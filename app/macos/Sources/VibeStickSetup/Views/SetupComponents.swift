import AppKit
import SwiftUI
import VibeStickSetupCore

struct StableWizardScrollView<Content: View>: View {
    let maximumContentWidth: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                content()
                    .padding(30)
                    .frame(maxWidth: maximumContentWidth, alignment: .leading)
                    .frame(width: geometry.size.width, alignment: .center)
            }
        }
    }
}

struct SetupHero: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InstructionRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.tint, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ReadyRow: View {
    let title: String
    let detail: String
    let ready: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }
}

struct DeploymentStepCompactRow: View {
    let step: DeploymentStep

    var body: some View {
        HStack(spacing: 10) {
            stateIcon
                .frame(width: 18)
            Text(step.phase.title)
            Spacer()
            stateText
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var stateText: some View {
        switch step.state {
        case .pending: Text("等待")
        case .running: Text("进行中")
        case .succeeded: Text("完成")
        case let .failed(message):
            Text(message)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400, alignment: .trailing)
        }
    }
}

struct LogPreview: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "尚无日志" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct WindowCloseButtonGuard: NSViewRepresentable {
    let disabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { updateWindow(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { updateWindow(for: nsView) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        nsView.window?.standardWindowButton(.closeButton)?.isEnabled = true
    }

    private func updateWindow(for view: NSView) {
        view.window?.standardWindowButton(.closeButton)?.isEnabled = !disabled
    }
}
