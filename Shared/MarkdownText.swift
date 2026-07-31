import SwiftUI

/// 依存ライブラリなしの簡易 Markdown 表示。
/// ブロック要素（見出し・箇条書き・番号リスト・コードブロック・引用・区切り線）を
/// 自前で分割し、インライン装飾（**強調**・`コード`・リンク）は
/// AttributedString の Markdown パーサに任せる。
/// 会話の閲覧用なので、表など未対応の要素はそのまま段落として出す
struct MarkdownText: View {
    let text: String
    /// 画面が狭い環境（Apple Watch）向けに表を詰めるか。
    /// iPhone では列も行も省略せず、セルも折り返して全部見せる
    var compact: Bool = false

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
        case table(MarkdownTable)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var quotes: [String] = []
        var inCode = false
        /// 表として消費した行の次の位置。ここより前の行は読み飛ばす
        var consumedUpTo = 0

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

        let allLines = text.components(separatedBy: "\n")
        var lineIndex = -1
        for rawLine in allLines {
            lineIndex += 1
            // 表はヘッダ行の位置でまとめて消費するので、消費済みの行は読み飛ばす
            if lineIndex < consumedUpTo { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // コードブロックの中でなければ、表の開始（ヘッダ + 区切り行）を探す
            if !inCode, line.contains("|") {
                let next = lineIndex + 1 < allLines.count
                    ? allLines[lineIndex + 1].trimmingCharacters(in: .whitespaces) : ""
                if MarkdownTable.isSeparator(next) {
                    flush()
                    var cursor = lineIndex + 2
                    var rows: [[String]] = []
                    while cursor < allLines.count {
                        let row = allLines[cursor].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|"),
                              !MarkdownTable.isSeparator(row) else { break }
                        rows.append(MarkdownTable.splitRow(row))
                        cursor += 1
                    }
                    blocks.append(.table(MarkdownTable(
                        headers: MarkdownTable.splitRow(line), rows: rows)))
                    consumedUpTo = cursor
                    continue
                }
            }

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

    /// 本文のフォント。Watch（compact）では周囲のテキスト（.footnote）と
    /// 大きさを揃える——.subheadline のままだと「入力」欄などより一回り大きく
    /// 見えて不揃いだった
    private var bodyFont: Font { compact ? .footnote : .subheadline }

    // MARK: 描画

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(bodyFont)

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
            // watchOS には systemBackground が無いので、
            // プラットフォーム非依存の primary の薄塗りで代用する
            .background(Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(Self.inline(item))
                    }
                    .font(bodyFont)
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
                    .font(bodyFont)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
            }

        case .divider:
            Divider()

        case .table(let table):
            // iPhone は領域に余裕があるので列も行も削らずセルは折り返す。
            // Watch は横幅が足りないので 2 列までに絞り、溢れた分は
            // MarkdownTableView 側が「…」列と「ほか n 行」で示す
            MarkdownTableView(
                table: table,
                maxColumns: compact ? 2 : max(table.columnCount, 1),
                maxRows: compact ? 6 : max(table.rows.count, 1),
                font: compact ? .caption2 : .caption,
                cellLineLimit: compact ? 2 : 4)
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
