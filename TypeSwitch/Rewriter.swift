import Foundation

enum RewriteError: LocalizedError {
    case http(Int, String)
    case emptyResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let message): "接口返回 \(code)：\(message)"
        case .emptyResponse: "接口没有返回内容"
        case .transport(let message): "网络错误：\(message)"
        }
    }
}

/// Turns mixed Chinese/pinyin/English input into English via DeepSeek.
///
/// Non-streaming on purpose: measured round-trip is ~0.6s with reasoning off,
/// and the text is written back in one call anyway, so streaming would only add
/// parsing complexity without changing what the user sees.
enum Rewriter {
    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let model = "deepseek-v4-flash"
    private static let apiKey = Secrets.deepSeekAPIKey

    private static let systemPrompt = """
    You rewrite text into natural, idiomatic English.

    The input comes from someone writing in English who switched to Chinese or \
    pinyin at the points where they got stuck. Their English fragments are \
    usually fine — keep them, and replace only what needs replacing. If the \
    input is entirely Chinese, translate the whole thing.

    Match the register of the surrounding English: casual stays casual, formal \
    stays formal.

    Do not add ending punctuation the writer did not type. If the input ends \
    without a period or question mark, the output ends without one too — they \
    are still mid-sentence.

    Output ONLY the rewritten sentence. No quotation marks around it, no \
    explanation, no alternatives, no preamble.
    """

    static func rewrite(_ input: String) async throws -> String {
        let text = stripTriggerArtifacts(input)
        guard !text.isEmpty else { throw RewriteError.emptyResponse }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "temperature": 0.3,
            // Reasoning is on by default on v4-flash and costs ~0.35s here for
            // no measurable quality gain on a one-sentence rewrite.
            "thinking": ["type": "disabled"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RewriteError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RewriteError.http(http.statusCode, Self.errorMessage(in: data))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              // Only "content" — "reasoning_content" is the model thinking aloud.
              let content = message["content"] as? String
        else { throw RewriteError.emptyResponse }

        let result = clean(content, matchingPunctuationOf: text)
        guard !result.isEmpty else { throw RewriteError.emptyResponse }
        return result
    }

    private static let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]

    /// Removes what the trigger itself typed into the line.
    ///
    /// Three quick spaces leave "   " at the caret, or ".  " when macOS's
    /// automatic period substitution turns the first two into a period. A period
    /// followed by two or more spaces is not something a person types, so it is
    /// safe to treat as the trigger's own residue rather than the writer's
    /// punctuation.
    private static func stripTriggerArtifacts(_ input: String) -> String {
        var text = input
        if let residue = text.range(of: #"[.。]\s{2,}$"#, options: .regularExpression) {
            text.removeSubrange(residue)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips the quotes models sometimes add, and keeps the writer's own
    /// choice about ending punctuation.
    ///
    /// The prompt asks for this too, but asking is not enough: a Chinese input
    /// with no trailing punctuation still reads as a finished sentence to the
    /// model, and it supplies a period the writer never typed. Someone stopped
    /// mid-sentence should get their sentence back unfinished.
    private static func clean(_ text: String, matchingPunctuationOf input: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in pairs where trimmed.count >= 2
            && trimmed.first == open && trimmed.last == close {
            trimmed = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        let inputEnded = input.last.map(sentenceEnders.contains) ?? false
        if !inputEnded {
            while let last = trimmed.last, sentenceEnders.contains(last) {
                trimmed = String(trimmed.dropLast())
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func errorMessage(in data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(data: data, encoding: .utf8) ?? "" }
        return message
    }
}
