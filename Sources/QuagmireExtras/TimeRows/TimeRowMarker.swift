import Quagmire
import SwiftUI

public extension EditorBulletMarker {
    /// Time rows: a bullet whose whole text is a time range ("9 to 11",
    /// "noon until 2") gets a clock that opens a start and end editor.
    /// Moving a row's end moves every later time row beside it by the same
    /// amount. Turn Into offers Time for any text-bearing block.
    static var timeRows: EditorBulletMarker {
        EditorBulletMarker(
            id: "quagmire.time-rows",
            title: "Time",
            systemImage: "clock",
            turnIntoShortcut: "h",
            recognizes: { TimeRange.parse($0) != nil },
            turnInto: TimeRows.turnInto
        ) { context in
            if let range = TimeRows.range(of: context.block) {
                TimeRowEditor(range: range, feedback: context.selectionFeedback) { edit in
                    let plan = TimeRows.plan(edit, on: context.block.id, in: context.document)
                    context.apply(
                        plan.map { BlockReplacement(blockID: $0.key, kind: .bullet(text: AttributedString($0.value.text))) },
                        actionName: "Change Time"
                    )
                }
            }
        }
    }
}

extension TimeRows {
    /// A block that already reads as a time range becomes that time row.
    /// Anything else gets the hour after the time row above it (or the next
    /// hour from now), and its words move into a bullet under the new time.
    static func turnInto(_ block: Block, in document: Quagmire.Document) -> Block? {
        let text = block.text
        let words = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        var replacement = block
        if TimeRange.parse(words) != nil {
            replacement.kind = .bullet(text: text)
            return replacement
        }
        let range = defaultRange(before: block.id, in: document)
        replacement.kind = .bullet(text: AttributedString(range.text))
        if !words.isEmpty {
            replacement.children.insert(.bullet(text: text), at: 0)
        }
        return replacement
    }

    /// An hour starting where the nearest time row above ends, or at the
    /// next whole hour when there is none.
    static func defaultRange(before blockID: BlockID, in document: Quagmire.Document, now: Date = Date()) -> TimeRange {
        var previousEnd: Int?
        var reached = false
        document.walk { block, _, _ in
            if block.id == blockID { reached = true }
            guard !reached, let range = range(of: block) else { return }
            previousEnd = range.end
        }
        if let previousEnd {
            return TimeRange(start: previousEnd, end: previousEnd + 60)
        }
        let hour = Calendar.current.component(.hour, from: now)
        let start = (hour + 1) * 60
        return TimeRange(start: start, end: start + 60)
    }
}
