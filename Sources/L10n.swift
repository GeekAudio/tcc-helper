// L10n.swift —— 双语支持（中 / 英）
//
// 设计：所有界面文案都走字典，视图里只写 key。
//       语言默认跟随系统，也可以在界面上手动锁定。
//       服务名单独一张表：中文沿用 ServiceCatalog.curated，英文在这里补。

import Foundation

enum Lang {
    case zh
    case en
}

// MARK: - 文案

enum CopyTable {
    static let zh: [String: String] = [
        // 主界面
        "tagline":          "一键补全系统权限",
        "lead":             "为所有已安装的应用补上缺失的隐私权限，不用逐个弹窗。",
        "grantAll":         "一键授权",
        "scanning":         "正在扫描",
        "writing":          "正在写入",
        "doneShort":        "已授权 %d 项",
        "nothingShort":     "无需处理",
        "retry":            "重试",
        "ready":            "准备就绪",
        "readyHint":        "点一下，自动找出缺权限的应用并写入。",
        "scanningHint":     "正在检查已安装的应用…",
        "foundHint":        "发现 %d 个应用缺 %d 项权限",
        "applyingHint":     "正在写入权限数据库，系统可能会要求输入管理员密码…",
        "doneHint":         "完成：%d 个应用，%d 项权限",
        "allGoodHint":      "所有应用声明的权限都已就绪。",
        "failedHint":       "写入失败，请展开高级模式查看详情。",
        "needFDA":          "读不到权限数据库，需要「完全磁盘访问权限」。",
        "advanced":         "高级模式",
        "language":         "语言",
        "followSystem":     "跟随系统",
        "chinese":          "简体中文",
        "english":          "English",

        // 高级模式 · 通用
        "advancedTitle":    "高级模式",
        "close":            "关闭",
        "database":         "权限数据库",
        "userDB":           "用户数据库",
        "systemDB":         "系统数据库",
        "userDBHint":       "麦克风、摄像头、音频采集、蓝牙等",
        "systemDBHint":     "辅助功能、屏幕录制等（写入需要管理员）",
        "recheck":          "重新自检",
        "selfFDA":          "授予自身完全磁盘访问权限",
        "openPrivacy":      "打开隐私设置",
        "dbReadWrite":      "可读写，共 %d 条",
        "dbReadOnly":       "可读不可写，共 %d 条（文件属主是 root）",
        "dbUnreadable":     "无法读取",
        "dbMissing":        "文件不存在",
        "dbChecking":       "正在检查…",
        "dbAdminNote":      "系统数据库属于 root，写入时会要求输入管理员密码；用户数据库读不了，才需要给本应用完全磁盘访问权限。",
        "dbSystemHint":     "屏幕录制、系统音频录制、辅助功能都在系统数据库里，要授权请先切到这里。",

        // 高级模式 · 目标应用
        "targetApp":        "目标应用",
        "dropHint":         "把应用拖到这里",
        "dropSubHint":      "也可以进入应用包内部，选择真正申请权限的子组件",
        "choose":           "选择…",
        "runningApps":      "运行中的应用…",
        "clear":            "清除",
        "path":             "路径",
        "identifier":       "标识",
        "version":          "版本",
        "signature":        "签名",
        "issuer":           "签发者",
        "signedDR":         "完整签名",
        "noDR":             "无完整签名，按标识匹配",
        "byPath":           "按路径授权，而不是按应用标识",
        "empty":            "无",

        // 高级模式 · 权限服务
        "service":          "权限服务",
        "serviceFilter":    "筛选权限",
        "serviceNote":      "清单在运行时从系统权限服务里抽取，系统认的都在。",
        "current":          "当前",

        // 高级模式 · 操作
        "actions":          "操作",
        "preview":          "预演",
        "grant":            "授权",
        "revoke":           "撤销",
        "refresh":          "刷新",
        "pickTargetFirst":  "请先选择目标应用。",
        "backupNote":       "写入前会自动备份数据库，写完重启权限服务。",
        "backupDone":       "已备份数据库",
        "backupFailed":     "备份失败，可能缺少完全磁盘访问权限",
        "writeOK":          "写入成功",
        "writeFailed":      "写入失败",
        "revokeOK":         "已撤销该条目",
        "revokedNone":      "该应用在此数据库中没有条目",
        "previewOnly":      "预演完成，未写入数据库",
        "verified":         "回读确认：条目已被系统接受",
        "notVerified":      "回读没看到条目，可能被判为无效清掉了",

        // 高级模式 · 条目
        "entries":          "当前条目",
        "noEntries":        "该应用在此数据库中没有条目。",
        "allowed":          "已允许",
        "denied":           "已拒绝",
        "undecided":        "未决定",
        "unknown":          "未知",

        // 弹窗
        "runningTitle":     "选择运行中的应用",
        "runningInfo":      "只列出有应用标识的进程，包内后台组件也在其中。",
        "appPickMessage":   "选择一个应用；需要给包内子组件授权时，可以进到它内部去选。",
        "ok":               "确定",
        "cancel":           "取消",
    ]

    static let en: [String: String] = [
        // Main
        "tagline":          "One-click permission repair",
        "lead":             "Fills in missing permissions for every installed app.",
        "grantAll":         "Grant All",
        "scanning":         "Scanning",
        "writing":          "Writing",
        "doneShort":        "%d granted",
        "nothingShort":     "All set",
        "retry":            "Retry",
        "ready":            "Ready",
        "readyHint":        "One click finds apps with missing permissions and writes them in.",
        "scanningHint":     "Checking installed applications…",
        "foundHint":        "%d apps · %d permissions missing",
        "applyingHint":     "Writing to the permission database. macOS may ask for an administrator password…",
        "doneHint":         "Done: %d apps, %d permissions",
        "allGoodHint":      "Every declared permission is already in place.",
        "failedHint":       "Write failed. Open Advanced for details.",
        "needFDA":          "The permission database is unreadable. Full Disk Access is required.",
        "advanced":         "Advanced",
        "language":         "Language",
        "followSystem":     "Follow System",
        "chinese":          "简体中文",
        "english":          "English",

        // Advanced · shared
        "advancedTitle":    "Advanced",
        "close":            "Close",
        "database":         "Permission Database",
        "userDB":           "User Database",
        "systemDB":         "System Database",
        "userDBHint":       "Microphone, camera, audio capture, Bluetooth",
        "systemDBHint":     "Accessibility, screen recording (requires admin)",
        "recheck":          "Re-check",
        "selfFDA":          "Grant Full Disk Access to This App",
        "openPrivacy":      "Open Privacy Settings",
        "dbReadWrite":      "Read-write, %d entries",
        "dbReadOnly":       "Read-only, %d entries (owned by root)",
        "dbUnreadable":     "Unreadable",
        "dbMissing":        "File not found",
        "dbChecking":       "Checking…",
        "dbAdminNote":      "The system database is owned by root, so writing to it asks for an administrator password. Full Disk Access is only needed when the user database cannot be read.",
        "dbSystemHint":     "Screen recording, system audio recording and accessibility live in the system database — switch here to grant them.",

        // Advanced · target
        "targetApp":        "Target App",
        "dropHint":         "Drop an app here",
        "dropSubHint":      "You can also go inside a bundle and pick the component that actually asks for permission",
        "choose":           "Choose…",
        "runningApps":      "Running Apps…",
        "clear":            "Clear",
        "path":             "Path",
        "identifier":       "Identifier",
        "version":          "Version",
        "signature":        "Signature",
        "issuer":           "Issuer",
        "signedDR":         "Signed, designated requirement available",
        "noDR":             "No designated requirement, matched by identifier",
        "byPath":           "Authorize by path instead of bundle identifier",
        "empty":            "None",

        // Advanced · service
        "service":          "Permission",
        "serviceFilter":    "Filter permissions",
        "serviceNote":      "The list is extracted from the system permission service at runtime, so it covers everything macOS knows.",
        "current":          "Current",

        // Advanced · actions
        "actions":          "Actions",
        "preview":          "Preview",
        "grant":            "Grant",
        "revoke":           "Revoke",
        "refresh":          "Refresh",
        "pickTargetFirst":  "Pick a target app first.",
        "backupNote":       "The database is backed up before every write, and the permission service restarts afterwards.",
        "backupDone":       "Database backed up",
        "backupFailed":     "Backup failed — Full Disk Access may be missing",
        "writeOK":          "Written successfully",
        "writeFailed":      "Write failed",
        "revokeOK":         "Entry removed",
        "revokedNone":      "This app has no entry in this database",
        "previewOnly":      "Preview finished, nothing written",
        "verified":         "Read-back confirmed: the entry was accepted",
        "notVerified":      "Read-back found nothing — the entry may have been discarded",

        // Advanced · entries
        "entries":          "Existing Entries",
        "noEntries":        "This app has no entries in this database.",
        "allowed":          "Allowed",
        "denied":           "Denied",
        "undecided":        "Undecided",
        "unknown":          "Unknown",

        // Dialogs
        "runningTitle":     "Choose a Running App",
        "runningInfo":      "Only processes with a bundle identifier are listed, including background helpers.",
        "appPickMessage":   "Pick an app. To authorize a component inside a bundle, navigate into it.",
        "ok":               "OK",
        "cancel":           "Cancel",
    ]
}

// MARK: - 服务名

enum ServiceName {
    /// 英文名。中文名沿用 ServiceCatalog.curated，这里不重复。
    static let en: [String: String] = [
        "kTCCServiceMicrophone":                    "Microphone",
        "kTCCServiceCamera":                        "Camera",
        "kTCCServiceAudioCapture":                  "System Audio Capture",
        "kTCCServiceScreenCapture":                 "Screen Recording",
        "kTCCServiceAccessibility":                 "Accessibility",
        "kTCCServiceListenEvent":                   "Input Monitoring",
        "kTCCServicePostEvent":                     "Post Events",
        "kTCCServiceAppleEvents":                   "Automation (Apple Events)",
        "kTCCServiceSystemPolicyAllFiles":          "Full Disk Access",
        "kTCCServiceDeveloperTool":                 "Developer Tools",
        "kTCCServiceBluetoothAlways":               "Bluetooth",
        "kTCCServiceBluetoothPeripheral":           "Bluetooth Peripheral",
        "kTCCServiceMediaLibrary":                  "Media & Apple Music",
        "kTCCServicePhotos":                        "Photos (Read)",
        "kTCCServicePhotosAdd":                     "Photos (Write)",
        "kTCCServiceContactsFull":                  "Contacts (Full)",
        "kTCCServiceContactsLimited":               "Contacts (Limited)",
        "kTCCServiceCalendar":                      "Calendar",
        "kTCCServiceReminders":                     "Reminders",
        "kTCCServiceMotion":                        "Motion & Fitness",
        "kTCCServiceFocusStatus":                   "Focus Status",
        "kTCCServicePasteboard":                    "Pasteboard",
        "kTCCServiceMicrophoneInjection":           "Microphone Injection",
        "kTCCServiceRemoteDesktop":                 "Remote Desktop",
        "kTCCServiceEndpointSecurityClient":        "Endpoint Security",
        "kTCCServiceSystemPolicyDesktopFolder":     "Desktop Folder",
        "kTCCServiceSystemPolicyDocumentsFolder":   "Documents Folder",
        "kTCCServiceSystemPolicyDownloadsFolder":   "Downloads Folder",
        "kTCCServiceSystemPolicyNetworkVolumes":    "Network Volumes",
        "kTCCServiceSystemPolicyRemovableVolumes":  "Removable Volumes",
        "kTCCServiceSystemPolicyAppBundles":        "App Management",
        "kTCCServiceSystemPolicyAppData":           "App Data",
        "kTCCServiceSystemPolicySysAdminFiles":     "System Administration Files",
        "kTCCServiceLocation":                      "Location",
        "kTCCServiceSpeechRecognition":             "Speech Recognition",
        "kTCCServiceUserTracking":                  "User Tracking",
        "kTCCServiceFileProviderDomain":            "File Provider Domain",
        "kTCCServiceFileProviderPresence":          "File Provider Presence",
        "kTCCServiceAccessorySetup":                "Accessory Setup",
    ]

    /// 显示名。中文优先用 curated 里的译名，英文优先用上表；
    /// 都没有就把 kTCCService 后面的驼峰拆成词（技术标识，不硬造翻译）。
    static func display(_ id: String, _ lang: Lang) -> String {
        switch lang {
        case .zh:
            let n = ServiceCatalog.name(for: id)
            if !n.isEmpty { return n }
            return humanized(id)
        case .en:
            if let n = en[id] { return n }
            return humanized(id)
        }
    }

    static func humanized(_ id: String) -> String {
        var s = id
        if s.hasPrefix("kTCCService") { s = String(s.dropFirst("kTCCService".count)) }
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0, ch.isUppercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

// MARK: - 语言状态

final class LangStore: ObservableObject {
    enum Choice: String, CaseIterable {
        case system, zh, en
    }

    private static let key = "tcchelper.lang"

    @Published var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        choice = Choice(rawValue: raw) ?? .system
    }

    var lang: Lang {
        switch choice {
        case .zh: return .zh
        case .en: return .en
        case .system:
            let p = Locale.preferredLanguages.first ?? "en"
            return p.hasPrefix("zh") ? .zh : .en
        }
    }

    /// 取文案；缺 key 时回退到 key 本身，方便发现漏翻。
    func t(_ key: String) -> String {
        let table = lang == .zh ? CopyTable.zh : CopyTable.en
        return table[key] ?? key
    }

    /// 带占位符的文案（%d 之类）
    func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    func service(_ id: String) -> String {
        ServiceName.display(id, lang)
    }

    func choiceLabel(_ c: Choice) -> String {
        switch c {
        case .system: return t("followSystem")
        case .zh: return t("chinese")
        case .en: return t("english")
        }
    }
}
