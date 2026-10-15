// TCCCore.swift —— TCC 权限读写的核心逻辑
//
// 原理：把「已授权」条目直接写进 TCC 数据库的 access 表，
//       csreq 由目标 App 自己的 designated requirement 生成。
// 背景：AMFI 关闭的机器上 macOS 不再弹权限窗、也不生成条目，只能这样手工补。

import Foundation

// MARK: - 进程执行

struct ProcResult {
    var status: Int32 = -1
    var out = ""
    var err = ""
    var combined: String {
        (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Sh {
    @discardableResult
    static func run(_ path: String, _ args: [String], stdin: Data? = nil) -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let op = Pipe(), ep = Pipe()
        p.standardOutput = op
        p.standardError = ep
        var ip: Pipe?
        if stdin != nil {
            let i = Pipe()
            ip = i
            p.standardInput = i
        }
        do {
            try p.run()
        } catch {
            return ProcResult(status: -1, err: "无法启动 \(path)：\(error.localizedDescription)")
        }
        if let d = stdin, let i = ip {
            i.fileHandleForWriting.write(d)
            try? i.fileHandleForWriting.close()
        }
        let od = op.fileHandleForReading.readDataToEndOfFile()
        let ed = ep.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcResult(status: p.terminationStatus,
                          out: String(decoding: od, as: UTF8.self),
                          err: String(decoding: ed, as: UTF8.self))
    }

    /// 以管理员身份跑一段 shell 脚本（用于写系统库 / 需要 root 的操作）。
    /// 做法：脚本落到临时文件，再用 osascript 的 with administrator privileges 执行。
    static func runAsAdmin(script: String) -> ProcResult {
        let tmp = NSTemporaryDirectory() + "tcchelper-admin-\(UUID().uuidString).sh"
        do {
            try script.write(toFile: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp)
        } catch {
            return ProcResult(status: -1, err: "写临时脚本失败：\(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let apple = "do shell script \"/bin/sh \(tmp)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", apple])
    }
}

// MARK: - TCC 数据库

enum TCCDB: String, CaseIterable, Identifiable {
    case user
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user:   return "用户库"
        case .system: return "系统库"
        }
    }

    var hint: String {
        switch self {
        case .user:   return "麦克风 / 摄像头 / 音频采集 / 蓝牙 / 照片 等大多在这里"
        case .system: return "辅助功能 / 屏幕录制 等在这里（写入需要管理员）"
        }
    }

    var path: String {
        switch self {
        case .user:
            return NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        case .system:
            return "/Library/Application Support/com.apple.TCC/TCC.db"
        }
    }
}

// MARK: - 目标 App 信息

struct AppInfo {
    var path: String = ""
    var bundleID: String = ""
    var displayName: String = ""
    var version: String = ""
    /// 显式 designated requirement（空 = 没有，如 ad-hoc 签名）
    var dr: String = ""
    /// codesign 以 `# designated =>` 打出的隐式 DR（ad-hoc 应用是 cdhash）
    var drImplicit: String = ""
    var team: String = ""
    var note: String = ""

    var hasDR: Bool { !dr.isEmpty }
    /// 写进 access.client 的值
    var isBundle: Bool { !bundleID.isEmpty }
}

// MARK: - 服务清单

enum ServiceCatalog {
    /// 常用服务（中文名方便认）。运行时还会用 tccd 里的真实清单补齐。
    static let curated: [(id: String, name: String)] = [
        ("kTCCServiceMicrophone", "麦克风"),
        ("kTCCServiceCamera", "摄像头"),
        ("kTCCServiceAudioCapture", "系统音频采集"),
        ("kTCCServiceScreenCapture", "屏幕录制"),
        ("kTCCServiceAccessibility", "辅助功能"),
        ("kTCCServiceListenEvent", "输入监控"),
        ("kTCCServicePostEvent", "发送按键事件"),
        ("kTCCServiceAppleEvents", "自动化（Apple 事件）"),
        ("kTCCServiceSystemPolicyAllFiles", "完全磁盘访问权限"),
        ("kTCCServiceDeveloperTool", "开发者工具"),
        ("kTCCServiceBluetoothAlways", "蓝牙"),
        ("kTCCServiceMediaLibrary", "媒体与 Apple Music"),
        ("kTCCServicePhotos", "照片（读取）"),
        ("kTCCServicePhotosAdd", "照片（写入）"),
        ("kTCCServiceContactsFull", "通讯录（完整）"),
        ("kTCCServiceContactsLimited", "通讯录（受限）"),
        ("kTCCServiceCalendar", "日历"),
        ("kTCCServiceReminders", "提醒事项"),
        ("kTCCServiceMotion", "运动与健身"),
        ("kTCCServiceFocusStatus", "专注状态"),
        ("kTCCServicePasteboard", "剪贴板"),
        ("kTCCServiceMicrophoneInjection", "麦克风注入"),
        ("kTCCServiceRemoteDesktop", "远程桌面"),
        ("kTCCServiceEndpointSecurityClient", "端点安全客户端"),
        ("kTCCServiceSystemPolicyDesktopFolder", "桌面文件夹"),
        ("kTCCServiceSystemPolicyDocumentsFolder", "文稿文件夹"),
        ("kTCCServiceSystemPolicyDownloadsFolder", "下载文件夹"),
        ("kTCCServiceSystemPolicyNetworkVolumes", "网络宗卷"),
        ("kTCCServiceSystemPolicyRemovableVolumes", "可移除宗卷"),
        ("kTCCServiceSystemPolicyAppBundles", "App 管理"),
        ("kTCCServiceSystemPolicyAppData", "App 数据"),
        ("kTCCServiceSystemPolicySysAdminFiles", "系统管理文件"),
    ]

    /// 从 tccd 二进制里抽出系统真正认识的全部服务名
    /// ★ 必须缓存：这个函数要读几 MB 的 tccd 再跑正则，
    ///   而自动扫描会对每个 App 调一次 —— 不缓存就是几十遍全量扫描（实测会卡住界面）。
    private static var systemServicesCache: [String]?

    static func systemServices() -> [String] {
        if let c = systemServicesCache { return c }
        let p = "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd"
        guard let data = FileManager.default.contents(atPath: p) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let re = try? NSRegularExpression(pattern: "kTCCService[A-Za-z]+")
        guard let re else { return [] }
        let ns = text as NSString
        var set = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            set.insert(ns.substring(with: m.range))
        }
        set.remove("kTCCServiceAll")
        let sorted = set.sorted()
        systemServicesCache = sorted
        return sorted
    }

    /// 供 Picker 用的完整列表：curated 在前（带中文名），其余按字母排
    static func all() -> [(id: String, name: String)] {
        let known = Set(curated.map { $0.id })
        var out = curated
        for s in systemServices() where !known.contains(s) {
            out.append((s, ""))
        }
        return out
    }

    static func name(for id: String) -> String {
        curated.first(where: { $0.id == id })?.name ?? ""
    }
}

// MARK: - 核心操作

enum TCCCore {

    static let tmpDir = NSTemporaryDirectory()

    // ---- 读取目标 App 信息 ----

    static func inspect(path: String) -> AppInfo {
        var info = AppInfo()
        info.path = path
        let fm = FileManager.default

        // bundle id / 版本
        let infoPlist = path + "/Contents/Info.plist"
        if fm.fileExists(atPath: infoPlist) {
            let bid = Sh.run("/usr/bin/plutil", ["-extract", "CFBundleIdentifier", "raw", infoPlist])
            info.bundleID = bid.combined
            let ver = Sh.run("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", infoPlist])
            info.version = ver.combined
        }
        info.displayName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        // 签名 / designated requirement
        // ★ codesign 的坑（两个都要防）：
        //   1) `-dvvv -r-` 时 **DR 走 stdout、详细信息走 stderr** ⇒ 必须两个流都解析，
        //      只看其中一个会漏掉 DR（早期版本就踩了这个，把有签名的 App 判成「无签名」）；
        //   2) 没有显式 DR 时（ad-hoc 签名）打成 `# designated => cdhash H"..."` —— 带 `#`，
        //      是注释形式。所以「有 #」= 没有显式 DR，不能当签名用。
        let cs = Sh.run("/usr/bin/codesign", ["-dvvv", "-r-", path])
        let text = cs.out + "\n" + cs.err
        for raw in text.split(separator: "\n") {
            let s = String(raw).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("# designated => ") {
                info.drImplicit = String(s.dropFirst("# designated => ".count))
            } else if let r = s.range(of: "designated => ") {
                info.dr = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("Authority="), info.team.isEmpty {
                // 只取第一条：codesign 按「签发者 → 中间 CA → Apple Root CA」顺序列出
                info.team = String(s.dropFirst("Authority=".count))
            }
        }
        if !info.hasDR {
            if info.drImplicit.isEmpty {
                info.note = "没有 designated requirement（未签名）⇒ csreq 只能留空，按 Bundle ID 匹配"
            } else {
                info.note = "只有隐式 DR（ad-hoc：\(info.drImplicit.prefix(46))…）⇒ csreq 留空，按 Bundle ID 匹配"
            }
        }
        return info
    }

    // ---- csreq ----

    /// DR 文本 → DER 形式的 csreq blob。★ 绝不能带 `designated => ` 前缀，
    /// 带了会生成 fade0c01（集合格式），TCC 不认。
    static func makeCsreq(dr: String) -> (Data?, String) {
        let out = tmpDir + "tcchelper-req-\(UUID().uuidString).bin"
        let r = Sh.run("/usr/bin/csreq", ["-r-", "-b", out], stdin: Data((dr + "\n").utf8))
        defer { try? FileManager.default.removeItem(atPath: out) }
        guard let data = FileManager.default.contents(atPath: out), data.count > 8 else {
            return (nil, "csreq 生成失败：\(r.combined)")
        }
        let magic = data.prefix(4).map { String(format: "%02x", $0) }.joined()
        if magic != "fade0c00" {
            return (data, "⚠️ csreq magic=\(magic)（期望 fade0c00；fade0c01 会被 TCC 拒绝）")
        }
        return (data, "csreq 正常（\(data.count) 字节，magic \(magic)）")
    }

    // ---- 数据库可写性自检 ----

    struct DBState {
        var readable = false
        var writable = false
        var count = 0
        var detail = ""
    }

    static func checkDB(_ db: TCCDB) -> DBState {
        var st = DBState()
        guard FileManager.default.fileExists(atPath: db.path) else {
            st.detail = "文件不存在：\(db.path)"
            return st
        }
        let r = Sh.run("/usr/bin/sqlite3", [db.path, "select count(*) from access;"])
        guard r.status == 0 else {
            st.detail = "读不了（缺「完全磁盘访问权限」，或 SIP 未放宽）：\(r.combined)"
            return st
        }
        st.readable = true
        st.count = Int(r.combined) ?? 0

        // 真·写测试：对主库做一次 DDL 再回滚。
        // ★ 不能用临时表测 —— 临时表只写 temp 库，永远「成功」，测不出只读。
        let t = Sh.run("/usr/bin/sqlite3", [db.path,
            "begin immediate; create table if not exists _tcchelper_probe(x);"
            + " drop table if exists _tcchelper_probe; rollback;"])
        if t.status != 0 {
            st.writable = false
            let msg = t.combined
            st.detail = "可读不可写（\(st.count) 条）："
                + (msg.contains("readonly") || msg.contains("attempt to write")
                   ? "文件属主是 root" : msg)
        } else {
            st.writable = true
            st.detail = "可读写（\(st.count) 条）"
        }
        return st
    }

    /// 给某个 client（通常就是本 App 自己）授予「完全磁盘访问权限」。
    /// 系统库是 root 所有，必须提权写；写完顺手重启 tccd。
    /// csreqPath 为 nil 时写空 csreq（本 App 是 ad-hoc 签名，没有显式 DR）。
    static func grantFullDiskAccess(client: String, csreqPath: String?) -> ProcResult {
        let sql: String
        if let p = csreqPath {
            sql = grantSQL(service: "kTCCServiceSystemPolicyAllFiles",
                           client: client, clientType: 0, csreqPath: p)
        } else {
            sql = grantSQLNoCsreq(service: "kTCCServiceSystemPolicyAllFiles",
                                  client: client, clientType: 0)
        }
        let script = """
        #!/bin/sh
        /usr/bin/sqlite3 \(shellQuote(TCCDB.system.path)) <<'TCCSQL'
        \(sql)
        TCCSQL
        /usr/bin/killall tccd 2>/dev/null
        exit 0
        """
        return Sh.runAsAdmin(script: script)
    }

    static func backup(_ db: TCCDB) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let dst = db.path + ".bak-\(stamp)"
        let r = Sh.run("/bin/cp", ["-p", db.path, dst])
        return r.status == 0 ? dst : nil
    }

    // ---- SQL 拼装（sqlite3 CLI 不支持绑定参数，做单引号转义）----

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func grantSQL(service: String, client: String, clientType: Int, csreqPath: String) -> String {
        """
        INSERT OR REPLACE INTO access
          (service, client, client_type, auth_value, auth_reason, auth_version, csreq,
           policy_id, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified)
        VALUES
          (\(q(service)), \(q(client)), \(clientType), 2, 4, 1, readfile(\(q(csreqPath))),
           NULL, 0, 'UNUSED', 0, strftime('%s','now'));
        """
    }

    /// 目标没有显式 designated requirement（ad-hoc 签名 / 未签名）时用这个：csreq 留空，
    /// 靠 client（Bundle ID 或路径）匹配。系统自己给 Apple 守护进程写的条目也是这样。
    static func grantSQLNoCsreq(service: String, client: String, clientType: Int) -> String {
        """
        INSERT OR REPLACE INTO access
          (service, client, client_type, auth_value, auth_reason, auth_version, csreq,
           policy_id, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified)
        VALUES
          (\(q(service)), \(q(client)), \(clientType), 2, 4, 1, NULL,
           NULL, 0, 'UNUSED', 0, strftime('%s','now'));
        """
    }

    static func revokeSQL(service: String, client: String, clientType: Int) -> String {
        "DELETE FROM access WHERE service=\(q(service)) AND client=\(q(client)) AND client_type=\(clientType);"
    }

    static func listSQL(client: String) -> String {
        """
        SELECT service, client_type, auth_value, auth_reason, length(csreq),
               datetime(last_modified,'unixepoch','localtime')
        FROM access WHERE client=\(q(client)) ORDER BY service;
        """
    }

    // ---- 执行 ----

    struct Entry: Identifiable {
        var id: String { "\(service)-\(clientType)" }
        var service: String
        var clientType: Int
        var authValue: Int
        var authReason: Int
        var csreqLen: Int
        var modified: String

        var stateText: String {
            switch authValue {
            case 0: return "已拒绝"
            case 2: return "已允许"
            case 3: return "未决"
            default: return "未知(\(authValue))"
            }
        }
    }

    static func entries(db: TCCDB, client: String) -> [Entry] {
        let r = Sh.run("/usr/bin/sqlite3", ["-separator", "|", db.path, listSQL(client: client)])
        guard r.status == 0 else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { return nil }
            return Entry(service: f[0],
                         clientType: Int(f[1]) ?? 0,
                         authValue: Int(f[2]) ?? -1,
                         authReason: Int(f[3]) ?? -1,
                         csreqLen: Int(f[4]) ?? 0,
                         modified: f[5])
        }
    }

    /// 写入（授权 / 撤销）。系统库自动走管理员。
    static func apply(sql: String, db: TCCDB, needAdmin: Bool) -> ProcResult {
        if needAdmin || db == .system {
            let script = """
            #!/bin/sh
            /usr/bin/sqlite3 \(shellQuote(db.path)) <<'TCCSQL'
            \(sql)
            TCCSQL
            """
            return Sh.runAsAdmin(script: script)
        }
        return Sh.run("/usr/bin/sqlite3", [db.path, sql])
    }

    static func restartTCCD(needAdmin: Bool) -> ProcResult {
        if needAdmin {
            return Sh.runAsAdmin(script: "#!/bin/sh\n/usr/bin/killall tccd 2>/dev/null; exit 0\n")
        }
        return Sh.run("/usr/bin/killall", ["tccd"])
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
