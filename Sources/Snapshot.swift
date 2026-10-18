// Snapshot.swift —— 离屏渲染界面截图（仅开发时用）
//
// 正常构建不参与编译；只有在 swiftc 加 -D SNAPSHOT 时才编进来：
//   swiftc -D SNAPSHOT ... Sources/*.swift -o /tmp/snapshot
//   /tmp/snapshot
// 产物：/tmp/tcc-zh.png、/tmp/tcc-en.png、/tmp/tcc-adv.png

#if SNAPSHOT
import SwiftUI
import AppKit

@main
struct SnapshotTool {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        _ = app

        render("zh", "/tmp/tcc-zh.png")
        render("en", "/tmp/tcc-en.png")
        renderAdvanced("zh", "/tmp/tcc-adv-zh.png")
        renderButton("/tmp/tcc-btn.png")
        renderConfetti("/tmp/tcc-confetti.png")
        print("done")
    }

    /// 渲染彩带爆发 0.35 秒时的形态
    @MainActor
    static func renderConfetti(_ path: String) {
        let view = ConfettiBurst(start: Date().addingTimeInterval(-0.35))
            .frame(width: 380, height: 380)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: confetti")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// 渲染写入中的按钮，用来检查星光/进度环效果
    @MainActor
    static func renderButton(_ path: String) {
        let m = GrantModel()
        m.stage = .applying
        m.progress = 0.62
        let store = LangStore()
        let view = GrantButton(model: m)
            .environmentObject(store)
            .padding(90)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: button")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    @MainActor
    static func renderAdvanced(_ langCode: String, _ path: String) {
        UserDefaults.standard.set(langCode, forKey: "tcchelper.lang")
        let store = LangStore()
        let view = AdvancedView().environmentObject(store)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: advanced")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    @MainActor
    static func render(_ langCode: String, _ path: String) {
        UserDefaults.standard.set(langCode, forKey: "tcchelper.lang")

        let view = RootView()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: \(langCode)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        } catch {
            print("write failed: \(error)")
        }
    }
}
#endif
