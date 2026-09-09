import AppKit
import CoreGraphics

/// Whatever key the user recorded. Any key works — a modifier is worth
/// preferring because it types nothing, so the trigger leaves no stray
/// characters in the line and cannot collide with an input method's candidate
/// selection, but that is the user's call, not ours.
struct TriggerBinding: Equatable {
    var keyCode: Int64
    /// Raw CGEventFlags value, or 0 when this is an ordinary key.
    var modifierFlagRaw: UInt64
    /// What the key types, for an ordinary character key; empty for modifiers
    /// and named keys. Stored raw rather than as a finished display label: a
    /// label saved while the app was in one language would go on reading in
    /// that language after the user switched to another.
    var character: String

    static let space = TriggerBinding(keyCode: 49, modifierFlagRaw: 0, character: " ")

    /// Built fresh every time it is shown, so it follows the current language.
    var label: String {
        if modifierFlagRaw != 0, let modifier = Self.modifiers[keyCode] { return modifier.label }
        if let name = Self.named[keyCode] { return name }
        return character.isEmpty ? String(localized: "键码 \(keyCode)") : character.uppercased()
    }

    var modifierFlag: CGEventFlags? {
        modifierFlagRaw == 0 ? nil : CGEventFlags(rawValue: modifierFlagRaw)
    }

    var isModifier: Bool { modifierFlagRaw != 0 }
    var typesCharacters: Bool { !isModifier }

    /// Builds a binding from a key press captured in the settings window.
    /// Returns nil for a modifier being released rather than pressed.
    init?(event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard let modifier = Self.modifiers[Int64(event.keyCode)],
                  event.modifierFlags.contains(modifier.nsFlag)
            else { return nil }
            self.init(keyCode: Int64(event.keyCode),
                      modifierFlagRaw: modifier.cgFlag.rawValue,
                      character: "")
        case .keyDown:
            self.init(keyCode: Int64(event.keyCode),
                      modifierFlagRaw: 0,
                      character: event.charactersIgnoringModifiers ?? "")
        default:
            return nil
        }
    }

    init(keyCode: Int64, modifierFlagRaw: UInt64, character: String) {
        self.keyCode = keyCode
        self.modifierFlagRaw = modifierFlagRaw
        self.character = character
    }

    private static let modifiers: [Int64: (nsFlag: NSEvent.ModifierFlags, cgFlag: CGEventFlags, label: String)] = [
        54: (.command, .maskCommand, String(localized: "右 ⌘")),
        55: (.command, .maskCommand, String(localized: "左 ⌘")),
        56: (.shift, .maskShift, String(localized: "左 ⇧")),
        60: (.shift, .maskShift, String(localized: "右 ⇧")),
        58: (.option, .maskAlternate, String(localized: "左 ⌥")),
        61: (.option, .maskAlternate, String(localized: "右 ⌥")),
        59: (.control, .maskControl, String(localized: "左 ⌃")),
        62: (.control, .maskControl, String(localized: "右 ⌃")),
        63: (.function, .maskSecondaryFn, "Fn"),
    ]

    private static let named: [Int64: String] = [
        49: String(localized: "空格"), 48: "Tab", 36: "Return", 76: "Enter",
        51: "Delete", 117: "Forward Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

}

struct AIProvider: Equatable {
    var name: String
    var baseURL: String
    var model: String

    /// OpenAI-compatible endpoints, which is nearly everything except Anthropic.
    static let presets: [AIProvider] = [
        AIProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash"),
        AIProvider(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-5-mini"),
        AIProvider(name: "Moonshot", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        AIProvider(name: String(localized: "本地 Ollama"), baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b"),
    ]

    static let `default` = presets[0]
}

enum PrefKey {
    static let triggerKeyCode = "triggerKeyCode"
    static let triggerModifierFlag = "triggerModifierFlag"
    static let triggerCharacter = "triggerCharacter"
    static let triggerCount = "triggerCount"
    static let triggerWindow = "triggerWindow"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let excludedApps = "excludedApps"
    static let providerBaseURL = "providerBaseURL"
    static let providerModel = "providerModel"
    static let systemPrompt = "systemPrompt"
    static let targetLanguage = "targetLanguage"
}

/// Read side of the settings. The UI writes the same keys through @AppStorage,
/// and everything here is read fresh at use time so a change takes effect
/// without restarting anything.
enum Prefs {
    static var trigger: TriggerBinding {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PrefKey.triggerKeyCode) != nil else { return .space }
        return TriggerBinding(
            keyCode: Int64(defaults.integer(forKey: PrefKey.triggerKeyCode)),
            modifierFlagRaw: UInt64(defaults.integer(forKey: PrefKey.triggerModifierFlag)),
            character: defaults.string(forKey: PrefKey.triggerCharacter) ?? ""
        )
    }

    static var triggerCount: Int {
        let stored = UserDefaults.standard.integer(forKey: PrefKey.triggerCount)
        return stored >= 2 ? stored : 3
    }

    /// How close together the taps have to be, in seconds.
    static var triggerWindow: Double {
        let stored = UserDefaults.standard.double(forKey: PrefKey.triggerWindow)
        return stored > 0 ? stored : 0.3
    }

    static var provider: AIProvider {
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: PrefKey.providerBaseURL) ?? ""
        let model = defaults.string(forKey: PrefKey.providerModel) ?? ""
        guard !baseURL.isEmpty, !model.isEmpty else { return .default }
        return AIProvider(name: String(localized: "自定义"), baseURL: baseURL, model: model)
    }

    /// What the text is rewritten into. Any language name the model understands
    /// works — the app is not tied to one language pair.
    static var targetLanguage: String {
        let stored = (UserDefaults.standard.string(forKey: PrefKey.targetLanguage) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? "English" : stored
    }

    /// The user's own instructions to the model, or the built-in ones when they
    /// have not written any (or cleared the field).
    static var systemPrompt: String {
        let stored = (UserDefaults.standard.string(forKey: PrefKey.systemPrompt) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? Rewriter.defaultSystemPrompt : stored
    }

    /// The user's key. There is no fallback — a key baked into the app would be
    /// the developer's own, spent by whoever runs the build.
    static var apiKey: String {
        (Keychain.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.triggerCount: 3,
            PrefKey.triggerWindow: 0.3,
            PrefKey.showMenuBarIcon: true,
            PrefKey.targetLanguage: "English",
        ])
    }
}
