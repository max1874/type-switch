import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater = Updater.shared

    var body: some View {
        // Only speak up when something is wrong or in flight. Reporting "ready"
        // on every open is noise, and the trigger is already spelled out in
        // Settings.
        switch state.status {
        case .idle:
            EmptyView()
        case .needsPermission:
            PermissionSection()
            Divider()
        case .working:
            Text(state.status.label)
            Divider()
        case .error(let message):
            // The whole message, not a summary of it: the panel that carried it
            // is gone after four seconds, and this is where someone looks when
            // they missed it.
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开设置…") { SettingsWindow.open(pane: .provider) }
            }
            Divider()
        }

        // Above Settings, because it is the one thing here that expires.
        update

        Button("设置…") { SettingsWindow.open(pane: .general) }
            .keyboardShortcut(",")

        Button("权限与自检…") { SetupWindow.open() }

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

/// The two grants, each with the switch that asks for it.
///
/// Buttons rather than a line of text saying something is missing: the fix is
/// one click away and System Settings is where it has to be done, so the menu
/// carries the click. Deep-linked to the exact pane, because "Privacy &
/// Security" is a list of thirty things.
private struct PermissionSection: View {
    var body: some View {
        if !Permissions.hasAccessibility {
            Button("① 打开辅助功能权限…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasInputMonitoring {
            Button("② 打开输入监控权限…") { Permissions.openInputMonitoringSettings() }
        }
        if Permissions.hasAccessibility, Permissions.hasInputMonitoring {
            Text("权限都齐了")
        }
    }
}
