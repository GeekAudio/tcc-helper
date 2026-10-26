// Computer Use 的权限属于独立 helper，不属于 ChatGPT / Codex 主应用。
import Foundation
import AppKit

enum ComputerUse {
    static let bundleID = "com.openai.sky.CUAService"
    static let requiredServices = ["kTCCServiceAccessibility", "kTCCServiceScreenCapture"]

    struct Status {
        var path: String?
        var readable = false
        var granted: Set<String> = []
        var ready: Bool { path != nil && readable && Set(requiredServices).isSubset(of: granted) }
    }

    enum Failure: String {
        case notFound = "cuNotFound"
        case unsigned = "cuUnsigned"
        case signature = "cuSignatureFailed"
        case write = "cuWriteFailed"
        case verification = "cuVerifyFailed"
    }

    struct AuthorizationResult {
        var status: Status
        var failure: Failure?
        var detail = ""
        var succeeded: Bool { failure == nil && status.ready }
    }

    static func isHelper(at path: String) -> Bool {
        guard let info = AutoGrant.plist(path + "/Contents/Info.plist"),
              info["CFBundleIdentifier"] as? String == bundleID,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/") else { return false }
        return FileManager.default.isExecutableFile(atPath: path + "/Contents/MacOS/" + executable)
    }

    /// 不依赖应用正在运行，也不依赖易变的应用名称；兼容自定义 CODEX_HOME。
    static func discover(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runningPaths: [String] = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path },
        registeredPath: String? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    ) -> [String] {
        var candidates = runningPaths
        if let registeredPath { candidates.append(registeredPath) }
        var dirs: [String] = []
        if let customHome = environment["CODEX_HOME"], !customHome.isEmpty {
            dirs.append((customHome as NSString).expandingTildeInPath + "/computer-use")
        }
        dirs += [home + "/.codex/computer-use", "/Applications", home + "/Applications"]
        for dir in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                candidates.append(dir + "/" + name)
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted, isHelper(at: resolved) else { return nil }
            return resolved
        }
    }

    static func status(path: String?, databasePath: String = TCCDB.system.path) -> Status {
        var status = Status(path: path)
        guard path != nil else { return status }
        let query = "SELECT service FROM access WHERE client='\(bundleID)' AND client_type=0 "
            + "AND indirect_object_identifier='UNUSED' AND auth_value=2;"
        let result = Sh.run("/usr/bin/sqlite3", ["-readonly", databasePath, query])
        status.readable = result.status == 0
        if status.readable {
            status.granted = Set(result.out.split(separator: "\n").map(String.init))
        }
        return status
    }

    /// 只补电脑操作必需的两项系统权限，不附带通讯录、日历或完全磁盘访问。
    static func authorize(path: String) -> AuthorizationResult {
        guard isHelper(at: path) else {
            return AuthorizationResult(status: Status(path: nil), failure: .notFound)
        }
        let info = TCCCore.inspect(path: path)
        guard info.hasDR else {
            return AuthorizationResult(status: status(path: path), failure: .unsigned)
        }
        let (blob, note) = TCCCore.makeCsreq(dr: info.dr)
        guard let blob, blob.prefix(4) == Data([0xfa, 0xde, 0x0c, 0x00]) else {
            return AuthorizationResult(status: status(path: path), failure: .signature, detail: note)
        }
        let temporary = NSTemporaryDirectory() + "tcc-computer-use-\(UUID().uuidString).bin"
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        do {
            try blob.write(to: URL(fileURLWithPath: temporary), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
        } catch {
            return AuthorizationResult(status: status(path: path), failure: .signature,
                                       detail: error.localizedDescription)
        }
        let sql = "BEGIN IMMEDIATE;\n" + requiredServices.map {
            TCCCore.grantSQL(service: $0, client: bundleID, clientType: 0, csreqPath: temporary)
        }.joined(separator: "\n") + "\nCOMMIT;"
        let result = TCCCore.apply(sql: sql, db: .system, needAdmin: true)
        guard result.status == 0 else {
            return AuthorizationResult(status: status(path: path), failure: .write, detail: result.combined)
        }
        _ = TCCCore.restartTCCD(needAdmin: false)
        let after = status(path: path)
        // 不只看进程返回值：确认允许状态和实际写入的签名同时匹配。
        let hex = blob.map { String(format: "%02X", $0) }.joined()
        let services = requiredServices.map { "'\($0)'" }.joined(separator: ",")
        let verified = Sh.run("/usr/bin/sqlite3", ["-readonly", TCCDB.system.path,
            "SELECT count(*) FROM access WHERE client='\(bundleID)' AND client_type=0 "
            + "AND indirect_object_identifier='UNUSED' AND auth_value=2 "
            + "AND service IN (\(services)) AND hex(csreq)='\(hex)';"])
        guard after.ready, verified.status == 0,
              Int(verified.out.trimmingCharacters(in: .whitespacesAndNewlines)) == requiredServices.count else {
            return AuthorizationResult(status: after, failure: .verification)
        }
        return AuthorizationResult(status: after)
    }
}
