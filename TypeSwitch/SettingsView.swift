import SwiftUI

struct SettingsView: View {
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("测试一句") { runTest() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let testResult {
                    Text(testResult)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } header: {
                Text("自检")
            }

            Section {
                Text("在任何输入框里打字，快速双击空格即可转换。有选中就转换选中部分，没有就转换光标所在行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("用法")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            do {
                let output = try await Rewriter.rewrite("writing English 卡住了？")
                testResult = "✅ \(output)"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
