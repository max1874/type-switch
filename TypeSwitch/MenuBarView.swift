import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.status.label)

        if let result = state.lastResult {
            Divider()
            Text("上次：\(result)")
        }

        Divider()

        SettingsLink { Text("设置…") }
            .keyboardShortcut(",")

        if !Permissions.hasAccessibility {
            Button("开启辅助功能权限…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasInputMonitoring {
            Button("开启输入监控权限…") { Permissions.openInputMonitoringSettings() }
        }

        Button("退出 TypeSwitch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
