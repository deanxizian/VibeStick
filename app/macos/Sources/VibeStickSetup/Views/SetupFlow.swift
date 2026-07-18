import SwiftUI

enum SetupFlowStep: Int, CaseIterable, Identifiable {
    case network
    case device
    case install

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .network: "连接网络"
        case .device: "连接设备"
        case .install: "完成安装"
        }
    }

    var systemImage: String {
        switch self {
        case .network: "wifi"
        case .device: "cable.connector"
        case .install: "checkmark"
        }
    }
}

struct SetupFlowProgressView: View {
    let current: SetupFlowStep
    let installationComplete: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(SetupFlowStep.allCases.enumerated()), id: \.element.id) { index, step in
                StepMarker(
                    step: step,
                    isCurrent: step == current,
                    isComplete: installationComplete || step.rawValue < current.rawValue
                )
                if index < SetupFlowStep.allCases.count - 1 {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue || installationComplete ? Color.green : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                        .frame(maxWidth: 90)
                        .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("安装进度")
    }
}

private struct StepMarker: View {
    let step: SetupFlowStep
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(markerColor)
                    .frame(width: 30, height: 30)
                Image(systemName: isComplete ? "checkmark" : step.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent || isComplete ? .white : .secondary)
            }
            Text(step.title)
                .font(.caption)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .frame(width: 92)
    }

    private var markerColor: Color {
        if isComplete { return .green }
        if isCurrent { return .accentColor }
        return .secondary.opacity(0.14)
    }
}
