import SwiftUI

struct ActivityLogView: View {
    @Bindable var store: SetupStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("活动日志")
                    .font(.headline)
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Text(store.operationTitle).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空") { store.clearLog() }
                    .disabled(store.isBusy || store.logText.isEmpty)
            }
            .padding()
            Divider()
            LogPreview(text: store.logText)
                .padding(8)
        }
    }
}
