import Foundation

/// Pipes selected rows through a host-run shell command and replaces them with
/// its output, like TextMate's Filter Through Command or Vim's `!`.
///
/// Each selected subtree root is one stdin line of plain text; children are
/// not sent and travel with their parent. Output lines map back onto rows:
/// a line identical to an input line keeps that row (kind, marks, children),
/// remaining changed lines pair in order with the remaining rows (new text,
/// same kind and children), extra lines become new rows shaped like the row
/// above them, and rows left without a line are removed.
public struct FilterThroughCommandInput: Equatable, Sendable {
    public let rows: [Block]
    public let lines: [String]

    public var stdin: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

public enum FilterThroughCommandError: LocalizedError, Equatable {
    case rowsChanged

    public var errorDescription: String? {
        switch self {
        case .rowsChanged:
            "The selected rows changed while the command was running."
        }
    }
}

@MainActor
public enum FilterThroughCommand {
    /// Text rows among the selection's subtree roots, in document order.
    public static func input(in document: Document, selection: Set<BlockID>) -> FilterThroughCommandInput {
        let rows = document.selectionSubtreeRoots(selection)
            .compactMap(document.find)
            .filter(\.isFilterable)
        return FilterThroughCommandInput(rows: rows, lines: rows.map(line(for:)))
    }

    /// Splits stdout into lines, ignoring the final newline.
    public static func lines(fromOutput output: String) -> [String] {
        var lines = output.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// The rows that replace `input.rows`, in order.
    public static func replacementRows(for input: FilterThroughCommandInput, output: [String]) -> [Block] {
        var used = Array(repeating: false, count: input.rows.count)
        var result: [Block?] = Array(repeating: nil, count: output.count)

        for (j, line) in output.enumerated() {
            if let i = input.lines.indices.first(where: { !used[$0] && input.lines[$0] == line }) {
                used[i] = true
                result[j] = input.rows[i]
            }
        }
        var leftovers = input.rows.indices.filter { !used[$0] }.makeIterator()
        for j in output.indices where result[j] == nil {
            guard let i = leftovers.next() else { break }
            result[j] = input.rows[i].withText(AttributedString(output[j]))
        }
        for j in output.indices where result[j] == nil {
            let above = j > 0 ? result[j - 1] : nil
            let shape = above ?? result[j...].lazy.compactMap { $0 }.first ?? input.rows.first ?? .paragraph()
            result[j] = Block(kind: shape.withText(AttributedString(output[j])).kind)
        }
        return result.compactMap { $0 }
    }

    /// Replaces `input.rows` with the filtered rows at the first row's place.
    /// Returns the replacement rows. Throws if any input row changed since
    /// `input` was captured.
    @discardableResult
    public static func apply(
        output: [String],
        for input: FilterThroughCommandInput,
        to document: Document
    ) throws -> [Block] {
        guard let first = input.rows.first else { return [] }
        guard isCurrent(input, in: document),
              let path = document.path(to: first.id),
              let position = path.last else {
            throw FilterThroughCommandError.rowsChanged
        }
        let parent = document.parent(of: first.id)
        let replacements = replacementRows(for: input, output: output)
        for row in input.rows {
            document.removeSubtree(row.id)
        }
        document.insertSubtrees(replacements, at: DropPath(parent: parent, position: position))
        return replacements
    }

    /// Whether every input row is still in the document unchanged.
    public static func isCurrent(_ input: FilterThroughCommandInput, in document: Document) -> Bool {
        input.rows.allSatisfy { document.find($0.id) == $0 }
    }

    static func line(for block: Block) -> String {
        String(block.text.characters)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private extension Block {
    var isFilterable: Bool {
        switch kind {
        case .paragraph, .heading, .bullet, .numbered, .todo, .quote, .toggle:
            true
        case .templateButton, .code, .divider, .documentLink, .image, .unsupported:
            false
        }
    }
}
