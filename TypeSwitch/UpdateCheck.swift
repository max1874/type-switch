#if DEBUG
import AppKit
import Security

/// Pulls the updater apart so each step can be run and read on its own.
///
///     TypeSwitch --update-latest
///     TypeSwitch --update-identity <reference.app> <candidate.app>
///     TypeSwitch --update-compare
///
/// The one step deliberately absent is the handover, which replaces the app
/// and relaunches it. That is not something to fire off from a terminal while
/// checking something else.
///
/// Debug-only. A shipped app has no reason to be able to do this.
@MainActor
enum UpdateCheck {
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("--update-compare") {
            compare()
            exit(0)
        }

        // Prints the shipped script rather than describing it, so what gets
        // exercised against scratch directories is the text that will run
        // against the real app.
        if arguments.contains("--update-handover-script") {
            print(Updater.handoverScript)
            exit(0)
        }

        if let flag = arguments.firstIndex(of: "--update-identity") {
            guard arguments.indices.contains(flag + 2) else {
                fail("--update-identity needs a reference app and a candidate app")
            }
            let reference = URL(fileURLWithPath: arguments[flag + 1])
            let candidate = URL(fileURLWithPath: arguments[flag + 2])
            print("reference: \(reference.path)")
            print("  \(requirement(of: reference) ?? "no designated requirement")")
            print("candidate: \(candidate.path)")
            do {
                try Updater.verifySameIdentity(candidate, as: reference)
                print("  accepted — same identity")
            } catch {
                print("  refused — \(error.localizedDescription)")
            }
            exit(0)
        }

        guard arguments.contains("--update-latest") else { return false }
        Task {
            await Updater.shared.check(asked: true)
            switch Updater.shared.stage {
            case .found(let update):
                print("running \(Updater.currentVersion), latest is \(update.version)")
                print("  page:     \(update.page.absoluteString)")
                print("  image:    \(update.image.absoluteString)")
                print("  checksum: \(update.checksum.absoluteString)")
            case .failed(let message):
                fail(message)
            default:
                print("running \(Updater.currentVersion), nothing newer published")
            }
            exit(0)
        }
        return true
    }

    /// The comparison decides whether anyone is ever told about a release, and
    /// it is the one part with no network in it, so it can simply be run.
    private static func compare() {
        let cases: [(String, String, Bool)] = [
            ("1.0.2", "1.0.1", true),
            ("1.0.1", "1.0.2", false),
            ("1.0.1", "1.0.1", false),
            ("1.1.0", "1.0.9", true),
            ("2.0", "1.9.9", true),
            ("1.10.0", "1.9.0", true),     // not a string comparison
            ("1.0.2", "1.0.2.1", false),
            ("1.0.10", "1.0.9", true),
            ("v1.0.3", "1.0.2", true),     // a tag that kept its v
        ]
        var wrong = 0
        for (candidate, current, expected) in cases {
            let got = Updater.isNewer(candidate, than: current)
            let mark = got == expected ? "ok  " : "WRONG"
            if got != expected { wrong += 1 }
            print("\(mark) isNewer(\(candidate), than: \(current)) = \(got)")
        }
        print(wrong == 0 ? "all \(cases.count) agree" : "\(wrong) disagree")
    }

    private static func requirement(of app: URL) -> String? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement
        else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("update: \(message)\n".utf8))
        exit(1)
    }
}
#endif
