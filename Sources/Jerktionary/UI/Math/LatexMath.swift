import Foundation

/// A parsed formula. Deliberately a small tree rather than a string: fractions,
/// roots and matrices are two-dimensional and cannot be expressed as a run of
/// styled characters.
indirect enum MathNode {
    case row([MathNode])
    /// Upright text — `\text{...}`, and words inside formulas.
    case text(String)
    /// A variable. Rendered italic, the way maths sets single letters.
    case variable(String)
    /// Digits, operators and everything else that stays upright.
    case symbol(String)
    case fraction(numerator: MathNode, denominator: MathNode)
    case script(base: MathNode, sub: MathNode?, sup: MathNode?)
    case sqrt(MathNode)
    case matrix(rows: [[MathNode]], delimiter: MatrixDelimiter)
    /// A large operator that carries its limits above and below in display style.
    case bigOperator(String, sub: MathNode?, sup: MathNode?)
    case space(Double)

    var isEmpty: Bool {
        if case .row(let children) = self { return children.isEmpty }
        return false
    }
}

enum MatrixDelimiter {
    case parenthesis
    case bracket
    case brace
    case bar
    case none
}

/// Parser for the subset of LaTeX that shows up in a worked answer: fractions,
/// powers and indices, roots, matrices, Greek letters and the usual operators.
///
/// It is not a TeX engine and does not try to be. Anything it does not know is
/// passed through as text rather than dropped, so an unsupported construct
/// degrades to something readable instead of disappearing.
enum LatexParser {
    static func parse(_ latex: String) -> MathNode {
        var tokenizer = Tokenizer(latex)
        var tokens = tokenizer.tokens()[...]
        return .row(parseSequence(&tokens, stopAt: nil))
    }

    // MARK: Tokens

    private enum Token: Equatable {
        case command(String)
        case lbrace
        case rbrace
        case caret
        case underscore
        case ampersand
        case rowBreak
        case character(Character)
    }

    private struct Tokenizer {
        private let source: [Character]
        private var index = 0

        init(_ text: String) { source = Array(text) }

        mutating func tokens() -> [Token] {
            var result: [Token] = []
            while index < source.count {
                let character = source[index]
                switch character {
                case "\\":
                    index += 1
                    guard index < source.count else { break }
                    if source[index] == "\\" {
                        result.append(.rowBreak)
                        index += 1
                    } else if source[index].isLetter {
                        var name = ""
                        while index < source.count, source[index].isLetter {
                            name.append(source[index])
                            index += 1
                        }
                        result.append(.command(name))
                    } else {
                        // An escaped literal such as \{ or \%.
                        result.append(.character(source[index]))
                        index += 1
                    }
                case "{": result.append(.lbrace); index += 1
                case "}": result.append(.rbrace); index += 1
                case "^": result.append(.caret); index += 1
                case "_": result.append(.underscore); index += 1
                case "&": result.append(.ampersand); index += 1
                default:
                    result.append(.character(character))
                    index += 1
                }
            }
            return result
        }
    }

    // MARK: Grammar

    private static func parseSequence(
        _ tokens: inout ArraySlice<Token>,
        stopAt terminator: String?
    ) -> [MathNode] {
        var nodes: [MathNode] = []
        while let token = tokens.first {
            if case .command(let name) = token, name == "end" {
                if terminator != nil { break }
            }
            if case .rbrace = token { break }

            guard let node = parseAtomWithScripts(&tokens, stopAt: terminator) else { break }
            nodes.append(node)
        }
        return merged(nodes)
    }

    /// Parses one atom, then attaches any `^` / `_` that follow it. Both orders
    /// are accepted, as TeX does.
    private static func parseAtomWithScripts(
        _ tokens: inout ArraySlice<Token>,
        stopAt terminator: String?
    ) -> MathNode? {
        guard var base = parseAtom(&tokens, stopAt: terminator) else { return nil }

        var sub: MathNode?
        var sup: MathNode?
        while let token = tokens.first, token == .caret || token == .underscore {
            tokens = tokens.dropFirst()
            let script = parseAtom(&tokens, stopAt: terminator) ?? .row([])
            if token == .caret { sup = script } else { sub = script }
        }
        guard sub != nil || sup != nil else { return base }

        // Large operators set their limits above and below instead of beside.
        if case .bigOperator(let glyph, _, _) = base {
            return .bigOperator(glyph, sub: sub, sup: sup)
        }
        if case .row(let children) = base, children.count == 1 {
            base = children[0]
        }
        return .script(base: base, sub: sub, sup: sup)
    }

    private static func parseAtom(
        _ tokens: inout ArraySlice<Token>,
        stopAt terminator: String?
    ) -> MathNode? {
        guard let token = tokens.first else { return nil }
        tokens = tokens.dropFirst()

        switch token {
        case .lbrace:
            let children = parseSequence(&tokens, stopAt: terminator)
            if tokens.first == .rbrace { tokens = tokens.dropFirst() }
            return .row(children)

        case .rbrace:
            return nil

        case .character(let character):
            if character == " " { return .space(0.28) }
            if character.isLetter { return .variable(String(character)) }
            // U+2212, not the hyphen the source uses: next to a unary "−1" the
            // shorter glyph reads as a different mark.
            if character == "-" { return .symbol("−") }
            return .symbol(String(character))

        case .caret, .underscore:
            // A stray script marker with nothing before it.
            return .symbol(token == .caret ? "^" : "_")

        case .ampersand, .rowBreak:
            // Only meaningful inside a matrix, which consumes them itself.
            return .space(0.2)

        case .command(let name):
            return parseCommand(name, &tokens, stopAt: terminator)
        }
    }

    private static func parseCommand(
        _ name: String,
        _ tokens: inout ArraySlice<Token>,
        stopAt terminator: String?
    ) -> MathNode? {
        switch name {
        case "frac", "dfrac", "tfrac":
            let numerator = parseAtom(&tokens, stopAt: terminator) ?? .row([])
            let denominator = parseAtom(&tokens, stopAt: terminator) ?? .row([])
            return .fraction(numerator: numerator, denominator: denominator)

        case "sqrt":
            return .sqrt(parseAtom(&tokens, stopAt: terminator) ?? .row([]))

        case "text", "mathrm", "operatorname", "mathbf", "mathit", "mathsf":
            let content = parseAtom(&tokens, stopAt: terminator) ?? .row([])
            return .text(flatten(content))

        case "begin":
            let environment = flatten(parseAtom(&tokens, stopAt: terminator) ?? .row([]))
            return parseEnvironment(environment, &tokens)

        case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "limits":
            // Sizing hints this renderer does not need; the delimiter that
            // follows \left or \right is emitted as an ordinary symbol.
            return .row([])

        case "quad": return .space(1.0)
        case "qquad": return .space(2.0)
        case ",", ":", ";": return .space(0.2)

        case "sum": return .bigOperator("∑", sub: nil, sup: nil)
        case "prod": return .bigOperator("∏", sub: nil, sup: nil)
        case "int": return .bigOperator("∫", sub: nil, sup: nil)
        case "lim": return .bigOperator("lim", sub: nil, sup: nil)

        default:
            if let glyph = Symbols.table[name] {
                return .symbol(glyph)
            }
            if let function = Symbols.functions[name] {
                return .text(function)
            }
            // Unknown: show it rather than swallow it.
            return .text("\\" + name)
        }
    }

    private static func parseEnvironment(
        _ environment: String,
        _ tokens: inout ArraySlice<Token>
    ) -> MathNode {
        let delimiter: MatrixDelimiter
        switch environment {
        case "pmatrix": delimiter = .parenthesis
        case "bmatrix": delimiter = .bracket
        case "Bmatrix": delimiter = .brace
        case "vmatrix": delimiter = .bar
        default: delimiter = .none
        }

        var rows: [[MathNode]] = []
        var row: [MathNode] = []
        var cell: [MathNode] = []

        func endCell() {
            row.append(.row(merged(cell)))
            cell = []
        }
        func endRow() {
            endCell()
            rows.append(row)
            row = []
        }

        while let token = tokens.first {
            if case .command(let name) = token, name == "end" {
                tokens = tokens.dropFirst()
                _ = parseAtom(&tokens, stopAt: nil) // the environment name
                break
            }
            if token == .ampersand {
                tokens = tokens.dropFirst()
                endCell()
                continue
            }
            if token == .rowBreak {
                tokens = tokens.dropFirst()
                endRow()
                continue
            }
            guard let node = parseAtomWithScripts(&tokens, stopAt: environment) else { break }
            cell.append(node)
        }
        if !cell.isEmpty || !row.isEmpty { endRow() }

        return .matrix(rows: rows, delimiter: delimiter)
    }

    // MARK: Helpers

    /// Joins neighbouring digits, binds a unary sign to the number it belongs to,
    /// and drops empty rows.
    private static func merged(_ nodes: [MathNode]) -> [MathNode] {
        var result: [MathNode] = []
        for node in nodes {
            if case .row(let children) = node, children.isEmpty { continue }

            guard case .symbol(let value) = node, value.count == 1,
                  value.first!.isNumber || value == "."
            else {
                result.append(node)
                continue
            }

            // Digits of one number.
            if case .symbol(let previous)? = result.last,
               previous.allSatisfy({ $0.isNumber || $0 == "." }) {
                result[result.count - 1] = .symbol(previous + value)
                continue
            }
            // A sign with no left operand is part of the number, not an operation
            // between two: "−1", never "− 1".
            if case .symbol(let sign)? = result.last, sign == "-" || sign == "−" || sign == "+",
               isUnaryPosition(before: result.count - 1, in: result) {
                result[result.count - 1] = .symbol((sign == "+" ? "+" : "−") + value)
                continue
            }
            result.append(node)
        }
        return result
    }

    /// True when nothing usable sits to the left, so the sign cannot be binary.
    /// Spaces are skipped: "x \to -1" puts one between the arrow and the sign,
    /// and stopping at it made every such minus look binary.
    private static func isUnaryPosition(before index: Int, in nodes: [MathNode]) -> Bool {
        var cursor = index - 1
        while cursor >= 0, case .space = nodes[cursor] { cursor -= 1 }
        guard cursor >= 0 else { return true }
        guard case .symbol(let previous) = nodes[cursor] else { return false }
        let binary: Set<String> = [
            "=", "+", "-", "−", "×", "·", "÷", "±", "<", ">", "≤", "≥", "≠", "≈",
            "→", "←", "↔", "⇒", "(", "[", ",", "∈", "∪", "∩"
        ]
        return binary.contains(previous)
    }

    static func flatten(_ node: MathNode) -> String {
        switch node {
        case .row(let children): children.map(flatten).joined()
        case .text(let value), .variable(let value), .symbol(let value): value
        case .fraction(let numerator, let denominator):
            "\(flatten(numerator))/\(flatten(denominator))"
        case .script(let base, let sub, let sup):
            flatten(base) + (sub.map { "_" + flatten($0) } ?? "")
                + (sup.map { "^" + flatten($0) } ?? "")
        case .sqrt(let value): "√" + flatten(value)
        case .matrix(let rows, _):
            rows.map { $0.map(flatten).joined(separator: " ") }.joined(separator: "; ")
        case .bigOperator(let glyph, _, _): glyph
        case .space: " "
        }
    }
}

/// Glyphs for the commands a worked answer actually uses.
enum Symbols {
    static let table: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝",
        "ll": "≪", "gg": "≫", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
        "in": "∈", "notin": "∉", "cup": "∪", "cap": "∩", "emptyset": "∅",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "mapsto": "↦",
        "infty": "∞", "partial": "∂", "nabla": "∇", "prime": "′",
        "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "degree": "°",
        "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ",
        "oplus": "⊕", "otimes": "⊗", "circ": "∘", "bullet": "∙", "star": "⋆"
    ]

    /// Names set upright rather than italic.
    static let functions: [String: String] = [
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec",
        "csc": "csc", "arcsin": "arcsin", "arccos": "arccos", "arctan": "arctan",
        "sinh": "sinh", "cosh": "cosh", "tanh": "tanh",
        "log": "log", "ln": "ln", "lg": "lg", "exp": "exp",
        "det": "det", "dim": "dim", "ker": "ker", "deg": "deg", "gcd": "gcd",
        "min": "min", "max": "max", "arg": "arg", "mod": "mod", "rank": "rank"
    ]
}
