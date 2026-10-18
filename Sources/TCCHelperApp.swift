// TCC Helper —— 主界面
//
// 设计原则：
//   · 默认只有一个按钮。点一下：扫描 → 写入 → 完成，全过程有动画。
//   · 所有手动能力收进「高级模式」，主界面不出现。
//   · 不写日志。每一步的结果直接体现在按钮和状态行上。
//   · 文案全部走 L10n，界面不会中英混排。

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 主流程

enum GrantStage: Equatable {
    case idle
    case scanning
    case applying
    case done(apps: Int, granted: Int)
    case nothing
    case failed(String)
}

@MainActor
final class GrantModel: ObservableObject {
    @Published var stage: GrantStage = .idle
    @Published var progress: Double = 0
    @Published var pendingApps = 0
    @Published var pendingMissing = 0

    private var ticker: Timer?

    var busy: Bool {
        switch stage {
        case .scanning, .applying: return true
        default: return false
        }
    }

    func run() {
        guard !busy else { return }
        stage = .scanning
        progress = 0
        pendingApps = 0
        pendingMissing = 0
        startTicker()

        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                AutoGrant.scan(roots: ["/Applications"],
                               includeLaunchd: true,
                               includeRunning: true,
                               includeHelpers: true)
            }.value

            guard let self else { return }
            let todo = found.filter { !$0.missing.isEmpty }
            self.pendingApps = todo.count
            self.pendingMissing = todo.reduce(0) { $0 + $1.missing.count }

            if todo.isEmpty {
                self.finish(.nothing)
                return
            }

            self.stage = .applying
            self.progress = 0.08

            let enriched = await Task.detached(priority: .userInitiated) {
                AutoGrant.enrichAll(todo)
            }.value

            let res = await Task.detached(priority: .userInitiated) {
                AutoGrant.applyBatch(enriched, db: .user)
            }.value

            if res.granted == 0 && res.failed > 0 {
                self.finish(.failed(res.log.last ?? ""))
            } else {
                self.finish(.done(apps: todo.count, granted: res.granted))
            }
        }
    }

    func reset() {
        guard !busy else { return }
        stage = .idle
        progress = 0
    }

    private func finish(_ s: GrantStage) {
        ticker?.invalidate()
        ticker = nil
        withAnimation(.easeOut(duration: 0.4)) { progress = 1 }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { stage = s }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.stage == .applying else { return }
                if self.progress < 0.9 {
                    self.progress += (0.92 - self.progress) * 0.055
                }
            }
        }
    }
}

// MARK: - 大按钮

struct GrantButton: View {
    @ObservedObject var model: GrantModel
    @EnvironmentObject var lang: LangStore
    @State private var hover = false

    private var palette: [Color] {
        switch model.stage {
        case .done, .nothing:
            return [Color(red: 0.24, green: 0.76, blue: 0.50), Color(red: 0.09, green: 0.60, blue: 0.44)]
        case .failed:
            return [Color(red: 0.94, green: 0.40, blue: 0.36), Color(red: 0.78, green: 0.22, blue: 0.26)]
        default:
            return [Color(red: 0.36, green: 0.51, blue: 0.99), Color(red: 0.56, green: 0.34, blue: 0.95)]
        }
    }

    var body: some View {
        Button {
            model.run()
        } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.busy)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    halo(t: t)
                    scanArc(t: t)
                    progressRing
                    disc
                    face(t: t)
                }
                .frame(width: 204, height: 204)
            }
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
        .scaleEffect(hover && !model.busy ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.22), value: hover)
    }

    // 呼吸光晕
    private func halo(t: TimeInterval) -> some View {
        let amp = model.busy ? 0.055 : 0.018
        let speed = model.busy ? 2.0 : 0.9
        return Circle()
            .fill(
                RadialGradient(colors: [palette[0].opacity(0.50), palette[0].opacity(0)],
                               center: .center, startRadius: 26, endRadius: 84)
            )
            .scaleEffect(1 + amp * sin(t * speed))
            .blur(radius: 7)
    }

    // 扫描阶段：一段绕圈的弧
    @ViewBuilder private func scanArc(t: TimeInterval) -> some View {
        if case .scanning = model.stage {
            let cycle = t.truncatingRemainder(dividingBy: 1.3) / 1.3
            Circle()
                .trim(from: 0, to: 0.24)
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [palette[0].opacity(0), palette[0], palette[1].opacity(0.9)]),
                                    center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(cycle * 360))
                .padding(-13)
                .frame(width: 180, height: 180)
        }
    }

    // 写入阶段：确定进度环
    @ViewBuilder private var progressRing: some View {
        if case .applying = model.stage {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(
                        AngularGradient(gradient: Gradient(colors: [palette[0], palette[1]]), center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.22), value: model.progress)
            }
            .padding(-13)
            .frame(width: 180, height: 180)
        }
    }

    private var disc: some View {
        Circle()
            .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Circle().stroke(
                    LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .shadow(color: palette[0].opacity(hover ? 0.45 : 0.32), radius: hover ? 28 : 20, y: 12)
            .frame(width: 156, height: 156)
            .animation(.easeOut(duration: 0.25), value: hover)
    }

    @ViewBuilder private func face(t: TimeInterval) -> some View {
        VStack(spacing: 7) {
            switch model.stage {
            case .idle:
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 29, weight: .regular))
                Text(lang.t("grantAll"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            case .scanning:
                Image(systemName: "viewfinder")
                    .font(.system(size: 28, weight: .medium))
                Text(lang.t("scanning"))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                Dots(t: t)
            case .applying:
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(model.progress * 100))")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.system(size: 16, weight: .semibold, design: .rounded))
                        .opacity(0.75)
                }
                Text(lang.t("writing"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .opacity(0.85)
            case .done(_, let granted):
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                Text(lang.f("doneShort", granted))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .opacity(0.92)
            case .nothing:
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold))
                Text(lang.t("nothingShort"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .opacity(0.92)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 42, weight: .bold))
                Text(lang.t("retry"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .opacity(0.92)
            }
        }
        .foregroundStyle(.white)
    }
}

struct Dots: View {
    let t: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                let v = sin(t * 4.2 - Double(i) * 0.8)
                Circle()
                    .fill(Color.white.opacity(0.30 + 0.60 * max(0, v)))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1.0)
            .animation(.spring(response: 0.26, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

// MARK: - 主界面

struct RootView: View {
    @StateObject private var lang = LangStore()
    @StateObject private var model = GrantModel()
    @State private var showAdvanced = false
    @State private var showLang = false

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                header
                    .padding(.top, 28)
                Spacer(minLength: 6)
                GrantButton(model: model)
                statusLine
                    .padding(.top, 12)
                Spacer(minLength: 6)
                footer
                    .padding(.bottom, 16)
            }
            .frame(width: 372, height: 500)
        }
        .frame(width: 372, height: 500)
        .environmentObject(lang)
        .sheet(isPresented: $showAdvanced) {
            AdvancedView().environmentObject(lang)
        }
    }

    private var header: some View {
        VStack(spacing: 9) {
            Text("TCC HELPER")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(.tertiary)

            Text(lang.t("tagline"))
                .font(.system(size: lang.lang == .zh ? 22 : 18.5, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(lang.t("lead"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
    }

    @ViewBuilder private var statusLine: some View {
        VStack(spacing: 3) {
            switch model.stage {
            case .idle:
                Text(lang.t("ready"))
                    .font(.system(size: 12, weight: .medium))
                Text(lang.t("readyHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .scanning:
                Text(lang.t("scanningHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .applying:
                Text(lang.f("foundHint", model.pendingApps, model.pendingMissing))
                    .font(.system(size: 12, weight: .medium))
                Text(lang.t("applyingHint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            case .done(let apps, let granted):
                Text(lang.f("doneHint", apps, granted))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.10, green: 0.55, blue: 0.38))
            case .nothing:
                Text(lang.t("allGoodHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .failed:
                Text(lang.t("failedHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.stage)
    }

    private var footer: some View {
        HStack {
            Button {
                showAdvanced = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text(lang.t("advanced"))
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Spacer()

            languageMenu
        }
        .padding(.horizontal, 22)
    }

    private var languageMenu: some View {
        Button {
            showLang = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                Text(lang.choiceLabel(lang.choice))
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showLang, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(LangStore.Choice.allCases, id: \.self) { c in
                    Button {
                        lang.choice = c
                        showLang = false
                    } label: {
                        HStack(spacing: 6) {
                            Text(lang.choiceLabel(c))
                                .font(.system(size: 11.5))
                            Spacer(minLength: 14)
                            if lang.choice == c {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 132)
        }
    }
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color(red: 0.42, green: 0.50, blue: 0.98).opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.22),
                startRadius: 10, endRadius: 330
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 入口

#if !SNAPSHOT
@main
struct TCCHelperApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
#endif
