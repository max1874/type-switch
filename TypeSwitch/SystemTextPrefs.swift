import Foundation

/// macOS's own text-substitution settings, which live in the global preferences
/// domain rather than in this app's.
///
/// Writing here changes a system-wide setting that affects every app, so it
/// only ever happens on an explicit click.
enum SystemTextPrefs {
    private static let periodKey = "NSAutomaticPeriodSubstitutionEnabled" as CFString

    /// "Add period with double-space". On by default, which is why two spaces
    /// turn into ". " mid-trigger when the trigger key is the space bar.
    static var doubleSpacePeriod: Bool {
        let value = CFPreferencesCopyValue(
            periodKey,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return (value as? Bool) ?? true
    }

    static func setDoubleSpacePeriod(_ enabled: Bool) {
        CFPreferencesSetValue(
            periodKey,
            enabled as CFPropertyList,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}
