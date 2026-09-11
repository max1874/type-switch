import Foundation

/// The URLs an address turns into.
///
/// Kept in one place because the settings window shows the user the same URL
/// the request is about to use. A preview built by different code than the
/// request is a preview that can be wrong, and being wrong here is the whole
/// problem it exists to solve: nothing about `https://api.deepseek.com` versus
/// `https://api.openai.com/v1` tells you which one already ends in the version
/// segment, and until now the only way to find out was to guess and see whether
/// the rewrite worked.
enum Endpoint {
    /// The one the rewrite is sent to.
    static func chatCompletions(_ baseURL: String) -> URL? { url(baseURL, path: "chat/completions") }

    /// Where the address lists what it can run. Part of the same format, and
    /// answered by every address worth listing — but not required by it, so an
    /// address that refuses is not a broken address.
    static func models(_ baseURL: String) -> URL? { url(baseURL, path: "models") }

    private static func url(_ baseURL: String, path: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/" + path)
    }
}
