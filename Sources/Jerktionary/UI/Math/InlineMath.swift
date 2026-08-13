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

        // One ordered pass over every command, longest name first. Two passes
        // could not work: the commands that map to nothing were replaced second,
        // so `\lim` had already eaten the front of `\limits` ("limlimits") and
        // `\le` the front of `\left` ("≤ft").
        for (name, glyph) in Self.replacements {
            text = text.replacingOccurrences(of: "\\" + name, with: glyph)
        }

        text = fractions(in: text)
        text = roots(in: text)
        text = limits(in: text)
        text = scripts(in: text, marker: "^", map: superscripts)
        text = scripts(in: text, marker: "_", map: subscriptsMap)

        text = text.replacingOccurrences(of: "{", with: "")
        text = text.replacingOccurrences(of: "}", with: "")
        text = text.replacingOccurrences(of: "\\,", with: " ")
        text = text.replacingOccurrences(of: "\\ ", with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Every command this handles, longest name first so no name can be eaten by
    /// a shorter one that happens to be its prefix. Commands that only affect
    /// typesetting map to an empty string and take part in the same ordering.
    static let replacements: [(String, String)] = {
        var all = Symbols.table
        all.merge(Symbols.functions) { current, _ in current }
        all.merge(bigOperators) { current, _ in current }
        all.merge(dropped) { current, _ in current }
        return all.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
    }()

    /// Typesetting hints with no textual meaning.
    private static let dropped: [String: String] = [
        "left": "", "right": "", "displaystyle": "", "limits": "", "nolimits": "",
        "mathrm": "", "text": "", "mathbf": "", "mathit": "", "mathsf": "",
        "big": "", "Big": "", "bigg": "", "Bigg": "", "operatorname": ""
    ]

    private static let bigOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂",
        "lim": "lim", "limsup": "lim sup", "liminf": "lim inf", "sup": "sup", "inf": "inf",
        "to": "→"
    ]

    /// Reads one `{…}` argument, or a single character when there are no braces.
    /// Nesting is tracked so `\frac{a}{\frac{b}{c}}` does not stop at the inner
    /// closing brace.
    private static func argument(_ rest: inout Substring) -> String {
        guard rest.first == "{" else {
            guard let character = rest.first else { return "" }
            rest = rest.dropFirst()
            return String(character)
        }
        rest = rest.dropFirst()
        var depth = 1
        var body = ""
        while let character = rest.first {
            rest = rest.dropFirst()
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            body.append(character)
        }
        return body
    }

    /// Brackets go on only where they change the reading: `f(x)/(x−1)`, not
    /// `(f(x))/((x−1))`.
    private static func bracketed(_ body: String) -> String {
        guard body.count > 1 else { return body }
        var depth = 0
        for character in body {
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
            if depth == 0, "+-−±/·×".contains(character) { return "(\(body))" }
        }
        return body
    }

    /// `\frac{f(x)}{x-1}` becomes f(x)/(x−1). Stripping the braces without this
    /// left "\dfracf(x)x-1" — the arguments run together and the division is gone.
    private static func fractions(in text: String) -> String {
        var result = text
        for command in ["\\dfrac", "\\tfrac", "\\frac"] {
            while let range = result.range(of: command) {
                var rest = result[range.upperBound...]
                let numerator = argument(&rest)
                let denominator = argument(&rest)
                let replacement = "\(bracketed(numerator))/\(bracketed(denominator))"
                result = String(result[result.startIndex..<range.lowerBound])
                    + replacement + String(rest)
            }
        }
        return result
    }

    /// `lim_{x \to 1}` becomes lim(x→1). The generic script fallback would have
    /// left `_` and a brace pair that the brace strip then removed, turning it
    /// into a bare "lim_x → 1".
    private static func limits(in text: String) -> String {
        var result = text
        for word in ["lim sup", "lim inf", "lim", "sup", "inf", "max", "min", "argmax", "argmin"] {
            while let range = result.range(of: word + "_") {
                var rest = result[range.upperBound...]
                let body = argument(&rest).trimmingCharacters(in: .whitespaces)
                let replacement = body.isEmpty ? word : "\(word)(\(body))"
                result = String(result[result.startIndex..<range.lowerBound])
                    + replacement + String(rest)
            }
        }
        return result
    }

    /// `\sqrt{x+1}` becomes √(x+1); the brackets are what keep it unambiguous
    /// once the radical has no bar over its content.
    private static func roots(in text: String) -> String {
        var result = text
        while let range = result.range(of: "\\sqrt") {
            var rest = result[range.upperBound...]
            let body = argument(&rest)
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
                // Parentheses, not braces: braces are stripped a step later, and
                // "lim_x → 1" is what that produced.
                result.append(marker)
                result += run.count == 1 ? run : "(\(run))"
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
