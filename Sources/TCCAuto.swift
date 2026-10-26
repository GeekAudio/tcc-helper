// TCCAuto.swift —— 自动授权：不靠人肉选，从系统里「反推」谁需要什么权限
//
// 两条线索：
//   ① App 的 Info.plist 里已经声明了自己要什么权限
//      （NSMicrophoneUsageDescription → 麦克风，NSAudioCaptureUsageDescription → 系统音频采集 …）
//   ② 真正申请权限的往往是**后台组件**，不一定是主 App
//      （例：Loopback 的麦克风/系统音频其实属于包内的 Audio Routing Kit (ARK).app）
//      ⇒ 扫 launchd 注册的每个 job，把它解析回所属的 .app，再看那个 .app 的 Info.plist

import Foundation
import AppKit

struct AutoTarget: Identifiable {
    var id: String { path }
    var path: String
    var bundleID: String
    var hasDR: Bool
    var dr: String
    var services: [String]          // 由 Info.plist 推导（用户库）
    var systemServices: [String] = []  // 由 Info.plist 推导（系统库）
    var source: String              // 从哪儿发现的
    var existing: Set<String> = []  // 用户库里已有「已允许」的服务
    var systemExisting: Set<String> = []  // 系统库里已有「已允许」的服务
    var selected: Bool = true

    var displayName: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    /// 还缺哪些（用户库）
    var missing: [String] { services.filter { !existing.contains($0) } }
    /// 还缺哪些（系统库）
    var systemMissing: [String] { systemServices.filter { !systemExisting.contains($0) } }
    /// 两个库加起来还有没有活干
    var hasWork: Bool { !missing.isEmpty || !systemMissing.isEmpty }
}

enum AutoGrant {

    /// Info.plist 键 → TCC 服务。顺序无所谓，后面会按系统真实服务清单过滤。
    ///
    /// ★ macOS 15 起「系统音频录制」并入了「屏幕录制」权限（kTCCServiceScreenCapture，
    ///   存在**系统库**），而 kTCCServiceAudioCapture 仍留在用户库给旧 API 用。
    ///   同一个 App 往往两条都要：用户库那条给 CoreAudio 的旧接口，系统库那条给新接口。
    ///   这里只映射用户库那条，系统库由 systemServices 单独处理。
    static let usageMap: [(key: String, service: String)] = [
        ("NSMicrophoneUsageDescription",              "kTCCServiceMicrophone"),
        ("NSCameraUsageDescription",                  "kTCCServiceCamera"),
        ("NSAudioCaptureUsageDescription",            "kTCCServiceAudioCapture"),
        ("NSAppleEventsUsageDescription",             "kTCCServiceAppleEvents"),
        ("NSBluetoothAlwaysUsageDescription",         "kTCCServiceBluetoothAlways"),
        ("NSBluetoothPeripheralUsageDescription",     "kTCCServiceBluetoothPeripheral"),
        ("NSContactsUsageDescription",                "kTCCServiceContactsFull"),
        ("NSCalendarsUsageDescription",               "kTCCServiceCalendar"),
        ("NSCalendarsFullAccessUsageDescription",     "kTCCServiceCalendar"),
        ("NSRemindersUsageDescription",               "kTCCServiceReminders"),
        ("NSRemindersFullAccessUsageDescription",     "kTCCServiceReminders"),
        ("NSPhotoLibraryUsageDescription",            "kTCCServicePhotos"),
        ("NSPhotoLibraryAddUsageDescription",         "kTCCServicePhotosAdd"),
        ("NSAppleMusicUsageDescription",              "kTCCServiceMediaLibrary"),
        ("NSDesktopFolderUsageDescription",           "kTCCServiceSystemPolicyDesktopFolder"),
        ("NSDocumentsFolderUsageDescription",         "kTCCServiceSystemPolicyDocumentsFolder"),
        ("NSDownloadsFolderUsageDescription",         "kTCCServiceSystemPolicyDownloadsFolder"),
        ("NSRemovableVolumesUsageDescription",        "kTCCServiceSystemPolicyRemovableVolumes"),
        ("NSNetworkVolumesUsageDescription",          "kTCCServiceSystemPolicyNetworkVolumes"),
        ("NSFileProviderDomainUsageDescription",      "kTCCServiceFileProviderDomain"),
        ("NSFileProviderPresenceUsageDescription",    "kTCCServiceFileProviderPresence"),
        ("NSFocusStatusUsageDescription",             "kTCCServiceFocusStatus"),
        ("NSMotionUsageDescription",                  "kTCCServiceMotion"),
        ("NSLocationUsageDescription",                "kTCCServiceLocation"),
        ("NSLocationWhenInUseUsageDescription",       "kTCCServiceLocation"),
        ("NSSpeechRecognitionUsageDescription",       "kTCCServiceSpeechRecognition"),
        ("NSUserTrackingUsageDescription",            "kTCCServiceUserTracking"),
        ("NSSystemAdministrationUsageDescription",    "kTCCServiceSystemPolicySysAdminFiles"),
        ("NSAccessorySetupKitSupports",               "kTCCServiceAccessorySetup"),
    ]

    /// Info.plist 键 → **系统库**里的服务。
    ///
    /// ★ 这是旧版本最大的漏：macOS 15 起「系统音频录制」改走 ScreenCaptureKit，
    ///   权限落在**系统库**的 `kTCCServiceScreenCapture`（和屏幕录制共用一条）；
    ///   用户库那条 `kTCCServiceAudioCapture` 只服务旧 CoreAudio 接口。
    ///   只写用户库 ⇒ 新接口仍然没权限，表现就是「明明授权了却用不了」。
    ///   写系统库需要管理员密码，所以放在第二趟单独跑，一次提权批量写完。
    static let systemUsageMap: [(key: String, service: String)] = [
        ("NSAudioCaptureUsageDescription", "kTCCServiceScreenCapture"),
    ]

    // MARK: plist 读取

    static func plist(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any]
    }

    // MARK: 从 Info.plist 推导服务

    static func bundleID(of bundle: String) -> String? {
        plist(bundle + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
    }

    /// 惰性补签名信息。
    /// ★ 扫描时**不能**对每个 App 都跑 codesign —— 每次是一个子进程，几十个就是十几秒
    ///   （实测：36 个 App 串行要 17–21 秒）。所以扫描阶段不碰它，只在真要写入/展示时补，
    ///   而且补的时候**并行**跑。
    static func enrich(_ t: inout AutoTarget) {
        let info = TCCCore.inspect(path: t.path)
        t.hasDR = info.hasDR
        t.dr = info.dr
    }

    /// 并行补齐一批目标的签名信息（串行的话每个 codesign 约 0.5s，几十个就很明显）
    static func enrichAll(_ targets: [AutoTarget]) -> [AutoTarget] {
        var out = targets
        let idx = out.indices.filter { out[$0].dr.isEmpty }
        guard !idx.isEmpty else { return out }
        let paths = idx.map { out[$0].path }      // 先取出不可变副本，避免并发读数组
        var hasDR = [Bool](repeating: false, count: idx.count)
        var drs = [String](repeating: "", count: idx.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: idx.count) { k in
            let info = TCCCore.inspect(path: paths[k])
            lock.lock()
            hasDR[k] = info.hasDR
            drs[k] = info.dr
            lock.unlock()
        }
        for (k, i) in idx.enumerated() {
            out[i].hasDR = hasDR[k]
            out[i].dr = drs[k]
        }
        return out
    }

    static func services(forBundle bundle: String) -> [String] {
        guard let info = plist(bundle + "/Contents/Info.plist") else { return [] }
        let known = Set(ServiceCatalog.systemServices())
        var out: [String] = []
        for (key, service) in usageMap {
            guard info[key] != nil else { continue }
            // 只保留系统 tccd 真认识的服务名，避免写进去也是无效条目
            guard known.isEmpty || known.contains(service) else { continue }
            if !out.contains(service) { out.append(service) }
        }
        return out
    }

    /// 同一个 App 需要在**系统库**里补的服务
    static func systemServices(forBundle bundle: String) -> [String] {
        guard let info = plist(bundle + "/Contents/Info.plist") else { return [] }
        let known = Set(ServiceCatalog.systemServices())
        var out: [String] = []
        for (key, service) in systemUsageMap {
            guard info[key] != nil else { continue }
            guard known.isEmpty || known.contains(service) else { continue }
            if !out.contains(service) { out.append(service) }
        }
        // Computer Use 不通过 usage description 声明这两项，必须识别真正的 helper。
        if ComputerUse.isHelper(at: bundle) {
            for service in ComputerUse.requiredServices where !out.contains(service) {
                if known.isEmpty || known.contains(service) { out.append(service) }
            }
        }
        return out
    }

    // MARK: 路径 → 所属 .app

    /// 从可执行文件路径往上找到所属的 .app（ARK 那种「.driver 里套 .app」也能命中）
    static func enclosingApp(of path: String) -> String? {
        var p = path
        for _ in 0..<14 {
            if p.hasSuffix(".app") { return p }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent == "/" || parent.isEmpty { return nil }
            p = parent
        }
        return nil
    }

    /// 在一个 .app 内部找子组件（Loopback 那种 helper 就在这里）
    static func nestedApps(in bundle: String) -> [String] {
        let subdirs = ["Contents/Library/LoginItems", "Contents/Library/LaunchServices",
                       "Contents/XPCServices", "Contents/PlugIns", "Contents/Helpers",
                       "Contents/Resources", "Contents/MacOS"]
        var out: [String] = []
        for sub in subdirs {
            let dir = bundle + "/" + sub
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let p = dir + "/" + n
                if !out.contains(p) { out.append(p) }
            }
            // Resources 下常见的再深一层
            for n in names {
                let d2 = dir + "/" + n
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: d2, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let inner = try? FileManager.default.contentsOfDirectory(atPath: d2) else { continue }
                for m in inner where m.hasSuffix(".app") {
                    let p = d2 + "/" + m
                    if !out.contains(p) { out.append(p) }
                }
            }
        }
        return out
    }

    // MARK: 候选来源

    /// 会被当作「可执行包」收集的扩展名。
    /// ★ 只认 .app 会漏掉 AudioServerPlugIn —— 典型例子是 SoundSource 的
    ///   `/Library/Audio/Plug-Ins/HAL/ARK.driver`，它的真正申请者
    ///   `Audio Routing Kit (ARK).app`（com.rogueamoeba.arkaudiod）藏在
    ///   `ARK.driver/Contents/Resources/` 里。只扫 .app 的话整个驱动被跳过，
    ///   用户就会看到「ARK 需要授权」的弹窗却没人处理。
    static let bundleSuffixes = [".app", ".driver", ".xpc", ".appex", ".plugin", ".kext"]

    static func appsUnder(_ root: String, depth: Int = 2) -> [String] {
        var out: [String] = []
        func walk(_ dir: String, _ d: Int) {
            guard d >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for n in names {
                let p = dir + "/" + n
                if bundleSuffixes.contains(where: { n.hasSuffix($0) }) { out.append(p); continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    walk(p, d - 1)
                }
            }
        }
        walk(root, depth)
        return out
    }

    /// launchd 注册的后台组件 —— 自动授权最关键的一路
    static func launchdPrograms() -> [String] {
        let dirs = ["/Library/LaunchAgents", "/Library/LaunchDaemons",
                    NSHomeDirectory() + "/Library/LaunchAgents"]
        var out: [String] = []
        for d in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for f in files where f.hasSuffix(".plist") {
                guard let dict = plist(d + "/" + f) else { continue }
                if let prog = dict["Program"] as? String {
                    out.append(prog)
                } else if let args = dict["ProgramArguments"] as? [String], let first = args.first {
                    out.append(first)
                }
            }
        }
        return out
    }

    /// 后台组件常住的目录（音频驱动、特权 helper…）
    static let helperDirs = [
        "/Library/Audio/Plug-Ins/HAL",
        "/Library/Audio/Plug-Ins/Components",
        "/Library/PrivilegedHelperTools",
        "/Library/Internet Plug-Ins",
    ]

    // MARK: 扫描

    static func scan(roots: [String] = ["/Applications"],
                     includeLaunchd: Bool = true,
                     includeRunning: Bool = true,
                     includeHelpers: Bool = true) -> [AutoTarget] {

        var candidates: [(path: String, source: String)] = []
        func add(_ p: String, _ s: String) {
            guard !candidates.contains(where: { $0.path == p }) else { return }
            candidates.append((p, s))
        }

        for r in roots {
            for a in appsUnder(r) { add(a, "目录 \(r)") }
        }

        if includeHelpers {
            for path in ComputerUse.discover(runningPaths: []) { add(path, "Computer Use") }
            for d in helperDirs {
                for a in appsUnder(d, depth: 3) { add(a, "组件目录 \(d)") }
            }
        }

        if includeLaunchd {
            for prog in launchdPrograms() {
                if let app = enclosingApp(of: prog) { add(app, "launchd 后台组件") }
            }
        }

        if includeRunning {
            for a in NSWorkspace.shared.runningApplications {
                if let u = a.bundleURL?.path, u.hasSuffix(".app") { add(u, "运行中") }
            }
        }

        // 主 App + 其内部子组件
        var targets: [AutoTarget] = []
        var seen = Set<String>()
        func consider(_ bundle: String, _ source: String) {
            guard !seen.contains(bundle) else { return }
            seen.insert(bundle)
            let svc = services(forBundle: bundle)
            let sysSvc = systemServices(forBundle: bundle)
            // 只要两个库里有一个有活干就收进来（旧版只看用户库，系统库服务整个被跳过）
            guard !svc.isEmpty || !sysSvc.isEmpty else { return }
            guard let bid = bundleID(of: bundle), !bid.isEmpty else { return }
            // 签名信息先留空，真要写入时再用 enrich() 补
            // （扫描阶段对每个 App 跑 codesign 会让 36 个 App 花掉 17–21 秒）
            targets.append(AutoTarget(path: bundle, bundleID: bid,
                                      hasDR: false, dr: "",
                                      services: svc, systemServices: sysSvc,
                                      source: source))
        }

        for c in candidates {
            consider(c.path, c.source)
            for nested in nestedApps(in: c.path) {
                consider(nested, "包内子组件（属于 \((c.path as NSString).lastPathComponent)）")
            }
        }
        // 标出已经授权过的 —— ★ 两个库都要查：
        //   旧版只查用户库，于是系统库里的 Accessibility / ScreenCapture 永远被算成「缺失」，
        //   每次点一键授权都在重复劳动，而且根本写不进去。
        let existingUser = existingGrants(db: .user)
        let existingSystem = existingGrants(db: .system)
        for i in targets.indices {
            targets[i].existing = existingUser[targets[i].bundleID] ?? []
            targets[i].systemExisting = existingSystem[targets[i].bundleID] ?? []
        }
        return targets.sorted { $0.bundleID < $1.bundleID }
    }

    /// 用户库里所有「已允许」的 (bundle id → services)
    static func existingGrants(db: TCCDB) -> [String: Set<String>] {
        let r = Sh.run("/usr/bin/sqlite3", ["-separator", "|", db.path,
            "select client, service from access where client_type=0 and auth_value=2;"])
        guard r.status == 0 else { return [:] }
        var out: [String: Set<String>] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard f.count == 2 else { continue }
            out[f[0], default: []].insert(f[1])
        }
        return out
    }

    // MARK: 批量授权

    struct BatchResult {
        var granted = 0
        var failed = 0
        var skipped = 0
        var log: [String] = []
    }

    /// 一次事务写完所有条目，只备份一次、只重启一次 tccd
    static func applyBatch(_ items: [AutoTarget], db: TCCDB, needAdmin: Bool = false) -> BatchResult {
        var res = BatchResult()
        var sql = "BEGIN;\n"
        var tmps: [String] = []

        for var t in items {
            // 系统库那趟只写 systemServices，用户库那趟只写 services ——
            // 混着写会往库里塞无效条目（tccd 根本不看另一个库里的同名服务）。
            let svcList = (db == .system) ? t.systemServices : t.services
            guard !svcList.isEmpty else { continue }
            if t.dr.isEmpty { enrich(&t) }   // 单个补（调用方通常已用 enrichAll 并行补过）
            var csreqPath: String? = nil
            if t.hasDR {
                let (blob, note) = TCCCore.makeCsreq(dr: t.dr)
                if let blob {
                    let p = NSTemporaryDirectory() + "tccauto-\(UUID().uuidString).bin"
                    if (try? blob.write(to: URL(fileURLWithPath: p))) != nil {
                        csreqPath = p
                        tmps.append(p)
                    }
                } else {
                    res.log.append("⚠️ \(t.displayName)：\(note)")
                }
            }
            for s in svcList {
                sql += csreqPath != nil
                    ? TCCCore.grantSQL(service: s, client: t.bundleID, clientType: 0, csreqPath: csreqPath!)
                    : TCCCore.grantSQLNoCsreq(service: s, client: t.bundleID, clientType: 0)
                res.granted += 1
                res.log.append("+ \(t.displayName)  [\(t.bundleID)]  \(s)"
                               + (csreqPath != nil ? "" : "   (csreq 留空)"))
            }
        }
        sql += "COMMIT;\n"

        defer { for p in tmps { try? FileManager.default.removeItem(atPath: p) } }

        if res.granted == 0 {
            res.log.append("没有需要写入的条目")
            return res
        }

        // ★ 系统库是 root:wheel，用户态 cp 必然失败 —— 备份放进提权脚本里做
        if db == .system {
            res.log.append("备份在提权脚本内完成")
        } else if let bk = TCCCore.backup(db) {
            res.log.append("已备份 → \(bk)")
        } else {
            res.log.append("⚠️ 备份失败（可能缺完全磁盘访问权限）")
        }

        let r = TCCCore.apply(sql: sql, db: db, needAdmin: needAdmin)
        if r.status != 0 {
            res.failed = res.granted
            res.granted = 0
            res.log.append("✗ 写入失败：\(r.combined)")
            return res
        }
        // 提权脚本里已经 kickstart 过一次；这里再以**用户身份**补一次。
        // 原因：用户域里 kickstart 是实测有效的路径（pid 438 → 3275），
        // 而 root 在提权脚本里操作 gui/<uid> 域没实测过，双保险。
        _ = TCCCore.restartTCCD(needAdmin: false)
        res.log.append("✓ 共写入 \(res.granted) 条")
        return res
    }
}
