import Foundation

enum RewriteError: LocalizedError {
    case http(Int, String)
    case emptyResponse
    case transport(String)
    case nothingToRewrite
    case badProviderURL(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: String(localized: "还没填 API Key，去设置里填一个")
        case .nothingToRewrite: String(localized: "这一行没有可转换的文字")
        case .badProviderURL(let url): String(localized: "接口地址无效：\(url)")
        case .http(let code, let message): String(localized: "接口返回 \(code)：\(message)")
        case .emptyResponse: String(localized: "接口没有返回内容")
        case .transport(let message): String(localized: "网络错误：\(message)")
        }
    }
}

/// Turns mixed Chinese/pinyin/English input into English via DeepSeek.
///
/// Non-streaming on purpose: measured round-trip is ~0.6s with reasoning off,
/// and the text is written back in one call anyway, so streaming would only add
/// parsing complexity without changing what the user sees.
enum Rewriter {
    /// OpenAI-compatible chat completions, which is what DeepSeek, OpenAI,
    /// Moonshot, and local Ollama/LM Studio all speak.
    private static func endpoint(for provider: AIProvider) throws -> URL {
        let base = provider.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            throw RewriteError.badProviderURL(provider.baseURL)
        }
        return url
    }

    /// `{{language}}` is replaced with the configured target language, so the
    /// app is not hard-wired to one language pair. The writer's own language is
    /// never named — whatever they fell back to is inferred from the input.
    static let languagePlaceholder = "{{language}}"

    static let defaultSystemPrompt = """
    You rewrite text into natural, idiomatic \(languagePlaceholder).

    The input comes from someone writing in \(languagePlaceholder) who switched \
    to another language at the points where they got stuck. Their \
    \(languagePlaceholder) fragments are usually fine — keep them, and replace \
    only what needs replacing. If the input is entirely in another language, \
    translate all of it.

    Match the register of the surrounding text: casual stays casual, formal \
    stays formal.

    Do not add ending punctuation the writer did not type. If the input ends \
    without a period or question mark, the output ends without one too — they \
    are still mid-sentence.

    Output ONLY the rewritten text. No quotation marks around it, no \
    explanation, no alternatives, no preamble.
    """

    static func rewrite(_ input: String) async throws -> String {
        let text = stripTriggerArtifacts(input)
        guard hasWords(text) else { throw RewriteError.nothingToRewrite }

        let key = Prefs.apiKey
        guard !key.isEmpty else { throw RewriteError.missingAPIKey }

        let provider = Prefs.provider
        var request = URLRequest(url: try endpoint(for: provider))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": provider.model,
            "max_tokens": 2048,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": Prefs.systemPrompt.replacingOccurrences(
                    of: languagePlaceholder, with: Prefs.targetLanguage
                )],
                ["role": "user", "content": text],
            ],
        ]
        // DeepSeek reasons by default, which measured ~0.35s slower with no
        // quality gain on a one-sentence rewrite. The parameter is theirs alone —
        // OpenAI rejects unknown arguments outright.
        if provider.baseURL.localizedCaseInsensitiveContains("deepseek") {
            body["thinking"] = ["type": "disabled"]
        }
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

    /// Whether there is anything worth sending.
    ///
    /// A shell prompt like "❯" survives an is-empty check but contains no
    /// words, and the model answers a promptless request with "please share the
    /// text you'd like me to rewrite" — which then gets written into the
    /// document as if it were a result.
    private static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.count { CharacterSet.letters.contains($0) } >= 2
    }

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
