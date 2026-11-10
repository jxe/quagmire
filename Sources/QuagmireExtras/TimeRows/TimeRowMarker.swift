import Quagmire
import SwiftUI

public extension EditorBulletMarker {
    /// Time rows: a bullet whose whole text is a time range ("9 to 11",
    /// "noon until 2") gets a clock that opens a start and end editor.
    /// Moving a row's end moves every later time row beside it by the same
    /// amount. Time rows are not offered in Turn Into; typing a range makes one.
    static var timeRows: EditorBulletMarker {
        EditorBulletMarker(
            id: "quagmire.time-rows",
            title: "Time",
            systemImage: "clock",
            recognizes: { TimeRange.parse($0) != nil }
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
