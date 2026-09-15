import Foundation

enum RewriteError: LocalizedError {
    case http(Int, String)
    case emptyResponse
    case transport(String)
    case nothingToRewrite
    case badProviderURL(String)
    case missingAPIKey
    /// The endpoint answered, and stopped early. Named separately from the rest
    /// because nothing is wrong with the configuration and nothing is wrong
    /// with the line — it is too long for the room the request left, and the
    /// only thing that helps is knowing that.
    case truncated
    /// The endpoint said it was busy, twice, and there is nothing the user's
    /// settings can do about it.
    case busy(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: String(localized: "还没填 API Key，去设置里填一个")
        case .nothingToRewrite: String(localized: "这一行没有可转换的文字")
        case .badProviderURL(let url): String(localized: "接口地址无效：\(url)")
        // The endpoint's own words are kept, always — it is the only party that
        // knows what actually went wrong, and its message frequently names the
        // model or the key outright. What is added is the part it cannot say:
        // which of the three things on the settings page to go and look at.
        case .http(401, let message), .http(403, let message):
            String(localized: "Key 不对，或者它没有权限用这个模型：\(message)")
        case .http(404, let message):
            String(localized: "地址或模型不对，接口说找不到：\(message)")
        case .http(429, let message):
            String(localized: "请求太密，等一会儿再试：\(message)")
        case .http(let code, let message) where code >= 500:
            String(localized: "对方服务出错了（\(code)），不是你的配置问题：\(message)")
        case .http(let code, let message): String(localized: "接口返回 \(code)：\(message)")
        case .emptyResponse: String(localized: "接口没有返回内容")
        case .transport(let message): String(localized: "网络错误：\(message)")
        case .truncated:
            String(localized: "这一行太长，模型没写完就停了，所以没有写回。选中短一点的一段再试。")
        case .busy(let code):
            String(localized: "对方一直说忙（\(code)），已经试过两次。等一会儿再触发一次。")
        }
    }

    /// Whether sending the same request again could plausibly work.
    ///
    /// Rate limits and the endpoint's own bad days pass; a wrong key does not,
    /// and neither does a line too long for the reply budget. Repeating those
    /// only spends the user's money and their patience.
    var isWorthRetrying: Bool {
        switch self {
        case .http(429, _), .http(500..., _), .transport:
            return true
        default:
            return false
        }
    }

    var isBusy: Bool {
        if case .http(429, _) = self { return true }
        if case .busy = self { return true }
        return false
    }
}

/// Turns mixed Chinese/pinyin/English input into English via DeepSeek.
///
/// Non-streaming on purpose: measured round-trip is ~0.6s with reasoning off,
/// and the text is written back in one call anyway, so streaming would only add
/// parsing complexity without changing what the user sees.
enum Rewriter {
    /// Parameters only one vendor understands, keyed by the address they belong
    /// to rather than by which shortcut was last clicked — the address can be
    /// typed by hand, and then no shortcut was clicked at all.
    private static func vendorExtras(for baseURL: String) -> [String: Any] {
        guard baseURL.localizedCaseInsensitiveContains("deepseek") else { return [:] }
        // DeepSeek reasons by default, which measured ~0.35s slower with no
        // quality gain on a one-sentence rewrite. Sending it anywhere else
        // would be rejected as an unknown argument.
        return ["thinking": ["type": "disabled"]]
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

    /// The glossary as the model is told about it.
    ///
    /// Appended after the instructions so it can overrule them, and inside the
    /// system prompt rather than as a second message so that everything sent to
    /// the model is still the one block the settings window shows.
    ///
    /// Written as an explicit rule per term rather than as a list to be
    /// interpreted. A model handed a bare list of words has to guess what the
    /// list is for, and guessing is what put `TypeSwitch` into the target
    /// language in the first place.
    static func glossarySection(_ terms: [GlossaryTerm]) -> String {
        guard !terms.isEmpty else { return "" }
        let rules = terms.map { term in
            term.isFixedTranslation
                ? "- Always write \"\(term.term)\" as \"\(term.replacement)\"."
                : "- Keep \"\(term.term)\" exactly as it is. Never translate it."
        }
        return """


        Glossary. These are the writer's own terms, and they outrule \
        everything above. A protected term is kept verbatim: not translated, \
        not reworded, not wrapped in quotation marks, not re-capitalised.
        \(rules.joined(separator: "\n"))
        """
    }

    /// The instructions as they will actually be sent: the writer's own prompt,
    /// with the language and the glossary filled in.
    static func instructions() -> String {
        Prefs.systemPrompt.replacingOccurrences(
            of: languagePlaceholder, with: Prefs.targetLanguage
        ) + glossarySection(Glossary.terms)
    }

    /// How long the whole rewrite may take, retries included. The user is
    /// sitting in front of a document they cannot see the result of, so the
    /// clock matters more than the attempt count does.
    private static let budget: TimeInterval = 20

    static func rewrite(_ input: String) async throws -> String {
        let text = stripTriggerArtifacts(input)
        guard hasWords(text) else { throw RewriteError.nothingToRewrite }

        switch Prefs.apiFormat {
        case .openAICompatible:
            return try await withRetries(text)
        }
    }

    /// Sends the request, and sends it once more when the reason it failed is
    /// the kind that passes.
    ///
    /// No retry loop in the app before this one: a 429 or a dropped connection
    /// meant the user re-triggered, which meant the line was captured again —
    /// and by then they had typed more of it.
    private static func withRetries(_ text: String) async throws -> String {
        let finishBy = Date().addingTimeInterval(budget)
        var attempt = 1
        while true {
            do {
                return try await chatCompletion(text, attempt: attempt, deadline: finishBy)
            } catch let error as RewriteError {
                // A busy endpoint that is still busy at the last attempt says
                // so in its own terms: "it tried twice" is the part the user
                // cannot work out for themselves.
                let last = attempt >= 2 || Date() >= finishBy.addingTimeInterval(-5)
                guard error.isWorthRetrying, !last else {
                    if error.isBusy, attempt >= 2 { throw RewriteError.busy(429) }
                    throw error
                }
                log.info("""
                    rewrite failed on attempt \(attempt, privacy: .public) \
                    (\(error.localizedDescription, privacy: .public)), trying once more
                    """)
                // Long enough for a rate limiter to have moved on, short enough
                // that the user has not started wondering whether it worked.
                try await Task.sleep(for: .milliseconds(700))
                attempt += 1
            }
        }
    }

    /// The one request the rewrite makes.
    ///
    /// `attempt` counts from 1 and only ever appears in the log: what the retry
    /// loop below is doing is worth being able to see afterwards, and the reply
    /// body carries nothing that says which try it was.
    private static func chatCompletion(
        _ text: String, attempt: Int = 1, deadline: Date? = nil
    ) async throws -> String {
        let key = Prefs.apiKey
        let baseURL = Prefs.baseURL
        // Decided once per rewrite, not once per attempt: a retry that waited
        // for a fresh connection on top of the backoff would spend the budget
        // the backoff was meant to buy.
        let finishBy = deadline ?? Date().addingTimeInterval(20)

        guard let url = Endpoint.chatCompletions(baseURL) else {
            throw RewriteError.badProviderURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Measured against what is left of the budget rather than set to it, so
        // a second attempt cannot leave the user waiting for two full timeouts.
        request.timeoutInterval = max(5, min(15, finishBy.timeIntervalSinceNow))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Only when there is one. A key is not required by every endpoint —
        // a model running on this machine answers without one — and demanding
        // it up front made a working local setup impossible to configure.
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": Prefs.model,
            "max_tokens": 2048,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": instructions()],
                ["role": "user", "content": text],
            ],
        ]
        body.merge(vendorExtras(for: baseURL)) { _, extra in extra }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
            // Or the backoff below would hold the user for the whole of it
            // after they had already stopped waiting.
            try Task.checkCancellation()
        } catch is CancellationError {
            // Never worth another try: the rewrite this belonged to is gone.
            throw CancellationError()
        } catch {
            throw RewriteError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // An endpoint that wanted a key says so itself, and it is the only
            // one that knows. Turning its refusal into plain words beats both
            // demanding a key from everyone and handing over a bare 401.
            if [401, 403].contains(http.statusCode), key.isEmpty {
                throw RewriteError.missingAPIKey
            }
            throw RewriteError.http(http.statusCode, Self.errorMessage(in: data))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              // Only "content" — "reasoning_content" is the model thinking aloud.
              let content = message["content"] as? String
        else { throw RewriteError.emptyResponse }

        // The reply is written into the document as if it were the whole line.
        // When the model stopped at the token ceiling, the tail of the sentence
        // is simply missing, and clean() below would trim it further and leave
        // something that reads like a finished rewrite. So it is refused before
        // it is cleaned, and refused before it is written.
        if let reason = choice["finish_reason"] as? String, reason == "length" {
            throw RewriteError.truncated
        }

        let result = clean(content, matchingPunctuationOf: text)
        guard !result.isEmpty else { throw RewriteError.emptyResponse }
        log.info("rewrite answered on attempt \(attempt, privacy: .public)")
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
