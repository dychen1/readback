import Foundation

enum SpeechTextNormalizer {
    static func normalize(_ text: String) -> String {
        let blockText = removeBlockFormatting(from: text)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let inlineText: String
        if let attributed = try? AttributedString(markdown: blockText, options: options) {
            inlineText = String(attributed.characters)
        } else {
            inlineText = blockText
        }

        return inlineText
            .replacingOccurrences(
                of: #"~~(?=\S)(.+?)(?<=\S)~~"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\n[ \t]*\n(?:[ \t]*\n)+"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeBlockFormatting(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let tableRows = tableRowIndexes(in: lines)
        return lines.enumerated().compactMap { index, line in
            if isFence(line) || isRule(line) || isTableDelimiter(line) {
                return nil
            }

            var content = line
                .replacingOccurrences(
                    of: #"^[ \t]{0,3}#{1,6}[ \t]+"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"^[ \t]{0,3}(?:>[ \t]*)+"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"^[ \t]{0,3}(?:[-+*]|\d+[.)])[ \t]+"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"^\[[ xX]\][ \t]+"#,
                    with: "",
                    options: .regularExpression
                )

            if tableRows.contains(index) {
                content = content
                    .trimmingCharacters(in: CharacterSet(charactersIn: "| \t"))
                    .replacingOccurrences(
                        of: #"[ \t]*\|[ \t]*"#,
                        with: ", ",
                        options: .regularExpression
                    )
            }
            return content
        }.joined(separator: "\n")
    }

    private static func tableRowIndexes(in lines: [String]) -> Set<Int> {
        var rows = Set<Int>()
        for index in lines.indices where isTableDelimiter(lines[index]) {
            if index > lines.startIndex, lines[index - 1].contains("|") {
                rows.insert(index - 1)
            }
            var next = index + 1
            while next < lines.endIndex,
                  !lines[next].trimmingCharacters(in: .whitespaces).isEmpty,
                  lines[next].contains("|")
            {
                rows.insert(next)
                next += 1
            }
        }
        return rows
    }

    private static func isFence(_ line: String) -> Bool {
        line.range(
            of: #"^[ \t]{0,3}(?:`{3,}|~{3,})"#,
            options: .regularExpression
        ) != nil
    }

    private static func isRule(_ line: String) -> Bool {
        line.range(
            of: #"^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let cells = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "| \t"))
            .split(separator: "|", omittingEmptySubsequences: false)
        return !cells.isEmpty && cells.allSatisfy { cell in
            String(cell).trimmingCharacters(in: .whitespaces).range(
                of: #"^:?-{3,}:?$"#,
                options: .regularExpression
            ) != nil
        }
    }
}
