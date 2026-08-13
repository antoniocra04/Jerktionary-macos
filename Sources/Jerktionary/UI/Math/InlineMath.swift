import Foundation

/// Inline maths, rendered into the text rather than beside it.
///
/// Display formulas get the full two-dimensional treatment (see MathView), but
/// `$A^{-1}$` in the middle of a sentence cannot: a SwiftUI view mixed into a
/// paragraph stops the text wrapping around it. Superscripts, indices and Greek
/// letters all exist as Unicode, so short inline maths is transliterated and the
/// sentence stays one flowing, selectable, wrapping block of text.
///
/// Anything with no Unicode form — a fraction, a root, a matrix — keeps its
/// LaTeX so nothing is silently lost, and belongs in a display block anyway.
enum InlineMath {
    /// Rewrites every `$…$` and `\(…\)` span in a line.
    static func render(in text: String) -> String {
        guard text.contains("$") || text.contains("\\(") else { return text }
        var result = ""
        var rest = Substring(text)

        while let span = nextSpan(in: rest) {
            result += rest[rest.startIndex..<span.start]
            result += transliterate(String(rest[span.body]))
            rest = rest[span.end...]
        }
        result += rest
        return result
    }

    private struct Span {
        let start: String.Index
        let body: Range<String.Index>
        let end: String.Index
    }

    private static func nextSpan(in text: Substring) -> Span? {
        let candidates: [(open: String, close: String)] = [("\\(", "\\)"), ("$", "$")]
        var best: Span?
        for pair in candidates {
            guard let open = text.range(of: pair.open) else { continue }
            // "$$" opens a display block; that is a job for the block parser.
            if pair.open == "$", text[open.upperBound...].hasPrefix("$") { continue }
            guard let close = text.range(of: pair.close, range: open.upperBound..<text.endIndex)
            else { continue }
            let span = Span(start: open.lowerBound, body: open.upperBound..<close.lowerBound, end: close.upperBound)
            if best == nil || span.start < best!.start { best = span }
        }
        return best
    }

    /// Best-effort LaTeX to Unicode. Order matters: commands are replaced before
    /// braces are stripped, or `\alpha` inside `{}` would lose its backslash.
    static func transliterate(_ latex: String) -> String {
        var text = latex

        // Longest first, always. Iterating a dictionary put `\le` before `\leq`
        // often enough to turn "≤" into "≤q", and `\in` before `\infty` to turn
        // "∞" into "∈fty" — with the order depending on the hash seed, so it
        // changed between runs.
        for (name, glyph) in Self.replacements {
            text = text.replacingOccurrences(of: "\\" + name, with: glyph)
        }
        for command in ["left", "right", "displaystyle", "limits", "mathrm", "text", "mathbf"] {
            text = text.replacingOccurrences(of: "\\" + command, with: "")
        }

        text = roots(in: text)
        text = scripts(in: text, marker: "^", map: superscripts)
        text = scripts(in: text, marker: "_", map: subscriptsMap)

        text = text.replacingOccurrences(of: "{", with: "")
        text = text.replacingOccurrences(of: "}", with: "")
        text = text.replacingOccurrences(of: "\\,", with: " ")
        text = text.replacingOccurrences(of: "\\ ", with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Every command this can render, longest name first so no name can be
    /// swallowed by a shorter one that happens to be its prefix.
    private static let replacements: [(String, String)] = {
        var all = Symbols.table
        all.merge(Symbols.functions) { current, _ in current }
        all.merge(bigOperators) { current, _ in current }
        return all.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
    }()

    private static let bigOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂"
    ]

    /// `\sqrt{x+1}` becomes √(x+1); the brackets are what keep it unambiguous
    /// once the radical has no bar over its content.
    private static func roots(in text: String) -> String {
        var result = text
        while let range = result.range(of: "\\sqrt") {
            var rest = result[range.upperBound...]
            var body = ""
            if rest.first == "{" {
                rest = rest.dropFirst()
                while let character = rest.first, character != "}" {
                    body.append(character)
                    rest = rest.dropFirst()
                }
                if rest.first == "}" { rest = rest.dropFirst() }
            } else if let character = rest.first {
                body.append(character)
                rest = rest.dropFirst()
            }
            let wrapped = body.count > 1 ? "√(\(body))" : "√\(body)"
            result = String(result[result.startIndex..<range.lowerBound]) + wrapped + String(rest)
        }
        return result
    }

    /// Converts `^{-1}` / `^2` when every character has a Unicode equivalent,
    /// and leaves the run alone when even one does not.
    private static func scripts(
        in text: String,
        marker: Character,
        map: [Character: Character]
    ) -> String {
        var result = ""
        var characters = Array(text)[...]

        while let first = characters.first {
            guard first == marker else {
                result.append(first)
                characters = characters.dropFirst()
                continue
            }
            characters = characters.dropFirst()

            var run = ""
            if characters.first == "{" {
                characters = characters.dropFirst()
                while let character = characters.first, character != "}" {
                    run.append(character)
                    characters = characters.dropFirst()
                }
                if characters.first == "}" { characters = characters.dropFirst() }
            } else if let character = characters.first {
                run.append(character)
                characters = characters.dropFirst()
            }

            let converted = run.compactMap { map[$0] }
            if converted.count == run.count, !run.isEmpty {
                result += String(converted)
            } else {
                result.append(marker)
                result += run.count == 1 ? run : "{\(run)}"
            }
        }
        return result
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
        "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼",
        "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "T": "ᵀ", "x": "ˣ", "k": "ᵏ",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "m": "ᵐ", "t": "ᵗ"
    ]

    private static let subscriptsMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
        "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "−": "₋", "=": "₌",
        "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]
}
