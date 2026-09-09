import AppKit

/// Apps the trigger is ignored in.
///
/// The trigger fires on a keystroke, not on the kind of text under it, so in a
/// terminal or an editor the line it picks up is as likely to be a shell prompt
/// or a line of code as it is prose. Which apps those are is the user's call —
/// someone drafting commit messages in a terminal may want it there — so the
/// list starts empty and they fill it.
enum ExcludedApps {
    static var bundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: PrefKey.excludedApps) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.excludedApps) }
    }

    static func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    static func add(_ bundleID: String) {
        guard !bundleID.isEmpty, !contains(bundleID) else { return }
        bundleIDs = (bundleIDs + [bundleID]).sorted()
    }

    static func remove(_ bundleID: String) {
        bundleIDs = bundleIDs.filter { $0 != bundleID }
    }

    /// An installed app's name and icon, for showing a row the user recognises
    /// rather than a reverse-DNS string. An app that has since been deleted
    /// keeps its identifier as the label so the row can still be removed.
    static func describe(_ bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        return (
            FileManager.default.displayName(atPath: url.path),
            NSWorkspace.shared.icon(forFile: url.path)
        )
    }

    /// Asks for an app and returns its bundle identifier.
    ///
    /// A picker rather than a text field: the identifier is what has to be
    /// matched at trigger time, and nobody knows an app's off by heart.
    @MainActor
    static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选一个不希望触发的 app")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
