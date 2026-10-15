// TCC Helper —— 万能权限工具（GUI）
//
// 用途：把「已授权」条目直接写进 macOS 的 TCC 数据库，绕过权限弹窗。
//       AMFI 被关闭的机器上系统不再弹窗、也不生成条目，这是唯一的手工补法。
//
// ★ 本 App 自身需要「完全磁盘访问权限」才能读写 TCC.db。

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 日志

final class Log: ObservableObject {
    @Published var text = ""
    private let file = "/tmp/tcchelper.log"

    init() {
        try? "".write(toFile: file, atomically: true, encoding: .utf8)
    }

    func add(_ s: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(s)"
        text += line + "\n"
        if let h = FileHandle(forWritingAtPath: file) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var log = Log()

    @State private var app = AppInfo()
    @State private var dropTargeted = false

    @State private var db: TCCDB = .user
    @State private var service = "kTCCServiceMicrophone"
    @State private var svcFilter = ""
    @State private var forcePathMode = false

    @State private var entries: [TCCCore.Entry] = []
    @State private var dbStatus: [TCCDB: TCCCore.DBState] = [:]
    @State private var busy = false

    // 自动授权
    @State private var autoTargets: [AutoTarget] = []
    @State private var autoScanApps = true
    @State private var autoScanLaunchd = true
    @State private var autoScanRunning = true
    @State private var scanning = false

    private var services: [(id: String, name: String)] {
        let all = ServiceCatalog.all()
        guard !svcFilter.isEmpty else { return all }
        let f = svcFilter.lowercased()
        return all.filter { $0.id.lowercased().contains(f) || $0.name.lowercased().contains(f) }
    }

    private var clientValue: String {
        if !forcePathMode && !app.bundleID.isEmpty { return app.bundleID }
        return app.path
    }
    private var clientType: Int {
        (!forcePathMode && !app.bundleID.isEmpty) ? 0 : 1
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    dbSection
                    autoSection
                    appSection
                    serviceSection
                    actionSection
                    entriesSection
                }
                .padding(16)
            }
            .frame(minWidth: 460)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("日志").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("清空") { log.text = "" }.controlSize(.small)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.text, forType: .string)
                    }.controlSize(.small)
                }
                ScrollView {
                    Text(log.text.isEmpty ? "（暂无输出）" : log.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(16)
            .frame(minWidth: 340)
        }
        .frame(minWidth: 940, minHeight: 780)
        .onAppear(perform: startup)
    }

    // MARK: 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TCC Helper").font(.system(size: 20, weight: .semibold))
            Text("把「已授权」条目直接写进 TCC 数据库，绕过权限弹窗。"
                 + "AMFI 被关闭的机器上系统不再弹窗、也不生成条目，这是唯一的手工补法。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dbSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $db) {
                    ForEach(TCCDB.allCases) { d in
                        Text("\(d.title) — \(d.hint)").tag(d)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                HStack(spacing: 8) {
                    let st = dbStatus[db]
                    let usable = (st?.readable ?? false) && ((st?.writable ?? false) || db == .system)
                    Image(systemName: usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(usable ? .green : .orange)
                    Text(st?.detail ?? "未检查").font(.system(size: 11)).textSelection(.enabled)
                }
                HStack {
                    Button("重新自检") { selfCheck() }.controlSize(.small)
                    Button("给自己完全磁盘访问") { selfFDA() }.controlSize(.small)
                    Button("打开隐私设置") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(u)
                        }
                    }.controlSize(.small)
                }
                Text("系统库属主是 root ⇒ 写它时会弹管理员密码（不是「完全磁盘访问」那个）。"
                     + "用户库若不可写，才需要给本 App 勾上「完全磁盘访问权限」。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: { Text("1 · 目标数据库").font(.system(size: 12, weight: .medium)) }
    }

    private var appSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 20)).foregroundStyle(.secondary)
                        Text("把 .app 拖到这里（也可拖包内的子组件）")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 84)
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    guard let p = providers.first else { return false }
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        var path: String?
                        if let d = item as? Data {
                            path = URL(dataRepresentation: d, relativeTo: nil)?.path
                        } else if let u = item as? URL {
                            path = u.path
                        }
                        if let path { DispatchQueue.main.async { setApp(path) } }
                    }
                    return true
                }

                HStack {
                    Button("选择目标…") { pickApp() }
                    Button("从运行中的 App 选…") { pickRunning() }
                    if !app.path.isEmpty {
                        Button("清空") { app = AppInfo(); entries = [] }
                    }
                }

                if !app.path.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        labeled("路径", app.path)
                        labeled("Bundle ID", app.bundleID.isEmpty ? "（无）" : app.bundleID)
                        if !app.version.isEmpty { labeled("版本", app.version) }
                        labeled("签名", app.hasDR ? "有显式 designated requirement"
                                                  : "无显式 DR（csreq 将留空）")
                        if !app.team.isEmpty { labeled("签发者", app.team) }
                        if !app.note.isEmpty {
                            Text("⚠️ " + app.note).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Toggle("按路径授权（client_type=1，而不是 Bundle ID）", isOn: $forcePathMode)
                            .font(.system(size: 11))
                            .disabled(app.path.isEmpty)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(6)
        } label: { Text("3 · 目标 App（手动）").font(.system(size: 12, weight: .medium)) }
    }

    private var serviceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选服务（中英文都行）", text: $svcFilter)
                        .textFieldStyle(.roundedBorder)
                }
                Picker("服务", selection: $service) {
                    ForEach(services, id: \.id) { s in
                        Text(s.name.isEmpty ? s.id : "\(s.name) — \(s.id)").tag(s.id)
                    }
                }
                .labelsHidden()
                HStack {
                    Text("当前：").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(service).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                Text("服务清单是运行时从系统 tccd 里抽出来的，所以「万能」——系统认的它都在。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: { Text("4 · 权限服务（手动）").font(.system(size: 12, weight: .medium)) }
    }

    private var actionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("预演（不写库）") { doDryRun() }
                        .disabled(busy || app.path.isEmpty)
                    Button("授权") { doGrant() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || app.path.isEmpty)
                    Button("撤销") { doRevoke() }
                        .disabled(busy || app.path.isEmpty)
                    Button("刷新条目") { refresh() }
                        .disabled(busy || app.path.isEmpty)
                }
                if busy { ProgressView().controlSize(.small) }
                Text("写入前会自动备份 TCC.db；写完后自动 killall tccd 让系统重新读库。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: { Text("5 · 操作").font(.system(size: 12, weight: .medium)) }
    }

    private var autoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("不用人工选：App 的 Info.plist 里已经声明了它要什么权限，顺着这个反推。"
                     + "还会扫 launchd 注册的后台组件 —— 真正申请权限的往往是 helper"
                     + "（例：Loopback 的麦克风/系统音频其实属于包内的 ARK.app，给 Loopback 授权没用）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Toggle("/Applications", isOn: $autoScanApps).font(.system(size: 11))
                    Toggle("launchd 后台组件", isOn: $autoScanLaunchd).font(.system(size: 11))
                    Toggle("运行中的 App", isOn: $autoScanRunning).font(.system(size: 11))
                    Spacer()
                    if scanning { ProgressView().controlSize(.small) }
                    Button(scanning ? "扫描中…" : "扫描") { runAutoScan() }
                        .disabled(busy || scanning)
                }

                if !autoTargets.isEmpty {
                    let picked = autoTargets.filter { $0.selected }.count
                    HStack(spacing: 8) {
                        Text("\(autoTargets.count) 个 App 声明了权限，选中 \(picked) 个")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("全选") { setAllSelected(true) }.controlSize(.small)
                        Button("全不选") { setAllSelected(false) }.controlSize(.small)
                        Button("只选还缺的") { onlyMissing() }.controlSize(.small)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach($autoTargets) { $t in
                                HStack(spacing: 6) {
                                    Toggle("", isOn: $t.selected).labelsHidden().controlSize(.mini)
                                    Text(t.displayName)
                                        .font(.system(size: 11))
                                        .frame(width: 150, alignment: .leading).lineLimit(1)
                                    Text(t.bundleID)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(t.missing.isEmpty ? "已全授权" : "缺 \(t.missing.count)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(t.missing.isEmpty ? .green : .orange)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 170)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Button("授权选中的") { runAutoApply() }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                        Text("一次事务写完，只备份一次、只重启一次 tccd。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        } label: { Text("2 · 自动授权（推荐）").font(.system(size: 12, weight: .medium)) }
    }

    private var entriesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if entries.isEmpty {
                    Text(app.path.isEmpty ? "先选一个目标 App。" : "该 App 在\(db.title)里没有任何条目。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { e in
                        HStack(spacing: 6) {
                            Text(e.stateText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(e.authValue == 2 ? .green : (e.authValue == 0 ? .red : .orange))
                                .frame(width: 48, alignment: .leading)
                            Text(ServiceCatalog.name(for: e.service).isEmpty
                                 ? e.service : "\(ServiceCatalog.name(for: e.service))")
                                .font(.system(size: 11))
                                .frame(width: 110, alignment: .leading)
                            Text(e.service).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("csreq \(e.csreqLen)B · ct=\(e.clientType)").font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(6)
        } label: { Text("6 · 当前条目（\(db.title)）").font(.system(size: 12, weight: .medium)) }
    }

    private func labeled(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 动作

    private func startup() {
        log.add("TCC Helper 启动；TCC 库路径 = \(db.path)")
        selfCheck()
        let n = ServiceCatalog.systemServices().count
        log.add("从 tccd 抽到 \(n) 个服务名")
        runAutoScan(quiet: true)   // 打开就先告诉你缺什么
    }

    private func selfCheck() {
        for d in TCCDB.allCases {
            let r = TCCCore.checkDB(d)
            dbStatus[d] = r
            log.add("自检 \(d.title)：\(r.readable ? "可读" : "不可读") / "
                    + "\(r.writable ? "可写" : "不可写") — \(r.detail)")
        }
    }

    /// 自举：给自己写一条「完全磁盘访问权限」到系统库（需要管理员）。
    /// 别的机器上若用户库读不了，就是靠这一步把工具自己救活。
    private func selfFDA() {
        busy = true
        defer { busy = false }
        log.add("— 给自己授予完全磁盘访问权限（写系统库，会弹管理员密码）—")
        let info = TCCCore.inspect(path: Bundle.main.bundlePath)
        log.add("本 App：\(Bundle.main.bundlePath)")
        var tmp: String? = nil
        if info.hasDR {
            let (data, note) = TCCCore.makeCsreq(dr: info.dr)
            log.add(data == nil ? "✗ \(note)" : "✓ \(note)")
            guard let data else { return }
            let p = NSTemporaryDirectory() + "tcchelper-self-\(UUID().uuidString).bin"
            do { try data.write(to: URL(fileURLWithPath: p)) } catch {
                log.add("✗ 写临时文件失败：\(error.localizedDescription)")
                return
            }
            tmp = p
        } else {
            log.add("本 App 是 ad-hoc 签名（没有显式 DR）⇒ csreq 留空")
        }
        defer { if let p = tmp { try? FileManager.default.removeItem(atPath: p) } }
        let bid = Bundle.main.bundleIdentifier ?? "com.geek.tcchelper"
        let r = TCCCore.grantFullDiskAccess(client: bid, csreqPath: tmp)
        log.add(r.status == 0 ? "✓ 已写入系统库（client=\(bid)）" : "✗ 失败：\(r.combined)")
        sleep(1)
        selfCheck()
    }

    private func setApp(_ path: String) {
        var p = path
        // 用户可能拖进来的是包内可执行文件，往上找 .app
        if !p.hasSuffix(".app") {
            var cur = p
            while cur != "/" && cur != "" {
                cur = (cur as NSString).deletingLastPathComponent
                if cur.hasSuffix(".app") { p = cur; break }
            }
        }
        app = TCCCore.inspect(path: p)
        log.add("目标 = \(app.path)")
        log.add("  bundle id = \(app.bundleID.isEmpty ? "（无）" : app.bundleID)；签名 = \(app.hasDR ? "有显式 DR" : "无显式 DR")")
        refresh()
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true   // ★ 可以钻进 .app 里选子组件
        panel.message = "选一个 .app；需要给包内子组件授权时，可以进到它内部去选"
        if panel.runModal() == .OK, let u = panel.url { setApp(u.path) }
    }

    private func pickRunning() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.bundleIdentifier != nil }
            .compactMap { a -> (String, String)? in
                guard let b = a.bundleURL?.path, let id = a.bundleIdentifier else { return nil }
                return (b, id)
            }
            .sorted { $0.1 < $1.1 }
        let alert = NSAlert()
        alert.messageText = "选择运行中的 App"
        alert.informativeText = "只列出有 bundle 的进程。包内后台组件（如 xxxhelper）也在里面。"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        for (p, id) in apps { pop.addItem(withTitle: id); pop.lastItem?.representedObject = p }
        alert.accessoryView = pop
        alert.addButton(withTitle: "选择")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let p = pop.selectedItem?.representedObject as? String {
            setApp(p)
        }
    }

    private func refresh() {
        guard !app.path.isEmpty else { return }
        entries = TCCCore.entries(db: db, client: clientValue)
        log.add("\(db.title) 中 client=\(clientValue) 的条目：\(entries.count) 条")
    }

    private func doDryRun() {
        busy = true
        defer { busy = false }
        log.add("— 预演 —")
        if app.hasDR {
            let (data, note) = TCCCore.makeCsreq(dr: app.dr)
            log.add(data == nil ? "✗ \(note)" : "✓ \(note)")
        } else {
            log.add("csreq 将留空（目标没有显式 DR，按 \(clientType == 0 ? "Bundle ID" : "路径") 匹配）")
        }
        log.add("将写入：service=\(service) client=\(clientValue) client_type=\(clientType) → \(db.title)")
    }

    private func doGrant() {
        busy = true
        defer { busy = false }
        log.add("— 授权 —")
        var csreqPath: String? = nil
        if app.hasDR {
            let (data, note) = TCCCore.makeCsreq(dr: app.dr)
            log.add(data == nil ? "✗ \(note)" : "✓ \(note)")
            guard let data else { return }
            let tmp = NSTemporaryDirectory() + "tcchelper-blob-\(UUID().uuidString).bin"
            do { try data.write(to: URL(fileURLWithPath: tmp)) } catch {
                log.add("✗ 写临时文件失败：\(error.localizedDescription)"); return
            }
            csreqPath = tmp
        } else {
            log.add("csreq 留空（目标没有显式 DR，按 \(clientType == 0 ? "Bundle ID" : "路径") 匹配）")
        }

        if let bk = TCCCore.backup(db) { log.add("已备份 → \(bk)") }
        else { log.add("⚠️ 备份失败（可能缺完全磁盘访问权限），继续尝试") }

        let sql = csreqPath != nil
            ? TCCCore.grantSQL(service: service, client: clientValue,
                               clientType: clientType, csreqPath: csreqPath!)
            : TCCCore.grantSQLNoCsreq(service: service, client: clientValue, clientType: clientType)

        let r = TCCCore.apply(sql: sql, db: db, needAdmin: false)
        if csreqPath != nil { try? FileManager.default.removeItem(atPath: csreqPath!) }
        if r.status != 0 {
            log.add("✗ 写入失败：\(r.combined)")
            log.add("  ⇒ 用户库读不了 / 写不了时，先点「给自己完全磁盘访问」；系统库会弹管理员密码。")
            return
        }
        log.add("✓ 写入成功")

        let k = TCCCore.restartTCCD(needAdmin: false)
        log.add(k.status == 0 ? "已重启 tccd" : "tccd 重启返回 \(k.status)（root 那份拒绝属正常）")
        sleep(1)
        refresh()
        let alive = entries.contains { $0.service == service && $0.authValue == 2 }
        log.add(alive ? "✓ 回读验证：条目在，且 auth_value=2（被 tccd 接受）"
                      : "⚠️ 回读没看到该条目 —— 可能被 tccd 判为无效清掉了")
    }

    private func doRevoke() {
        busy = true
        defer { busy = false }
        log.add("— 撤销 —")
        if let bk = TCCCore.backup(db) { log.add("已备份 → \(bk)") }
        let sql = TCCCore.revokeSQL(service: service, client: clientValue, clientType: clientType)
        let r = TCCCore.apply(sql: sql, db: db, needAdmin: false)
        if r.status != 0 { log.add("✗ 撤销失败：\(r.combined)"); return }
        log.add("✓ 已删除该条目")
        _ = TCCCore.restartTCCD(needAdmin: false)
        sleep(1)
        refresh()
    }

    // MARK: 自动授权

    private func setAllSelected(_ v: Bool) {
        for i in autoTargets.indices { autoTargets[i].selected = v }
    }

    private func onlyMissing() {
        for i in autoTargets.indices { autoTargets[i].selected = !autoTargets[i].missing.isEmpty }
    }

    private func runAutoScan(quiet: Bool = false) {
        if scanning { return }
        if !quiet { log.add("— 自动扫描 —") }
        var roots: [String] = []
        if autoScanApps { roots.append("/Applications") }
        let useL = autoScanLaunchd
        let useR = autoScanRunning
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let found = AutoGrant.scan(roots: roots, includeLaunchd: useL, includeRunning: useR)
            let dt = String(format: "%.1f", Date().timeIntervalSince(t0))
            DispatchQueue.main.async {
                self.autoTargets = found
                self.scanning = false
                self.log.add("扫到 \(found.count) 个声明了权限的 App，用时 \(dt)s")
                let missing = found.filter { !$0.missing.isEmpty }
                if quiet {
                    self.log.add("其中 \(missing.count) 个还有未授权项 —— 在「2 · 自动授权」里勾选后点授权")
                } else {
                    self.log.add("其中 \(missing.count) 个还有未授权项：")
                    for t in missing {
                        self.log.add("  · \(t.displayName) [\(t.bundleID)] → \(t.missing.joined(separator: ", "))")
                    }
                    if missing.isEmpty { self.log.add("  （都齐了）") }
                }
            }
        }
    }

    private func runAutoApply() {
        let picked = autoTargets.filter { $0.selected && !$0.missing.isEmpty }
        guard !picked.isEmpty else {
            log.add("没有选中的、且还缺权限的项 —— 先扫描，再勾选。")
            return
        }
        let targetDB = db
        busy = true
        log.add("— 批量授权 \(picked.count) 个 App —")
        DispatchQueue.global(qos: .userInitiated).async {
            let enriched = AutoGrant.enrichAll(picked)   // 并行补签名，别串行跑几十次 codesign
            let res = AutoGrant.applyBatch(enriched, db: targetDB)
            DispatchQueue.main.async {
                for l in res.log { self.log.add(l) }
                self.busy = false
                self.runAutoScan(quiet: true)   // 就地重扫，看结果
            }
        }
    }
}

// MARK: - 入口

@main
struct TCCHelperApp: App {
    var body: some Scene {
        WindowGroup("TCC Helper") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
