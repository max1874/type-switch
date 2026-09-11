import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater = Updater.shared

    var body: some View {
        // Only speak up when something is wrong. Reporting "ready" on every
        // open is noise, and the trigger is already spelled out in Settings.
        if case .idle = state.status {} else {
            Text(state.status.label)
            Divider()
        }

        // Above Settings, because it is the one thing here that expires.
        update

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

    @ViewBuilder
    private var update: some View {
        switch updater.stage {
        case .found(let available):
            Button("更新到 \(available.version)") { updater.install(available) }
            Button("先看看 \(available.version) 改了什么…") {
                NSWorkspace.shared.open(available.page)
            }
            Divider()
        case .installing:
            Text("正在更新…")
            Divider()
        case .idle, .checking, .failed:
            EmptyView()
        }
    }
}
