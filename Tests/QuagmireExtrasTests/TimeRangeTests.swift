import Foundation
import Testing
import Quagmire
@testable import QuagmireExtras

@Suite struct TimeRangeTests {
    private func r(_ startHour: Int, _ startMinute: Int = 0, to endHour: Int, _ endMinute: Int = 0) -> TimeRange {
        TimeRange(start: startHour * 60 + startMinute, end: endHour * 60 + endMinute)
    }

    @Test func readsDictatedDayBlocks() {
        #expect(TimeRange.parse("9 to 11") == r(9, to: 11))
        #expect(TimeRange.parse("11 to one") == r(11, to: 13))
        #expect(TimeRange.parse("1-3") == r(13, to: 15))
        #expect(TimeRange.parse("From 3 until 5.") == r(15, to: 17))
        #expect(TimeRange.parse("noon to 2") == r(12, to: 14))
        #expect(TimeRange.parse("10 to 12") == r(10, to: 12))
    }

    @Test func readsMinutesAndMeridiems() {
        #expect(TimeRange.parse("9:30–11am") == r(9, 30, to: 11))
        #expect(TimeRange.parse("8 to 10pm") == r(20, to: 22))
        #expect(TimeRange.parse("7pm-9pm") == r(19, to: 21))
        #expect(TimeRange.parse("14:00-16:30") == r(14, to: 16, 30))
        #expect(TimeRange.parse("10pm to 1am") == r(22, to: 25))
    }

    @Test func leavesOtherBulletsAlone() {
        #expect(TimeRange.parse("Go running") == nil)
        #expect(TimeRange.parse("Call mom 9 to 11") == nil)
        #expect(TimeRange.parse("9") == nil)
        #expect(TimeRange.parse("2-3 people") == nil)
        #expect(TimeRange.parse("") == nil)
    }

    @Test func writesTheShortestTextThatReadsBack() {
        #expect(r(9, to: 11).text == "9–11")
        #expect(r(11, to: 13).text == "11–1")
        #expect(r(9, 30, to: 11).text == "9:30–11")
        #expect(r(19, to: 21).text == "7–9pm")
        #expect(r(18, to: 20).text == "6–8")
        for range in [r(9, to: 11), r(13, to: 15), r(19, to: 21), r(22, to: 25), r(6, to: 8), r(0, 30, to: 2)] {
            #expect(TimeRange.parse(range.text) == range, "\(range.text)")
        }
    }

    @MainActor
    @Test func editsMoveEveryLaterTimeRow() {
        let a = Block.bullet(text: AttributedString("9 to 11"))
        let b = Block.bullet(text: AttributedString("11 to one"))
        let task = Block.bullet(text: AttributedString("Go running"))
        let c = Block.bullet(text: AttributedString("1-3"))
        let document = Document(id: DocumentID("day"), children: [a, b, task, c])

        let longer = TimeRows.plan(.end(12 * 60), on: a.id, in: document)
        #expect(longer == [a.id: r(9, to: 12), b.id: r(12, to: 14), c.id: r(14, to: 16)])

        let earlier = TimeRows.plan(.start(8 * 60), on: a.id, in: document)
        #expect(earlier == [a.id: r(8, to: 11)])

        let last = TimeRows.plan(.end(16 * 60), on: c.id, in: document)
        #expect(last == [c.id: r(13, to: 16)])
    }

    @MainActor
    @Test func turnsBlocksIntoTimeRows() throws {
        let morning = Block.bullet(text: AttributedString("9 to 11"))
        let task = Block.paragraph(text: AttributedString("Go running"))
        let spelled = Block.paragraph(text: AttributedString("noon until 2"))
        let document = Document(id: DocumentID("day"), children: [morning, task, spelled])

        let afterMorning = try #require(TimeRows.turnInto(task, in: document))
        #expect(afterMorning.id == task.id)
        #expect(TimeRows.range(of: afterMorning) == r(11, to: 12))
        #expect(afterMorning.children.map(\.text) == [AttributedString("Go running")])

        let already = try #require(TimeRows.turnInto(spelled, in: document))
        #expect(TimeRows.range(of: already) == r(12, to: 14))
        #expect(already.children.isEmpty)
    }

    @MainActor
    @Test func markerRecognizesWholeTimeRanges() {
        let marker = EditorBulletMarker.timeRows
        #expect(marker.recognizes("9 to 11"))
        #expect(!marker.recognizes("9 to 11 standup"))
    }
}
