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
            // ★ 两个库都算：旧版只看 missing（用户库），系统库的辅助功能 /
            //   系统音频录制永远漏掉 —— 这正是「授权完还是一堆缺失」的直接原因。
            let todo = found.filter { $0.hasWork }
            self.pendingApps = todo.count
            self.pendingMissing = todo.reduce(0) { $0 + $1.missing.count + $1.systemMissing.count }

            if todo.isEmpty {
                self.finish(.nothing)
                return
            }

            self.stage = .applying
            self.progress = 0.08

            let enriched = await Task.detached(priority: .userInitiated) {
                AutoGrant.enrichAll(todo)
            }.value

            // 第一趟：用户库（麦克风 / 音频采集 / 蓝牙 / 自动化），免密码
            let res = await Task.detached(priority: .userInitiated) {
                AutoGrant.applyBatch(enriched, db: .user)
            }.value
            var granted = res.granted
            var failed = res.failed
            var lastLog = res.log.last ?? ""

            // 第二趟：系统库（辅助功能 / 系统音频录制），一次提权批量写完
            let sysTodo = enriched.filter { !$0.systemMissing.isEmpty }
            if !sysTodo.isEmpty {
                // 进入第二阶段：进度跳一档，配合状态行提示「可能要输密码」
                withAnimation(.easeInOut(duration: 0.45)) {
                    self.progress = max(self.progress, 0.55)
                }
                let res2 = await Task.detached(priority: .userInitiated) {
                    AutoGrant.applyBatch(sysTodo, db: .system)
                }.value
                granted += res2.granted
                failed += res2.failed
                if let l = res2.log.last { lastLog = l }
            }

            if granted == 0 && failed > 0 {
                self.finish(.failed(lastLog))
            } else {
                self.finish(.done(apps: todo.count, granted: granted))
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
                // ★ 不设死上限：一直向 99% 渐近，数字始终在变。
                //   旧版卡在 92% 不动，用户以为卡死了。
                if self.progress < 0.99 {
                    self.progress += (0.99 - self.progress) * 0.03
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
    @State private var burstAt: Date?

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
                        sparkles(t: t)
                        face(t: t)
                    }
                    .frame(width: 204, height: 204)
            }
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
        .scaleEffect(hover && !model.busy ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.22), value: hover)
        // 完成时的彩带：overlay 不参与布局，画布比按钮大一圈，纸片可以飞出按钮外
        .overlay(
            ConfettiBurst(start: burstAt)
                .frame(width: 380, height: 380)
                .allowsHitTesting(false)
        )
        .onChange(of: model.stage) { new in
            if case .done = new {
                burstAt = Date()
            } else {
                burstAt = nil
            }
        }
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

    // 过程星光：只在扫描 / 写入时出现，围着按钮边缘慢慢飘
    @ViewBuilder private func sparkles(t: TimeInterval) -> some View {
        if model.busy {
            SparkleField(t: t,
                         count: model.stage == .applying ? 18 : 12,
                         radius: 0.55...0.98,
                         tint: .white)
                .frame(width: 204, height: 204)
                .allowsHitTesting(false)
        }
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
                .frame(width: 206, height: 206)
        }
    }

    // 写入阶段：确定进度环
    @ViewBuilder private var progressRing: some View {
        if case .applying = model.stage {
            let size: CGFloat = 206
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

                // 进度头：跟着环走的亮点。哪怕百分比只涨 0.5%，
                // 这个点也在往前挪，视觉上不会「停住」。
                Circle()
                    .fill(Color.white)
                    .frame(width: 5.5, height: 5.5)
                    .shadow(color: palette[0].opacity(0.95), radius: 4)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(model.progress * 360))
                    .animation(.easeInOut(duration: 0.22), value: model.progress)
            }
            .frame(width: size, height: size)
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
                    Text("\(min(99, Int(model.progress * 100)))")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.system(size: 16, weight: .semibold, design: .rounded))
                        .opacity(0.75)
                }
                HStack(spacing: 5) {
                    Text(lang.t("writing"))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .opacity(0.85)
                    Dots(t: t)
                }
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

// MARK: - 星光

/// 围着按钮飘的十字星点。用 Canvas 画，几十个粒子也不会掉帧。
struct SparkleField: View {
    let t: TimeInterval
    let count: Int
    let radius: ClosedRange<Double>
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = Double(size.width) / 2

            for i in 0..<count {
                let seed = Double(i + 1)

                // 用无理数做确定性伪随机，保证每帧参数一致
                let a0 = frac(seed * 0.6180339887) * 2 * .pi
                let r0 = radius.lowerBound
                    + (radius.upperBound - radius.lowerBound) * frac(seed * 0.7548776662)
                let speed = 0.20 + 0.28 * frac(seed * 0.5698402910)
                let phase = frac(seed * 0.4142135623)

                let cycle = (t * speed + phase).truncatingRemainder(dividingBy: 1)
                let fade = sin(cycle * .pi)                       // 0 → 1 → 0
                guard fade > 0.02 else { continue }

                let drift = 16 * cycle                            // 慢慢上浮
                let dir: Double = (i % 2 == 0) ? 1 : -1
                let a = a0 + t * 0.10 * dir
                let r = maxR * r0

                let x = c.x + CGFloat(cos(a) * r)
                let y = c.y + CGFloat(sin(a) * r) - CGFloat(drift)

                let s = CGFloat(1.4 + 1.9 * frac(seed * 0.7320508075))
                let op = 0.85 * fade

                // 十字光芒
                var p = Path()
                p.move(to: CGPoint(x: x - s * 2.4, y: y))
                p.addLine(to: CGPoint(x: x + s * 2.4, y: y))
                p.move(to: CGPoint(x: x, y: y - s * 2.4))
                p.addLine(to: CGPoint(x: x, y: y + s * 2.4))
                ctx.stroke(p, with: .color(tint.opacity(op)), lineWidth: 1.0)

                // 中心亮点
                let dot = CGRect(x: x - s * 0.7, y: y - s * 0.7, width: s * 1.4, height: s * 1.4)
                ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(op)))
            }
        }
        .blendMode(.plusLighter)
    }
}

// MARK: - 完成彩带

/// 完成后从按钮中心炸开的彩带，受重力下落、边落边转，2 秒内淡出。
struct ConfettiBurst: View {
    let start: Date?

    private let colors: [Color] = [
        Color(red: 0.30, green: 0.80, blue: 0.52),
        Color(red: 0.40, green: 0.62, blue: 1.00),
        Color(red: 1.00, green: 0.78, blue: 0.30),
        Color(red: 1.00, green: 0.45, blue: 0.55),
        Color(red: 0.68, green: 0.45, blue: 0.98),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: start == nil)) { ctx in
            let e = start.map { ctx.date.timeIntervalSince($0) } ?? -1

            Canvas { gc, size in
                guard e >= 0, e < 2.2 else { return }
                let c = CGPoint(x: size.width / 2, y: size.height / 2)

                for i in 0..<30 {
                    let seed = Double(i + 1)
                    let a = frac(seed * 0.6180339887) * 2 * .pi
                    let speed = 95.0 + 130.0 * frac(seed * 0.7548776662)

                    let vx = cos(a) * speed
                    let vy = sin(a) * speed - 70

                    let x = c.x + CGFloat(vx * e)
                    let y = c.y + CGFloat(vy * e + 170 * e * e)     // 重力
                    let fade = max(0, 1 - e / 1.9)
                    guard fade > 0.02 else { continue }

                    let w = CGFloat(3.6 + 2.2 * frac(seed * 0.91))
                    let h = w * 1.9
                    let spin = CGFloat(seed * 2.7 + e * 7 * (frac(seed * 0.37) - 0.5))

                    var g2 = gc
                    g2.translateBy(x: x, y: y)
                    g2.rotate(by: .radians(Double(spin)))

                    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                    g2.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                            with: .color(colors[i % colors.count].opacity(fade)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 取小数部分
func frac(_ x: Double) -> Double {
    x - floor(x)
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
