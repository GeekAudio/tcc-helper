// AdvancedView.swift —— 高级模式
//
// 主界面只留一个按钮，其余能力全部收在这里：
// 选数据库、挑目标应用、指定权限、预演/授权/撤销、看条目。
// 不写日志，每次操作只留一条结果提示。

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 结果提示

struct Notice: Equatable {
    var key: String
    var detail: String = ""
    var ok: Bool = true
}

// MARK: - 状态

@MainActor
final class AdvancedModel: ObservableObject {
    @Published var db: TCCDB = .user
    @Published var dbStatus: [TCCDB: TCCCore.DBState] = [:]
    @Published var app = AppInfo()
    @Published var service = "kTCCServiceMicrophone"
    @Published var filter = ""
    @Published var forcePath = false
    @Published var entries: [TCCCore.Entry] = []
    @Published var busy = false
    @Published var notice: Notice?
    @Published var dropTargeted = false

    var clientValue: String {
        if !forcePath && !app.bundleID.isEmpty { return app.bundleID }
        return app.path
    }

    var clientType: Int {
        (!forcePath && !app.bundleID.isEmpty) ? 0 : 1
    }

    // MARK: 自检

    func selfCheck() {
        for d in TCCDB.allCases {
            dbStatus[d] = TCCCore.checkDB(d)
        }
    }

    func selfFDA() {
        guard !busy else { return }
        busy = true
        let info = TCCCore.inspect(path: Bundle.main.bundlePath)
        var tmp: String?
        if info.hasDR {
            let (data, _) = TCCCore.makeCsreq(dr: info.dr)
            if let data {
                let p = NSTemporaryDirectory() + "tcchelper-self-\(UUID().uuidString).bin"
                if (try? data.write(to: URL(fileURLWithPath: p))) != nil { tmp = p }
            }
        }
        defer { if let p = tmp { try? FileManager.default.removeItem(atPath: p) } }

        let bid = Bundle.main.bundleIdentifier ?? "com.geek.tcchelper"
        let r = TCCCore.grantFullDiskAccess(client: bid, csreqPath: tmp)
        busy = false
        if r.status == 0 {
            notice = Notice(key: "writeOK", detail: bid)
        } else {
            notice = Notice(key: "writeFailed", detail: r.combined, ok: false)
        }
        selfCheck()
    }

    // MARK: 目标应用

    func setApp(_ path: String) {
        var p = path
        if !p.hasSuffix(".app") {
            var cur = p
            while cur != "/" && !cur.isEmpty {
                cur = (cur as NSString).deletingLastPathComponent
                if cur.hasSuffix(".app") { p = cur; break }
            }
        }
        app = TCCCore.inspect(path: p)
        refresh()
    }

    func clearApp() {
        app = AppInfo()
        entries = []
        notice = nil
    }

    func pickApp(t: (String) -> String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = t("appPickMessage")
        if panel.runModal() == .OK, let u = panel.url { setApp(u.path) }
    }

    func pickRunning(t: (String) -> String) {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.bundleIdentifier != nil }
            .compactMap { a -> (String, String)? in
                guard let b = a.bundleURL?.path, let id = a.bundleIdentifier else { return nil }
                return (b, id)
            }
            .sorted { $0.1 < $1.1 }

        let alert = NSAlert()
        alert.messageText = t("runningTitle")
        alert.informativeText = t("runningInfo")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        for (p, id) in apps {
            pop.addItem(withTitle: id)
            pop.lastItem?.representedObject = p
        }
        alert.accessoryView = pop
        alert.addButton(withTitle: t("ok"))
        alert.addButton(withTitle: t("cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let p = pop.selectedItem?.representedObject as? String {
            setApp(p)
        }
    }

    // MARK: 条目

    func refresh() {
        guard !app.path.isEmpty else { return }
        entries = TCCCore.entries(db: db, client: clientValue)
    }

    // MARK: 操作

    func dryRun() {
        guard !app.path.isEmpty else {
            notice = Notice(key: "pickTargetFirst", ok: false)
            return
        }
        notice = Notice(key: "previewOnly", detail: clientValue, ok: true)
    }

    func grant() {
        guard !app.path.isEmpty else {
            notice = Notice(key: "pickTargetFirst", ok: false)
            return
        }
        guard !busy else { return }
        busy = true
        notice = nil

        let target = app
        let svc = service
        let client = clientValue
        let ct = clientType
        let database = db

        DispatchQueue.global(qos: .userInitiated).async {
            var csreqPath: String?
            if target.hasDR {
                let (data, _) = TCCCore.makeCsreq(dr: target.dr)
                if let data {
                    let p = NSTemporaryDirectory() + "tcchelper-blob-\(UUID().uuidString).bin"
                    if (try? data.write(to: URL(fileURLWithPath: p))) != nil { csreqPath = p }
                }
            }
            let backedUp = TCCCore.backup(database) != nil

            let sql = csreqPath != nil
                ? TCCCore.grantSQL(service: svc, client: client, clientType: ct, csreqPath: csreqPath!)
                : TCCCore.grantSQLNoCsreq(service: svc, client: client, clientType: ct)

            let r = TCCCore.apply(sql: sql, db: database, needAdmin: false)
            if let p = csreqPath { try? FileManager.default.removeItem(atPath: p) }

            var n: Notice
            if r.status != 0 {
                n = Notice(key: "writeFailed", detail: r.combined, ok: false)
            } else {
                _ = TCCCore.restartTCCD(needAdmin: false)
                Thread.sleep(forTimeInterval: 1.0)
                n = backedUp
                    ? Notice(key: "writeOK", detail: svc, ok: true)
                    : Notice(key: "backupFailed", ok: false)
            }

            DispatchQueue.main.async {
                self.busy = false
                self.notice = n
                self.refresh()
            }
        }
    }

    func revoke() {
        guard !app.path.isEmpty else {
            notice = Notice(key: "pickTargetFirst", ok: false)
            return
        }
        guard !busy else { return }
        busy = true
        notice = nil

        let svc = service
        let client = clientValue
        let ct = clientType
        let database = db

        DispatchQueue.global(qos: .userInitiated).async {
            _ = TCCCore.backup(database)
            let r = TCCCore.apply(sql: TCCCore.revokeSQL(service: svc, client: client, clientType: ct),
                                  db: database, needAdmin: false)
            if r.status == 0 {
                _ = TCCCore.restartTCCD(needAdmin: false)
                Thread.sleep(forTimeInterval: 0.6)
            }
            let n = r.status == 0
                ? Notice(key: "revokeOK", ok: true)
                : Notice(key: "writeFailed", detail: r.combined, ok: false)

            DispatchQueue.main.async {
                self.busy = false
                self.notice = n
                self.refresh()
            }
        }
    }
}

// MARK: - 卡片容器

struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - 高级模式

struct AdvancedView: View {
    @EnvironmentObject var lang: LangStore
    @StateObject private var m = AdvancedModel()
    @Environment(\.dismiss) private var dismiss

    private var filteredServices: [(id: String, name: String)] {
        let all = ServiceCatalog.all()
        guard !m.filter.isEmpty else { return all }
        let f = m.filter.lowercased()
        return all.filter {
            $0.id.lowercased().contains(f)
                || ServiceName.display($0.id, lang.lang).lowercased().contains(f)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.6)
            #if SNAPSHOT
            // 离屏渲染时 ScrollView 不展开内容，截图工具里直接铺开
            cards.padding(16)
            #else
            ScrollView {
                cards.padding(16)
            }
            #endif
        }
        .frame(width: 760, height: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if m.dbStatus.isEmpty { m.selfCheck() }
        }
    }

    private var cards: some View {
        VStack(spacing: 12) {
            databaseCard
            targetCard
            serviceCard
            actionCard
            entriesCard
        }
    }

    private var topBar: some View {
        HStack {
            Text(lang.t("advancedTitle"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(lang.t("close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: 数据库

    private var databaseCard: some View {
        Card(lang.t("database")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $m.db) {
                    Text(lang.t("userDB")).tag(TCCDB.user)
                    Text(lang.t("systemDB")).tag(TCCDB.system)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: m.db) { _ in m.refresh() }

                HStack(spacing: 7) {
                    let st = m.dbStatus[m.db]
                    let usable = (st?.readable ?? false) && ((st?.writable ?? false) || m.db == .system)
                    Image(systemName: usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(usable ? .green : .orange)
                    Text(dbStatusText(st))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button(lang.t("recheck")) { m.selfCheck() }
                        .controlSize(.small)
                    Button(lang.t("selfFDA")) { m.selfFDA() }
                        .controlSize(.small)
                        .disabled(m.busy)
                    Button(lang.t("openPrivacy")) {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    .controlSize(.small)
                }

                Text(lang.t("dbAdminNote"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Text(lang.t("dbSystemHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func dbStatusText(_ st: TCCCore.DBState?) -> String {
        guard let st else { return lang.t("dbChecking") }
        if !st.detail.isEmpty && !st.readable {
            return st.detail.hasPrefix("文件不存在")
                ? lang.t("dbMissing")
                : "\(lang.t("dbUnreadable")) — \(st.detail)"
        }
        if st.readable && st.writable { return lang.f("dbReadWrite", st.count) }
        if st.readable { return lang.f("dbReadOnly", st.count) }
        return lang.t("dbUnreadable")
    }

    // MARK: 目标应用

    private var targetCard: some View {
        Card(lang.t("targetApp")) {
            VStack(alignment: .leading, spacing: 10) {
                dropZone

                HStack(spacing: 8) {
                    Button(lang.t("choose")) { m.pickApp { lang.t($0) } }
                        .controlSize(.small)
                    Button(lang.t("runningApps")) { m.pickRunning { lang.t($0) } }
                        .controlSize(.small)
                    if !m.app.path.isEmpty {
                        Button(lang.t("clear")) { m.clearApp() }
                            .controlSize(.small)
                    }
                    Spacer()
                }

                if !m.app.path.isEmpty {
                    infoGrid
                }
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.3, dash: [5, 4])
                )
                .foregroundStyle(m.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))

            VStack(spacing: 3) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17))
                    .foregroundStyle(m.dropTargeted ? Color.accentColor : .secondary)
                Text(m.app.path.isEmpty ? lang.t("dropHint") : m.app.displayName)
                    .font(.system(size: 11.5, weight: m.app.path.isEmpty ? .regular : .medium))
                    .foregroundStyle(m.app.path.isEmpty ? .secondary : .primary)
                if m.app.path.isEmpty {
                    Text(lang.t("dropSubHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            .padding(6)
        }
        .frame(height: 84)
        .onDrop(of: [.fileURL], isTargeted: $m.dropTargeted) { providers in
            guard let p = providers.first else { return false }
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var path: String?
                if let d = item as? Data {
                    path = URL(dataRepresentation: d, relativeTo: nil)?.path
                } else if let u = item as? URL {
                    path = u.path
                }
                if let path { DispatchQueue.main.async { m.setApp(path) } }
            }
            return true
        }
    }

    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(lang.t("path"), m.app.path)
            row(lang.t("identifier"), m.app.bundleID.isEmpty ? lang.t("empty") : m.app.bundleID)
            if !m.app.version.isEmpty {
                row(lang.t("version"), m.app.version)
            }
            row(lang.t("signature"), m.app.hasDR ? lang.t("signedDR") : lang.t("noDR"))
            if !m.app.team.isEmpty {
                row(lang.t("issuer"), m.app.team)
            }
            Toggle(lang.t("byPath"), isOn: $m.forcePath)
                .font(.system(size: 10.5))
                .toggleStyle(.checkbox)
                .padding(.top, 2)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(k)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(v)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 权限服务

    private var serviceCard: some View {
        Card(lang.t("service")) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField(lang.t("serviceFilter"), text: $m.filter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }

                Picker("", selection: $m.service) {
                    ForEach(filteredServices, id: \.id) { s in
                        Text(lang.service(s.id)).tag(s.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)

                HStack(spacing: 5) {
                    Text(lang.t("current"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(m.service)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(lang.t("serviceNote"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 操作

    private var actionCard: some View {
        Card(lang.t("actions")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(lang.t("preview")) { m.dryRun() }
                        .controlSize(.small)
                        .disabled(m.busy || m.app.path.isEmpty)
                    Button(lang.t("grant")) { m.grant() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(m.busy || m.app.path.isEmpty)
                    Button(lang.t("revoke")) { m.revoke() }
                        .controlSize(.small)
                        .disabled(m.busy || m.app.path.isEmpty)
                    Button(lang.t("refresh")) { m.refresh() }
                        .controlSize(.small)
                        .disabled(m.busy || m.app.path.isEmpty)
                    Spacer()
                    if m.busy {
                        ProgressView().controlSize(.small)
                    }
                }

                if let n = m.notice {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: n.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(n.ok ? .green : .orange)
                        Text(n.detail.isEmpty ? lang.t(n.key) : "\(lang.t(n.key)) — \(n.detail)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(n.ok ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(lang.t("backupNote"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 条目

    private var entriesCard: some View {
        Card(lang.t("entries")) {
            VStack(alignment: .leading, spacing: 5) {
                if m.app.path.isEmpty {
                    Text(lang.t("pickTargetFirst"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else if m.entries.isEmpty {
                    Text(lang.t("noEntries"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(m.entries) { e in
                        HStack(spacing: 8) {
                            Text(stateText(e.authValue))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(e.authValue == 2 ? .green : (e.authValue == 0 ? .red : .orange))
                                .frame(width: 48, alignment: .leading)
                            Text(lang.service(e.service))
                                .font(.system(size: 10.5))
                                .frame(width: 118, alignment: .leading)
                                .lineLimit(1)
                            Text(e.service)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(e.csreqLen) B")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private func stateText(_ v: Int) -> String {
        switch v {
        case 0: return lang.t("denied")
        case 2: return lang.t("allowed")
        case 3: return lang.t("undecided")
        default: return lang.t("unknown")
        }
    }
}
