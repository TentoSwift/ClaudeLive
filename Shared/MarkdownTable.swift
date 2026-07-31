import SwiftUI

/// Markdown の表（パイプ記法）を扱う。依存ライブラリなし。
///
/// ライブアクティビティは領域が狭く、返答は 300 文字に切り詰められて届くため、
/// 「表の途中で切れた入力」が普通に来る。そのため区切り行までしか無い表や
/// セル数が揃わない行も捨てずに、あるところまで描けるように寛容に解釈する。
///
/// アプリ内の会話表示（MarkdownText）とライブアクティビティ（Widget）の
/// 両方から使うので Shared に置いている。
struct MarkdownTable: Equatable {
    /// ヘッダ行のセル
    var headers: [String]
    /// 本体行。行ごとのセル数は headers と一致しないことがある（切れた入力）
    var rows: [[String]]

    /// 実際に描くべき列数。ヘッダと本体で食い違うときは広い方に合わせる
    var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    /// `| a | b |` 形式の1行をセルに分割する。
    /// 前後のパイプは省略可（`a | b` でも通す）
    static func splitRow(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `|---|:--:|` のような区切り行か。表と判定する決め手になる
    static func isSeparator(_ line: String) -> Bool {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    /// 表の一部になり得る行か（パイプを含み、かつ区切り行も許容）
    private static func looksLikeRow(_ line: String) -> Bool {
        line.contains("|")
    }
}

// MARK: - テキストの分割

/// 本文を「ふつうのテキスト」と「表」に切り分けた結果
enum MarkdownSegment: Equatable {
    case text(String)
    case table(MarkdownTable)
}

extension MarkdownTable {
    /// 本文を走査して、表とそれ以外に分割する。
    /// 表と判定する条件は「パイプを含む行が2行以上続き、2行目が区切り行」。
    /// 区切り行を必須にすることで、文章中の `a | b` のような偶発的なパイプを
    /// 表と誤検出しないようにしている
    static func segments(_ text: String) -> [MarkdownSegment] {
        let lines = text.components(separatedBy: "\n")
        var result: [MarkdownSegment] = []
        var buffer: [String] = []
        var index = 0

        func flushText() {
            let joined = buffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(joined))
            }
            buffer = []
        }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            // ヘッダ行 + 区切り行が揃って初めて表とみなす
            let next = index + 1 < lines.count
                ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            guard looksLikeRow(line), isSeparator(next) else {
                buffer.append(lines[index])
                index += 1
                continue
            }

            flushText()
            let headers = splitRow(line)
            var rows: [[String]] = []
            index += 2  // ヘッダと区切りを消費
            while index < lines.count {
                let row = lines[index].trimmingCharacters(in: .whitespaces)
                // 表の終わり: 空行、またはパイプを含まない行
                guard !row.isEmpty, looksLikeRow(row), !isSeparator(row) else { break }
                rows.append(splitRow(row))
                index += 1
            }
            result.append(.table(MarkdownTable(headers: headers, rows: rows)))
        }
        flushText()
        return result
    }

    /// 表を描かない狭い場所（Watch の Smart Stack など）向けに、表を
    /// 「（表）」に畳んだ 1 行のテキストを返す。
    ///
    /// 表を含む返答では改行が保持されて届くため、素のまま出すと
    /// `| 項目 | 結果 |` `|---|---|` といったパイプ記法が表示行を埋めてしまう。
    /// 表そのものは iPhone やアプリ内で見られるので、ここでは畳んで
    /// 前後の文章にスペースを譲る
    static func flattenedWithoutTables(_ text: String) -> String {
        let parts: [String] = segments(text).map { segment in
            switch segment {
            case .text(let body):
                return body.replacingOccurrences(of: "\n", with: " ")
            case .table:
                return "（表）"
            }
        }
        return parts
            .joined(separator: " ")
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 本文に表が含まれるか（描画側で分岐を省くための軽い判定）
    static func containsTable(_ text: String) -> Bool {
        segments(text).contains {
            if case .table = $0 { return true }
            return false
        }
    }
}

// MARK: - 表示

/// 表をコンパクトなグリッドとして描く。
/// ライブアクティビティでも使うため、ScrollView（ウィジェットでは効かない）は使わず、
/// 列数・行数の上限で領域に収める。
struct MarkdownTableView: View {
    let table: MarkdownTable
    /// 表示する最大列数。溢れた列は落として末尾に「…」列を出す
    var maxColumns: Int = 4
    /// 表示する最大本体行数。溢れた行は「ほか n 行」と要約する
    var maxRows: Int = 6
    var font: Font = .caption2
    /// セル内の最大行数。ライブアクティビティでは 1 にして高さを固定する
    var cellLineLimit: Int = 2

    private var shownColumnCount: Int {
        min(table.columnCount, maxColumns)
    }
    private var hasHiddenColumns: Bool {
        table.columnCount > maxColumns
    }
    private var shownRows: [[String]] {
        Array(table.rows.prefix(maxRows))
    }
    private var hiddenRowCount: Int {
        max(0, table.rows.count - maxRows)
    }

    /// 行から index 番目のセルを取る。切れた入力で足りない場合は空文字
    private func cell(_ row: [String], _ index: Int) -> String {
        index < row.count ? row[index] : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            ForEach(Array(shownRows.enumerated()), id: \.offset) { offset, row in
                Divider().opacity(0.35)
                bodyRow(row, isAlternate: offset.isMultiple(of: 2))
            }
            if hiddenRowCount > 0 {
                Divider().opacity(0.35)
                Text("ほか \(hiddenRowCount) 行")
                    .font(font)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 5)
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<shownColumnCount, id: \.self) { column in
                cellText(cell(table.headers, column), isHeader: true)
                if column < shownColumnCount - 1 {
                    columnSeparator
                }
            }
            if hasHiddenColumns {
                columnSeparator
                overflowMark("…")
            }
        }
        .background(Color.primary.opacity(0.06))
    }

    private func bodyRow(_ row: [String], isAlternate: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<shownColumnCount, id: \.self) { column in
                cellText(cell(row, column), isHeader: false)
                if column < shownColumnCount - 1 {
                    columnSeparator
                }
            }
            if hasHiddenColumns {
                columnSeparator
                overflowMark("")
            }
        }
    }

    /// 省略列を示すだけの細い列。ここに通常のセル幅を与えると
    /// 空白が表の2割近くを占めてしまうので、固定幅にする
    private func overflowMark(_ text: String) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .padding(.vertical, 3)
    }

    private var columnSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5)
    }

    private func cellText(_ text: String, isHeader: Bool) -> some View {
        // セル内のインライン装飾（**強調** など）は表では潰して素の文字として出す。
        // 狭い領域で太字が混ざると桁が揃わず読みにくくなるため
        // 本体セルは実データなので .primary で読みやすく、見出しは
        // ラベルにすぎないので .secondary + 太字にして役割を区別する。
        // （逆にすると、ロック画面では肝心の中身が薄く沈んで読めなかった）
        Text(text.replacingOccurrences(of: "**", with: ""))
            .font(isHeader ? font.weight(.semibold) : font)
            .foregroundStyle(isHeader ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(cellLineLimit)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
    }
}

/// 返答テキストを、表だけグリッドにして描く。
/// 表を含まない大多数のケースでは今までどおり単一の Text に落ちるので、
/// マーキーや lineLimit の挙動を変えない
struct ResponseBodyView: View {
    let text: String
    /// 表を含まないときの行数上限（従来の .lineLimit をそのまま渡す）
    var lineLimit: Int
    var font: Font = .footnote
    /// 表のセルを何行まで折り返すか。狭いロック画面では 1 にする
    var tableCellLineLimit: Int = 1
    /// 表の本体行の上限
    var tableMaxRows: Int = 4

    /// インライン装飾の解釈。Widget 側の styledMarkdown と同じ扱い
    private func styled(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }

    var body: some View {
        let segments = MarkdownTable.segments(text)
        let hasTable = segments.contains { if case .table = $0 { return true }; return false }

        if !hasTable {
            // 従来と完全に同じ描画（表がないときに挙動を変えないため）
            Text(styled(text))
                .font(font)
                .lineLimit(lineLimit)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let body):
                        Text(styled(body))
                            .font(font)
                            .lineLimit(2)
                    case .table(let table):
                        MarkdownTableView(
                            table: table,
                            maxRows: tableMaxRows,
                            font: font == .footnote ? .caption2 : font,
                            cellLineLimit: tableCellLineLimit)
                    }
                }
            }
        }
    }
}
