import Foundation

/// Terms the model must leave alone, or translate in one fixed way.
///
/// The built-in instruction already asks the model to replace only what needs
/// replacing, and it still cannot know that `TypeSwitch` is a product name
/// rather than two English words, or that `kAXValueAttribute` is an identifier
/// that stops compiling the moment it is translated. Which words those are is
/// knowledge the writer has and the model does not, so it is a setting.
///
/// Two kinds of entry, and the direction is what tells them apart:
///
///     TypeSwitch                  leave exactly as written
///     prompt → 提示词              always render it this way
///
/// Stored as JSON rather than as the lines the user types. The lines are a
/// display format; what the request needs is the two fields, and a parser run
/// at request time is a parser that can disagree with the editor about what was
/// written.
struct GlossaryTerm: Codable, Equatable, Identifiable {
    /// The text as it appears in what the writer types.
    var term: String
    /// What to render it as, or empty to keep `term` exactly as it is.
    var replacement: String = ""

    var id: String { term }

    /// True when this entry asks for one fixed translation rather than for the
    /// term to survive untouched.
    var isFixedTranslation: Bool { !replacement.isEmpty }

    /// The line shown in the editor: `term` alone, or `term → replacement`.
    var line: String {
        isFixedTranslation ? "\(term) → \(replacement)" : term
    }

    /// One line of the editor as a term.
    ///
    /// A `#` at the start is a comment, which is what makes the field
    /// self-explanatory without a second control explaining it. Everything else
    /// is a line: split on the first arrow if there is one, and treat the whole
    /// line as a term if there is not.
    ///
    /// Both arrows are accepted because the two are the same key on a Chinese
    /// keyboard, and which one arrives depends on the input method that was
    /// active rather than on anything the user chose.
    static func parse(line: String) -> GlossaryTerm? {
        let cleaned = line.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("#") else { return nil }

        for arrow in ["->", "→"] {
            if let split = cleaned.range(of: arrow) {
                let term = String(cleaned[cleaned.startIndex..<split.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let replacement = String(cleaned[split.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                // "term →" with nothing after it is a half-typed line, not a
                // request to replace the term with nothing.
                guard !term.isEmpty, !replacement.isEmpty else { return nil }
                return GlossaryTerm(term: term, replacement: replacement)
            }
        }
        return GlossaryTerm(term: cleaned)
    }

    /// The whole field, one entry per line.
    static func parse(_ text: String) -> [GlossaryTerm] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .compactMap { parse(line: String($0)) }
            // A term named twice is one entry, and the first line wins: the
            // request can only carry one instruction about it.
            .filter { seen.insert($0.term).inserted }
    }

    static func text(of terms: [GlossaryTerm]) -> String {
        terms.map(\.line).joined(separator: "\n")
    }
}

enum Glossary {
    /// Everything the user has written, in the order they wrote it.
    static var terms: [GlossaryTerm] {
        get {
            guard let data = UserDefaults.standard.data(forKey: PrefKey.glossary),
                  let stored = try? JSONDecoder().decode([GlossaryTerm].self, from: data)
            else { return [] }
            return stored
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            UserDefaults.standard.set(data, forKey: PrefKey.glossary)
        }
    }

    static var text: String {
        get { GlossaryTerm.text(of: terms) }
        set { terms = GlossaryTerm.parse(newValue) }
    }

    static var isEmpty: Bool { terms.isEmpty }
}
