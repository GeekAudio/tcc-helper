// tcchelper-cli —— 命令行版，和 GUI 共用 TCCCore.swift 的同一套逻辑
// 用途：验证 + 脚本化（GUI 点不了的地方用它）

import Foundation

let argv = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    tcchelper-cli —— TCC 权限读写（与 TCC Helper.app 共用同一套逻辑）

    用法：
      tcchelper-cli services                              列出系统认识的全部服务
      tcchelper-cli auto [--root DIR]... [--apply]        自动扫描并授权（默认只预演）
                       [--no-launchd] [--no-running] [--service kTCCServiceX]
      tcchelper-cli inspect  <App>                        看目标 App 的 bundle id / 签名
      tcchelper-cli list     <App> [--db user|system]     列出该 App 的条目
      tcchelper-cli dry      <App> <service> [--db ...]   预演（不写库）
      tcchelper-cli grant    <App> <service> [--db ...] [--path]   授权
      tcchelper-cli revoke   <App> <service> [--db ...] [--path]   撤销

      --db    user（默认，麦克风/摄像头/音频采集…）| system（辅助功能/屏幕录制…）
      --path  按绝对路径授权（client_type=1），而不是 Bundle ID

    auto 的原理：App 的 Info.plist 里已经声明了它要什么权限
      （NSMicrophoneUsageDescription → 麦克风，NSAudioCaptureUsageDescription → 系统音频采集 …）
      ⇒ 顺着这个反推，不用人工选。还会扫 launchd 注册的后台组件，
        因为真正申请权限的往往是 helper（例：Loopback 的权限其实属于包内的 ARK.app）。
    """)
    exit(2)
}

func flag(_ name: String) -> String? {
    if let i = argv.firstIndex(of: name), i + 1 < argv.count { return argv[i + 1] }
    return nil
}
func has(_ name: String) -> Bool { argv.contains(name) }
func positional() -> [String] {
    var out: [String] = []
    var skip = false
    for a in argv {
        if skip { skip = false; continue }
        if a.hasPrefix("--") { skip = (a == "--db"); continue }
        out.append(a)
    }
    return out
}

let pos = positional()
guard let cmd = pos.first else { usage() }

let db: TCCDB = (flag("--db") == "system") ? .system : .user

func target(_ p: String) -> AppInfo { TCCCore.inspect(path: p) }

func clientOf(_ info: AppInfo) -> (String, Int) {
    if !has("--path"), !info.bundleID.isEmpty { return (info.bundleID, 0) }
    return (info.path, 1)
}

switch cmd {

case "services":
    let all = ServiceCatalog.all()
    print("共 \(all.count) 个服务：")
    for s in all {
        print("  \(s.id)\(s.name.isEmpty ? "" : "   ← \(s.name)")")
    }

case "auto":
    // 自动授权：扫描 → 从 Info.plist 反推每个 App 需要什么权限
    var roots: [String] = []
    var i = 0
    while i < argv.count {
        if argv[i] == "--root", i + 1 < argv.count { roots.append(argv[i + 1]); i += 2; continue }
        i += 1
    }
    if roots.isEmpty { roots = ["/Applications"] }
    let useLaunchd = !has("--no-launchd")
    let useRunning = !has("--no-running")
    let onlyService = flag("--service")

    print("扫描范围：")
    for r in roots { print("  · 目录 \(r)") }
    if useLaunchd { print("  · launchd 注册的后台组件") }
    if useRunning { print("  · 正在运行的 App") }
    print("  · 组件目录（音频驱动 / 特权 helper…）")
    print()

    let tScan = Date()
    var targets = AutoGrant.scan(roots: roots, includeLaunchd: useLaunchd, includeRunning: useRunning)
    let scanSec = String(format: "%.1f", Date().timeIntervalSince(tScan))
    print("（扫描用时 \(scanSec)s）")
    print()

    let tEnrich = Date()
    targets = AutoGrant.enrichAll(targets)
    let enrichSec = String(format: "%.1f", Date().timeIntervalSince(tEnrich))
    print("（签名检查用时 \(enrichSec)s）")
    print()
    if let onlyService {
        targets = targets.map { t in
            var t = t
            t.services = t.services.filter { $0 == onlyService }
            return t
        }.filter { !$0.services.isEmpty }
    }

    if targets.isEmpty {
        print("没找到需要授权的 App（都没有声明 usage description，或服务名系统不认识）。")
        exit(0)
    }

    var nSvc = 0
    for t in targets {
        let miss = t.missing
        // 签名已在上面用 enrichAll 并行补过
        print("● \(t.displayName)")
        print("    bundle id : \(t.bundleID)")
        print("    路径      : \(t.path)")
        print("    来源      : \(t.source)")
        let sig: String
        if miss.isEmpty {
            sig = "（已授权，未检查）"
        } else {
            sig = t.hasDR ? "有显式 DR（csreq 会生成）" : "无显式 DR（csreq 留空）"
        }
        print("    签名      : \(sig)")
        print("    需要      : \(t.services.joined(separator: ", "))")
        if !miss.isEmpty {
            print("    还缺      : \(miss.joined(separator: ", "))")
        } else {
            print("    还缺      : （都已授权）")
        }
        nSvc += t.services.count
    }
    print()
    print("共 \(targets.count) 个 App / \(nSvc) 条权限。")

    if !has("--apply") {
        print("（这是预演；加 --apply 才真正写入）")
        exit(0)
    }
    let todo = targets.filter { !$0.missing.isEmpty }
    print("开始写入 \(todo.count) 个 App …")
    let res = AutoGrant.applyBatch(todo, db: db)
    for l in res.log { print("  \(l)") }
    exit(res.failed > 0 ? 1 : 0)

case "inspect":
    guard pos.count >= 2 else { usage() }
    let i = target(pos[1])
    print("路径      : \(i.path)")
    print("Bundle ID : \(i.bundleID.isEmpty ? "（无）" : i.bundleID)")
    print("版本      : \(i.version.isEmpty ? "（无）" : i.version)")
    print("签名      : \(i.hasDR ? "有显式 designated requirement" : "无显式 DR（ad-hoc / 未签名）")")
    if !i.team.isEmpty { print("签发者    : \(i.team)") }
    if !i.dr.isEmpty { print("DR        : \(i.dr)") }
    if !i.drImplicit.isEmpty { print("隐式 DR   : \(i.drImplicit)") }
    if !i.note.isEmpty { print("注意      : \(i.note)") }

case "list":
    guard pos.count >= 2 else { usage() }
    let i = target(pos[1])
    let (c, _) = clientOf(i)
    let es = TCCCore.entries(db: db, client: c)
    print("\(db.title) 中 client=\(c) 的条目：\(es.count) 条")
    for e in es {
        let n = ServiceCatalog.name(for: e.service)
        print("  \(e.stateText)  ct=\(e.clientType)  csreq=\(e.csreqLen)B  \(e.service)\(n.isEmpty ? "" : "  ← \(n)")  [\(e.modified)]")
    }

case "dry", "grant", "revoke":
    guard pos.count >= 3 else { usage() }
    let i = target(pos[1])
    let service = pos[2]
    let (c, ct) = clientOf(i)
    print("目标    : \(i.path)")
    print("client  : \(c)  (client_type=\(ct))")
    print("服务    : \(service)\(ServiceCatalog.name(for: service).isEmpty ? "" : "  ← \(ServiceCatalog.name(for: service))")")
    print("数据库  : \(db.title)  \(db.path)")

    let st = TCCCore.checkDB(db)
    print("自检    : \(st.readable ? "可读" : "不可读") / \(st.writable ? "可写" : "不可写") — \(st.detail)")

    if cmd == "revoke" {
        if let bk = TCCCore.backup(db) { print("已备份  : \(bk)") }
        let r = TCCCore.apply(sql: TCCCore.revokeSQL(service: service, client: c, clientType: ct),
                              db: db, needAdmin: false)
        if r.status != 0 { print("✗ 撤销失败：\(r.combined)"); exit(1) }
        print("✓ 已删除条目")
        _ = TCCCore.restartTCCD(needAdmin: false)
        exit(0)
    }

    var csreqTmp: String? = nil
    defer { if let p = csreqTmp { try? FileManager.default.removeItem(atPath: p) } }

    if i.hasDR {
        let (blob, note) = TCCCore.makeCsreq(dr: i.dr)
        print("csreq   : \(note)")
        guard let blob else { exit(1) }
        let tmp = NSTemporaryDirectory() + "tcchelper-cli-\(UUID().uuidString).bin"
        try! blob.write(to: URL(fileURLWithPath: tmp))
        csreqTmp = tmp
    } else {
        print("csreq   : 留空（目标没有显式 DR，按 \(ct == 0 ? "Bundle ID" : "路径") 匹配）")
    }

    if cmd == "dry" { print("（预演结束，未写库）"); exit(0) }

    if let bk = TCCCore.backup(db) { print("已备份  : \(bk)") }
    let sql = csreqTmp != nil
        ? TCCCore.grantSQL(service: service, client: c, clientType: ct, csreqPath: csreqTmp!)
        : TCCCore.grantSQLNoCsreq(service: service, client: c, clientType: ct)
    let r = TCCCore.apply(sql: sql, db: db, needAdmin: false)
    guard r.status == 0 else {
        print("✗ 写入失败：\(r.combined)")
        print("  ⇒ 用户库读不了 / 写不了时，给本工具「完全磁盘访问权限」；系统库需要管理员。")
        exit(1)
    }
    print("✓ 写入成功")
    _ = TCCCore.restartTCCD(needAdmin: false)
    sleep(1)

    let after = TCCCore.entries(db: db, client: c)
    if let e = after.first(where: { $0.service == service }) {
        print("✓ 回读：\(e.stateText)  csreq=\(e.csreqLen)B  —— 条目在，被 tccd 接受")
    } else {
        print("⚠️ 回读没看到该条目 —— 可能被 tccd 判为无效清掉了")
    }

default:
    usage()
}
