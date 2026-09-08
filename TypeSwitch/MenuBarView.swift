import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Only speak up when something is wrong. Reporting "ready" on every
        // open is noise, and the trigger is already spelled out in Settings.
        if case .idle = state.status {} else {
            Text(state.status.label)
            Divider()
        }

        Button("设置…") { SettingsWindow.open() }
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
