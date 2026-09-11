#if DEBUG
import AppKit

/// Sends one line through the app's own rewrite path and prints what came back.
///
///     TYPESWITCH_API_KEY=… TypeSwitch --rewrite "这个功能 should be 很简单" \
///         -providerBaseURL https://openrouter.ai/api/v1 \
///         -providerModel deepseek/deepseek-chat
///
/// This is how an address gets checked. Reading the request body and agreeing
/// that it looks right is not a check — an endpoint either accepts the request
/// and answers in the shape the parser expects, or it does not, and the only
/// way to know which is to send it. `curl` would prove the endpoint's half and
/// leave the app's half — the reply parsing, the quote stripping, the
/// punctuation matching — untested.
///
/// Nothing stored is disturbed: `-key value` on the command line lands in
/// UserDefaults' argument domain, which outranks what is saved, and the key
/// comes from the environment rather than from the keychain or from `argv`,
/// where `ps` would show it to every process on the machine.
///
/// Debug-only. A shipped app has no reason to be able to do this.
@MainActor
enum RewriteCheck {
    static func runIfRequested() -> Bool {
        if models() { return true }

        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--rewrite") else { return false }
        guard arguments.indices.contains(flag + 1) else {
            fail("--rewrite needs a line of text to send")
        }
        let text = arguments[flag + 1]

        print("\(Prefs.baseURL)  \(Prefs.model)  key: \(Prefs.apiKey.isEmpty ? "none" : "set")")
        let started = Date()
        Task {
            do {
                let rewritten = try await Rewriter.rewrite(text)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("  in:  \(text)")
                print("  out: \(rewritten)")
                print("  \(ms)ms")
                exit(0)
            } catch {
                fail(error.localizedDescription)
            }
        }
        return true
    }

    /// `TypeSwitch --models -providerBaseURL …` — what the settings window's
    /// model list will be asking for, asked from here where the answer can be
    /// read in full.
    private static func models() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--models") else { return false }
        let baseURL = Prefs.baseURL
        print("\(baseURL)  key: \(Prefs.apiKey.isEmpty ? "none" : "set")")
        Task {
            do {
                let names = try await ModelCatalog.fetch(baseURL: baseURL, key: Prefs.apiKey)
                print("  \(names.count) models")
                for name in names.prefix(8) { print("    \(name)") }
                if names.count > 8 { print("    … and \(names.count - 8) more") }
                exit(0)
            } catch {
                fail(error.localizedDescription)
            }
        }
        return true
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("rewrite: \(message)\n".utf8))
        exit(1)
    }
}
#endif
