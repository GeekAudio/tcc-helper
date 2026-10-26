import Foundation

let fm = FileManager.default
let root = NSTemporaryDirectory() + "tcc-regression-\(UUID().uuidString)"
try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: root) }

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS \(message)")
}

func fixture(_ path: String, id: String, descriptions: [String: String] = [:]) throws {
    try fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
    var plist = descriptions
    plist["CFBundleIdentifier"] = id
    plist["CFBundleExecutable"] = "helper"
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path + "/Contents/MacOS/helper"))
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path + "/Contents/MacOS/helper")
}

let helper = root + "/home/.codex/computer-use/Renamed Helper.app"
try fixture(helper, id: ComputerUse.bundleID)
check(ComputerUse.isHelper(at: helper), "helper identified without relying on its filename")
check(Set(AutoGrant.systemServices(forBundle: helper)) == Set(ComputerUse.requiredServices),
      "helper without usage descriptions still needs both system permissions")
check(AutoGrant.services(forBundle: helper).isEmpty, "dedicated profile adds no unrelated user permissions")
check(ComputerUse.authorize(path: helper).failure == .unsigned,
      "unsigned helper rejected without requesting administrator access")

let host = root + "/ChatGPT.app"
try fixture(host, id: "com.openai.codex")
check(!ComputerUse.isHelper(at: host), "host app cannot be mistaken for the actual helper")
check(AutoGrant.systemServices(forBundle: host).isEmpty, "host app receives no Computer Use preset")
let rejected = ComputerUse.authorize(path: host)
check(rejected.failure == .notFound, "invalid authorization target rejected before touching a database")

let audio = root + "/Audio.app"
try fixture(audio, id: "test.audio", descriptions: ["NSAudioCaptureUsageDescription": "Audio"])
check(AutoGrant.systemServices(forBundle: audio) == ["kTCCServiceScreenCapture"],
      "existing system audio permission detection preserved")
check(AutoGrant.services(forBundle: audio) == ["kTCCServiceAudioCapture"],
      "existing user audio permission detection preserved")

let found = ComputerUse.discover(home: root + "/home", environment: [:], runningPaths: [], registeredPath: nil)
check(found == [helper], "stopped helper discovered under the default home")
let custom = root + "/custom/computer-use/ChatGPT Computer Use.app"
try fixture(custom, id: ComputerUse.bundleID)
let customFound = ComputerUse.discover(home: root + "/empty", environment: ["CODEX_HOME": root + "/custom"],
                                      runningPaths: [], registeredPath: nil)
check(customFound == [custom], "custom CODEX_HOME is supported without a running app")
let deduplicated = ComputerUse.discover(home: root + "/home", environment: [:],
                                       runningPaths: [helper, helper], registeredPath: helper)
check(deduplicated == [helper], "running, registered and on-disk discoveries are deduplicated")

let db = root + "/permissions.db"
let setup = Sh.run("/usr/bin/sqlite3", [db, "CREATE TABLE access(service TEXT, client TEXT, client_type INTEGER, "
    + "auth_value INTEGER, indirect_object_identifier TEXT); "
    + "INSERT INTO access VALUES('kTCCServiceAccessibility','\(ComputerUse.bundleID)',0,2,'UNUSED'); "
    + "INSERT INTO access VALUES('kTCCServiceScreenCapture','com.openai.codex',0,2,'UNUSED');"])
check(setup.status == 0, "test database created")
let missing = ComputerUse.status(path: helper, databasePath: db)
check(missing.readable && !missing.ready && missing.granted == ["kTCCServiceAccessibility"],
      "host permission does not satisfy a missing helper permission")
_ = Sh.run("/usr/bin/sqlite3", [db,
    "INSERT INTO access VALUES('kTCCServiceScreenCapture','\(ComputerUse.bundleID)',0,0,'UNUSED');"])
check(!ComputerUse.status(path: helper, databasePath: db).ready, "denied permission is not reported as ready")
_ = Sh.run("/usr/bin/sqlite3", [db, "UPDATE access SET auth_value=2 WHERE client='\(ComputerUse.bundleID)';"])
check(ComputerUse.status(path: helper, databasePath: db).ready, "both helper permissions report ready")
check(!ComputerUse.status(path: helper, databasePath: root + "/absent.db").readable,
      "unreadable database is distinct from ready")
check(!fm.fileExists(atPath: root + "/absent.db"), "status inspection never creates a missing database")

// 用临时库运行与提权完全相同的写入脚本，验证事务失败不会被重启命令掩盖。
let backup = root + "/backup's file.db"
let restartMarker = root + "/restarted"
func runWrite(_ sql: String, backupPath: String) -> ProcResult {
    let script = TCCCore.privilegedWriteScript(sql: sql, databasePath: db,
        backupPath: backupPath, restartCommand: "/usr/bin/touch " + TCCCore.shellQuote(restartMarker))
    return Sh.run("/bin/sh", [], stdin: Data(script.utf8))
}
let failure = runWrite("BEGIN; UPDATE access SET auth_value=0; INVALID SQL; COMMIT;", backupPath: backup)
check(failure.status != 0, "SQL failure propagates as a failure")
check(!fm.fileExists(atPath: restartMarker), "restart never masks a failed write")
check(ComputerUse.status(path: helper, databasePath: db).ready, "failed transaction leaves original permissions intact")
check(fm.fileExists(atPath: backup), "database was backed up before attempting to write")
check(Sh.run("/usr/bin/sqlite3", [backup, "PRAGMA integrity_check;"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok",
      "backup is a valid SQLite snapshot")
let backupFailure = runWrite("DELETE FROM access;", backupPath: root + "/missing/directory/backup.db")
check(backupFailure.status != 0 && ComputerUse.status(path: helper, databasePath: db).ready,
      "backup failure stops authorization before any write")
let success = runWrite("BEGIN; UPDATE access SET auth_value=0; COMMIT;", backupPath: root + "/second.db")
check(success.status == 0 && fm.fileExists(atPath: restartMarker), "successful write reaches the restart step")
check(!ComputerUse.status(path: helper, databasePath: db).ready, "successful write changes the test database")
print("All Computer Use regression checks passed. No system permissions were changed.")
