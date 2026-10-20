# TCC Helper

**中文** · [English](#english)

把「已授权」条目直接写进 macOS 的 TCC 数据库，绕过权限弹窗。

![界面](screenshot.png)

## 解决什么问题

关闭了 AMFI 的黑苹果（`boot-args` 里有 `amfi=0x80`）上，macOS 不再弹权限窗口，也不会生成授权条目——
麦克风、摄像头、系统音频、辅助功能这些权限永远申请不下来，App 功能直接残废。

TCC Helper 反过来做：读每个 App 的 `Info.plist`，反推它声明了哪些权限，再把对应条目写进 TCC 数据库。

## 怎么用

**一键授权**——点一下，自动扫描已安装的应用 → 找出还缺的权限 → 一次事务写完 → 重启权限服务。

- 用户库（麦克风 / 摄像头 / 音频采集 / 蓝牙）不需要密码
- 系统库（辅助功能 / 系统音频录制）会要一次管理员密码

**高级模式**——手动选数据库、挑目标应用、指定服务，预演 / 授权 / 撤销 / 查看现有条目。

## 覆盖范围

| 数据库 | 权限 |
|---|---|
| 用户库 | 麦克风、摄像头、系统音频采集、蓝牙、自动化、照片、通讯录、日历、文件夹访问 |
| 系统库 | 辅助功能、屏幕录制、系统音频录制（macOS 15 起与屏幕录制共用 `ScreenCapture`） |

会自动识别 `.app` / `.driver` / `.xpc` / `.appex` 包里的组件——SoundSource 的 ARK 驱动就藏在
`ARK.driver/Contents/Resources/` 里。

## 注意

- **条目不持久**：系统更新、`tccutil reset`、清理工具都会抹掉，需要重跑
- **本地网络**不在 TCC 数据库里（由 nehelper 管理），这个工具管不了
- 这是有意降低系统安全边界的操作，只给确实需要的 App 授权
- 本 App 自身需要「完全磁盘访问权限」才能读写 `TCC.db`

## 下载

[Releases](https://github.com/GeekAudio/tcc-helper/releases/latest) · 需要 macOS 13+

ad-hoc 签名（本机没有 Developer ID，未经公证）。首次打开 macOS 会拦下来，提示「无法打开，因为 Apple
无法验证此 App 是否包含恶意软件」。

**macOS 15 起「右键 → 打开」已经失效**，请走这里：

1. 打开 **系统设置 → 隐私与安全性**
2. 往下滚到 **安全性**，会看到一行「已阻止使用 TCC Helper，因为来自身份不明的开发者」
3. 点 **仍要打开**，输入登录密码 / Touch ID 确认
4. 再双击一次 App，弹窗里选 **打开**

如果提示的是「已损坏，无法打开，你应该将它移到废纸篓」，那是下载时带的隔离标记没清掉，终端跑一行：

```sh
xattr -dr com.apple.quarantine "/Applications/TCC Helper.app"
```

---

## English

Writes "allowed" entries straight into the macOS TCC (Transparency, Consent, and Control) database,
bypassing the permission dialogs.

### Why it exists

On hackintosh machines with AMFI disabled (`amfi=0x80`), macOS stops showing permission prompts and
never creates the authorization records. Microphone, camera, system audio and accessibility stay
permanently denied, and apps quietly lose functionality.

TCC Helper works backwards: it reads each app's `Info.plist` to infer which permissions it declares,
then writes the corresponding rows into the TCC database.

### Usage

- **Grant All** — one click: scan installed apps, find what is missing, write everything in a single
  transaction, restart the permission service. The user database needs no password; the system
  database asks for an admin password once.
- **Advanced** — pick the database, target app and service manually; preview, grant, revoke and
  inspect existing entries.

### Scope

| Database | Permissions |
|---|---|
| User | Microphone, camera, system audio capture, Bluetooth, automation, photos, contacts, calendars, folder access |
| System | Accessibility, screen recording, system audio recording (shares `ScreenCapture` since macOS 15) |

Components inside `.app`, `.driver`, `.xpc` and `.appex` bundles are detected automatically — the ARK
driver used by SoundSource lives inside `ARK.driver/Contents/Resources/`.

### Caveats

- Entries do not survive OS updates, `tccutil reset`, or cleanup tools — re-run when needed.
- Local Network is not stored in TCC (managed by nehelper); it cannot be granted this way.
- This intentionally lowers the system's security boundary. Only grant what you actually need.
- The app itself needs Full Disk Access to read and write `TCC.db`.

### Download

[Releases](https://github.com/GeekAudio/tcc-helper/releases/latest) · macOS 13+

Ad-hoc signed (no Developer ID, not notarized), so macOS blocks it on first launch with *"Apple could not
verify that TCC Helper is free of malware."*

**Right-click → Open stopped working in macOS 15.** Do this instead:

1. Open **System Settings → Privacy & Security**
2. Scroll down to **Security** — you'll see *"TCC Helper was blocked because it is from an unidentified developer"*
3. Click **Open Anyway**, then authenticate with your password / Touch ID
4. Double-click the app again and choose **Open**

If macOS instead says the app *"is damaged and can't be opened"*, the quarantine flag survived the download —
clear it in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/TCC Helper.app"
```
