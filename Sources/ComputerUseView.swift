import SwiftUI

@MainActor
final class ComputerUseModel: ObservableObject {
    @Published var status = ComputerUse.Status(path: nil)
    @Published var busy = false
    @Published var checked = false
    @Published var authorizing = false
    @Published var completed = false
    @Published var failure: ComputerUse.Failure?
    @Published var detail = ""

    func refresh() {
        guard !busy else { return }
        busy = true
        authorizing = false
        completed = false
        failure = nil
        detail = ""
        Task {
            status = await Task.detached(priority: .userInitiated) {
                ComputerUse.status(path: ComputerUse.discover().first)
            }.value
            checked = true
            busy = false
        }
    }

    func authorize() {
        guard !busy, let path = status.path else { return }
        busy = true
        authorizing = true
        completed = false
        failure = nil
        detail = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ComputerUse.authorize(path: path)
            }.value
            status = result.status
            failure = result.failure
            detail = result.detail
            completed = result.succeeded
            authorizing = false
            busy = false
        }
    }
}

struct ComputerUseView: View {
    @EnvironmentObject var lang: LangStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ComputerUseModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 25))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS Computer Use").font(.title3.bold())
                    Text(lang.t("cuSubtitle")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let path = model.status.path {
                VStack(alignment: .leading, spacing: 4) {
                    Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                        .font(.subheadline.weight(.medium))
                    Text(path).font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                permission("kTCCServiceAccessibility", title: "cuAccessibility", icon: "hand.point.up.left")
                permission("kTCCServiceScreenCapture", title: "cuScreenCapture", icon: "rectangle.dashed")
                Text(lang.t("cuAdminHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.checked {
                Text(lang.t("cuNotFound"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(lang.t(model.authorizing ? "cuAuthorizing" : "cuChecking")).font(.caption)
                }
            } else if let failure = model.failure {
                Text(lang.t(failure.rawValue)).font(.caption).foregroundStyle(.red)
                if !model.detail.isEmpty {
                    Text(model.detail).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(4).textSelection(.enabled)
                }
            } else if model.completed {
                Label(lang.t("cuCompleted"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if model.status.ready {
                Label(lang.t("cuReady"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            Divider()
            HStack {
                Button(lang.t("close")) { dismiss() }.disabled(model.busy)
                Spacer()
                Button(lang.t("cuRefresh")) { model.refresh() }.disabled(model.busy)
                Button(lang.t(model.status.ready ? "cuRegrant" : "cuGrant")) { model.authorize() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.status.path == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { model.refresh() }
        .interactiveDismissDisabled(model.busy)
    }

    private func permission(_ service: String, title: String, icon: String) -> some View {
        HStack {
            Label(lang.t(title), systemImage: icon)
            Spacer()
            Text(lang.t(!model.status.readable ? "cuUnreadable"
                        : model.status.granted.contains(service) ? "allowed" : "cuMissing"))
                .foregroundStyle(model.status.granted.contains(service) ? Color.green : Color.secondary)
        }
        .font(.subheadline)
    }
}
