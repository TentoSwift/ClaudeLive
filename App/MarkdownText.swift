import SwiftUI

/// 依存ライブラリなしの簡易 Markdown 表示。
/// ブロック要素（見出し・箇条書き・番号リスト・コードブロック・引用・区切り線）を
/// 自前で分割し、インライン装飾（**強調**・`コード`・リンク）は
/// AttributedString の Markdown パーサに任せる。
/// 会話の閲覧用なので、表など未対応の要素はそのまま段落として出す
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: ブロック構造

    enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(String)
        case bullet([String])
        case numbered([String])
        case quote(String)
        case divider
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var quotes: [String] = []
        var inCode = false

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !bullets.isEmpty {
                blocks.append(.bullet(bullets))
                bullets = []
            }
            if !numbers.isEmpty {
                blocks.append(.numbered(numbers))
                numbers = []
            }
            if !quotes.isEmpty {
                blocks.append(.quote(quotes.joined(separator: "\n")))
                quotes = []
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flush()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flush()
            } else if let heading = parseHeading(line) {
                flush()
                blocks.append(.heading(level: heading.0, text: heading.1))
            } else if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.divider)
            } else if let item = stripPrefix(line, ["- ", "* ", "+ "]) {
                if !numbers.isEmpty || !paragraph.isEmpty || !quotes.isEmpty { flush() }
                bullets.append(item)
            } else if let item = stripNumberPrefix(line) {
                if !bullets.isEmpty || !paragraph.isEmpty || !quotes.isEmpty { flush() }
                numbers.append(item)
            } else if line.hasPrefix("> ") || line == ">" {
                if !bullets.isEmpty || !numbers.isEmpty || !paragraph.isEmpty { flush() }
                quotes.append(String(line.dropFirst(min(2, line.count))))
            } else {
                if !bullets.isEmpty || !numbers.isEmpty || !quotes.isEmpty { flush() }
                paragraph.append(rawLine)
            }
        }
        if inCode, !codeLines.isEmpty {
            // 閉じられていないフェンスはコードとして出す
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func stripPrefix(_ line: String, _ prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func stripNumberPrefix(_ line: String) -> String? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " ",
              !line[..<dot].isEmpty,
              line[..<dot].allSatisfy(\.isNumber) else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    // MARK: 描画

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.subheadline)

        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .headline : (level == 2 ? .subheadline.bold() : .footnote.bold()))
                .padding(.top, 2)

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.caption.monospaced())
                    .padding(8)
            }
            .background(Color(.systemBackground).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 8))

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(Self.inline(item))
                    }
                    .font(.subheadline)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        Text(Self.inline(item))
                    }
                    .font(.subheadline)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .divider:
            Divider()
        }
    }

    /// インライン装飾のみ AttributedString の Markdown パーサに任せる
    static func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }
}
