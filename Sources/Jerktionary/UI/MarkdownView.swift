import SwiftUI

/// A pragmatic Markdown renderer built on SwiftUI + AttributedString — no
/// external dependencies. Handles the common block elements (headings, ordered
/// and unordered lists, blockquotes, fenced code, horizontal rules, paragraphs)
/// and delegates inline styling (bold/italic/code/links) to AttributedString.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let blocks = MarkdownParser.parse(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Self.inline(content)
                .font(headingFont(level))
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 0)

        case .paragraph(let content):
            Self.inline(content)
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.tint)
                        Self.inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Self.inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let content):
            Self.inline(content)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Theme.tint.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

        case .code(let content):
            Text(content)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .textSelection(.enabled)

        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }

    /// Inline markdown (bold/italic/code/links), preserving whitespace and soft
    /// line breaks. Falls back to plain text if parsing fails.
    static func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}

// MARK: - Parser

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String)
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")

        var index = 0
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushBullets() {
            if !bullets.isEmpty {
                blocks.append(.unorderedList(bullets))
                bullets = []
            }
        }
        func flushOrdered() {
            if !ordered.isEmpty {
                blocks.append(.orderedList(ordered))
                ordered = []
            }
        }
        func flushAll() {
            flushParagraph(); flushBullets(); flushOrdered()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                index += 1 // skip closing fence
                continue
            }

            // Blank line ends the current block group.
            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            // Heading.
            if let heading = matchHeading(trimmed) {
                flushAll()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushBullets(); flushOrdered()
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(content))
                index += 1
                continue
            }

            // Unordered list item.
            if let item = matchUnordered(trimmed) {
                flushParagraph(); flushOrdered()
                bullets.append(item)
                index += 1
                continue
            }

            // Ordered list item.
            if let item = matchOrdered(trimmed) {
                flushParagraph(); flushBullets()
                ordered.append(item)
                index += 1
                continue
            }

            // Plain paragraph line.
            flushBullets(); flushOrdered()
            paragraph.append(line)
            index += 1
        }

        flushAll()
        return blocks
    }

    private static func matchHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" && level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func matchUnordered(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func matchOrdered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return String(afterDigits.dropFirst(2))
    }
}
