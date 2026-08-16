import SwiftUI

/// Renders a parsed formula.
///
/// A view tree rather than an attributed string, because the parts that make a
/// formula readable — a fraction bar between stacked terms, a radical over its
/// content, a bracketed grid — are two-dimensional and have no representation in
/// a run of styled text.
struct MathView: View {
    let latex: String
    var size: CGFloat = 16

    var body: some View {
        MathNodeView(node: LatexParser.parse(latex), size: size)
            // Formulas are read, not spoken by VoiceOver glyph by glyph.
            .accessibilityElement()
            .accessibilityLabel("Formula: \(LatexParser.flatten(LatexParser.parse(latex)))")
    }
}

private struct MathNodeView: View {
    let node: MathNode
    let size: CGFloat

    /// Scripts and matrix cells step down; the ratio is the one TeX uses.
    private var scriptSize: CGFloat { size * 0.72 }

    var body: some View {
        switch node {
        case .row(let children):
            HStack(alignment: .mathBaseline, spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    MathNodeView(node: child, size: size)
                }
            }

        case .text(let value):
            Text(value)
                .font(.system(size: size))
                .alignmentGuide(.mathBaseline) { $0[.firstTextBaseline] }

        case .variable(let value):
            Text(value)
                .font(.system(size: size).italic())
                .alignmentGuide(.mathBaseline) { $0[.firstTextBaseline] }

        case .symbol(let value):
            Text(value)
                .font(.system(size: size))
                .padding(.horizontal, Self.spacing(around: value, size: size))
                .alignmentGuide(.mathBaseline) { $0[.firstTextBaseline] }

        case .space(let width):
            Color.clear.frame(width: size * width, height: 1)

        case .fraction(let numerator, let denominator):
            VStack(spacing: size * 0.12) {
                MathNodeView(node: numerator, size: size * 0.95)
                Rectangle()
                    .frame(height: max(1, size * 0.055))
                MathNodeView(node: denominator, size: size * 0.95)
            }
            .fixedSize()
            .padding(.horizontal, size * 0.12)
            // The bar sits where the minus sign would, which is what puts the
            // fraction on the same visual line as the rest of the row.
            .alignmentGuide(.mathBaseline) { $0.height / 2 + size * 0.28 }

        case .script(let base, let sub, let sup):
            HStack(alignment: .mathBaseline, spacing: 0) {
                MathNodeView(node: base, size: size)
                VStack(alignment: .leading, spacing: 0) {
                    if let sup {
                        MathNodeView(node: sup, size: scriptSize)
                    }
                    if let sub {
                        MathNodeView(node: sub, size: scriptSize)
                    }
                }
                .padding(.leading, size * 0.04)
                .alignmentGuide(.mathBaseline) { dimension in
                    // One script hangs off the baseline; two straddle it.
                    if sup != nil && sub != nil { return dimension.height / 2 + size * 0.28 }
                    return sup != nil ? dimension.height + size * 0.02 : size * 0.28
                }
            }

        case .sqrt(let content):
            HStack(alignment: .mathBaseline, spacing: 0) {
                RadicalSign(size: size)
                MathNodeView(node: content, size: size)
                    .padding(.horizontal, size * 0.1)
                    .overlay(alignment: .top) {
                        Rectangle().frame(height: max(1, size * 0.055))
                    }
                    .padding(.top, max(1, size * 0.055))
            }

        case .matrix(let rows, let delimiter):
            MatrixView(rows: rows, delimiter: delimiter, size: size)

        case .bigOperator(let glyph, let sub, let sup):
            VStack(spacing: 0) {
                if let sup { MathNodeView(node: sup, size: scriptSize) }
                // ∑ and ∫ are drawn oversized; a word like "lim" is set at the
                // body size, or it shouts over the expression it introduces.
                Text(glyph)
                    .font(.system(size: glyph.count == 1 ? size * 1.5 : size))
                if let sub { MathNodeView(node: sub, size: scriptSize) }
            }
            .fixedSize()
            .padding(.horizontal, size * 0.12)
            .alignmentGuide(.mathBaseline) { $0.height / 2 + size * 0.28 }
        }
    }

    /// Relations and binary operators get air; punctuation and primes do not.
    private static func spacing(around value: String, size: CGFloat) -> CGFloat {
        let tight: Set<String> = [",", ".", "!", "'", "′", "(", ")", "[", "]", "|"]
        if tight.contains(value) { return 0 }
        let operators: Set<String> = [
            "+", "−", "-", "=", "×", "·", "÷", "±", "∓", "≤", "≥", "≠", "≈", "≡",
            "<", ">", "→", "←", "↔", "⇒", "⇐", "⇔", "∈", "∉", "⊂", "⊆", "∪", "∩", "↦"
        ]
        return operators.contains(value) ? size * 0.22 : size * 0.04
    }
}

/// The √ sign, drawn rather than typed: the character does not scale to the
/// height of what it covers.
private struct RadicalSign: View {
    let size: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size * 0.55))
            path.addLine(to: CGPoint(x: size * 0.18, y: size * 0.5))
            path.addLine(to: CGPoint(x: size * 0.34, y: size * 0.95))
            path.addLine(to: CGPoint(x: size * 0.52, y: 0))
        }
        .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.055), lineCap: .round, lineJoin: .round))
        .frame(width: size * 0.55, height: size)
        .alignmentGuide(.mathBaseline) { _ in size * 0.98 }
    }
}

private struct MatrixView: View {
    let rows: [[MathNode]]
    let delimiter: MatrixDelimiter
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.14) {
            if delimiter != .none {
                Delimiter(kind: delimiter, leading: true)
                    .stroke(lineWidth: max(1, size * 0.06))
                    .frame(width: size * 0.34)
            }
            Grid(horizontalSpacing: size * 0.6, verticalSpacing: size * 0.3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            MathNodeView(node: cell, size: size)
                        }
                    }
                }
            }
            .padding(.vertical, size * 0.15)
            if delimiter != .none {
                Delimiter(kind: delimiter, leading: false)
                    .stroke(lineWidth: max(1, size * 0.06))
                    .frame(width: size * 0.34)
            }
        }
        .fixedSize()
        .alignmentGuide(.mathBaseline) { $0.height / 2 + size * 0.28 }
    }
}

/// Brackets as paths so they grow with the grid; a typed "(" stays one line tall
/// no matter how many rows it is supposed to embrace.
private struct Delimiter: Shape {
    let kind: MatrixDelimiter
    let leading: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.width * 0.2
        let near = leading ? rect.maxX - inset : rect.minX + inset
        let far = leading ? rect.minX + inset : rect.maxX - inset

        switch kind {
        case .parenthesis:
            path.move(to: CGPoint(x: near, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: near, y: rect.maxY),
                control: CGPoint(x: far - (near - far) * 0.6, y: rect.midY)
            )
        case .bracket:
            path.move(to: CGPoint(x: near, y: rect.minY))
            path.addLine(to: CGPoint(x: far, y: rect.minY))
            path.addLine(to: CGPoint(x: far, y: rect.maxY))
            path.addLine(to: CGPoint(x: near, y: rect.maxY))
        case .brace:
            path.move(to: CGPoint(x: near, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: far, y: rect.midY),
                control: CGPoint(x: far, y: rect.minY + rect.height * 0.25)
            )
            path.addQuadCurve(
                to: CGPoint(x: near, y: rect.maxY),
                control: CGPoint(x: far, y: rect.maxY - rect.height * 0.25)
            )
        case .bar:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case .none:
            break
        }
        return path
    }
}

extension VerticalAlignment {
    /// Formula parts line up on the maths axis, not on the top or centre of
    /// their boxes — a fraction and the `=` beside it have to agree on where
    /// the line through the row runs.
    private enum MathBaseline: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.firstTextBaseline]
        }
    }

    static let mathBaseline = VerticalAlignment(MathBaseline.self)
}
