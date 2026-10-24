import Foundation
import Quagmire

/// A stretch of the day written as a bullet's whole text: "9 to 11",
/// "11 to one", "1-3", "9:30–11am", "noon until 2". A bullet that reads as
/// one is drawn as a time row: a clock in place of the bullet that opens the
/// time editor. The Markdown stays a plain bullet; edits rewrite its text.
///
/// Times are minutes since midnight. `end` may run past midnight (up to a
/// day after `start`) so "10pm to 1am" holds together.
struct TimeRange: Equatable, Hashable, Sendable {
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    var duration: Int { end - start }

    func shifted(by minutes: Int) -> TimeRange {
        TimeRange(start: start + minutes, end: end + minutes)
    }

    // MARK: Parsing

    /// The range a bullet's text spells, or nil when the text is anything
    /// more than a time range.
    static func parse(_ text: String) -> TimeRange? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Dictation tends to end a phrase with punctuation.
        while let last = s.last, ":.,;".contains(last) { s.removeLast() }
        if s.hasPrefix("from ") { s.removeFirst(5) }
        guard s.count <= 32,
              let match = s.firstMatch(of: rangePattern),
              let start = ClockReading(String(match.output.1)),
              let end = ClockReading(String(match.output.2)) else { return nil }
        return resolve(start: start, end: end)
    }

    nonisolated(unsafe) private static let rangePattern =
        /^(.+?)\s*(?:–|—|-|\bto\b|\buntil\b|\btill\b|\btil\b)\s*(.+)$/

    /// Picks am/pm for whichever ends left it out. A bare start hour reads
    /// the way a day plan means it (7–11 morning, 12–6 afternoon); a bare
    /// end is the first matching time after the start.
    private static func resolve(start: ClockReading, end: ClockReading) -> TimeRange? {
        let startMinutes: Int
        if let fixed = start.fixedMinutes {
            startMinutes = fixed
        } else if let endFixed = end.fixedMinutes {
            // "8 to 10pm": the latest reading of the start before the end.
            let candidates = start.candidates.filter { $0 < endFixed }
            startMinutes = candidates.max() ?? start.dayPlanMinutes
        } else {
            startMinutes = start.dayPlanMinutes
        }
        var endMinutes: Int
        if let fixed = end.fixedMinutes {
            endMinutes = fixed
        } else {
            endMinutes = end.candidates.first { $0 > startMinutes } ?? (end.candidates[0] + 24 * 60)
        }
        if endMinutes <= startMinutes { endMinutes += 24 * 60 }
        guard endMinutes - startMinutes < 24 * 60 else { return nil }
        return TimeRange(start: startMinutes, end: endMinutes)
    }

    // MARK: Formatting

    /// The shortest text that parses back to this range: "9–11", "9:30–11",
    /// with "am"/"pm" added only where the day-plan reading would be wrong.
    var text: String {
        let s = Self.normalized(start), e = Self.normalized(end)
        let options = [
            "\(Self.clock(s))–\(Self.clock(e))",
            "\(Self.clock(s))–\(Self.clock(e, meridiem: true))",
            "\(Self.clock(s, meridiem: true))–\(Self.clock(e, meridiem: true))",
        ]
        let target = TimeRange(start: s, end: s + duration)
        return options.first { Self.parse($0) == target } ?? options[2]
    }

    /// One end on its own, for the editor: "9:30 AM".
    static func displayClock(_ minutes: Int) -> String {
        let m = normalized(minutes)
        let hour24 = m / 60
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        let minute = m % 60
        let suffix = hour24 < 12 ? "AM" : "PM"
        return minute == 0 ? "\(hour) \(suffix)" : String(format: "%d:%02d %@", hour, minute, suffix)
    }

    static func normalized(_ minutes: Int) -> Int {
        ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
    }

    private static func clock(_ minutes: Int, meridiem: Bool = false) -> String {
        let m = normalized(minutes)
        let hour24 = m / 60
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        let minute = m % 60
        var out = minute == 0 ? "\(hour)" : String(format: "%d:%02d", hour, minute)
        if meridiem { out += hour24 < 12 ? "am" : "pm" }
        return out
    }
}

/// One end of a spoken or typed range, before am/pm is settled.
private struct ClockReading {
    /// 0–23 when written as 24-hour or with am/pm; otherwise 1–12.
    var hour: Int
    var minute: Int
    /// nil when the text left it to context.
    var isPM: Bool?
    /// 13–23 or 0 written out: already a 24-hour time.
    var is24Hour: Bool

    private static let words: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    nonisolated(unsafe) private static let digitPattern =
        /^(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.?|p\.m\.?|a|p)?$/

    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        switch s {
        case "noon", "midday":
            self.init(hour: 12, minute: 0, isPM: true, is24Hour: false)
            return
        case "midnight":
            self.init(hour: 12, minute: 0, isPM: false, is24Hour: false)
            return
        default: break
        }
        // "one", "eleven pm", "two thirty" is left out on purpose: it would
        // need a whole number parser for little gain.
        let parts = s.split(separator: " ").map(String.init)
        if let first = parts.first, let hour = Self.words[first], parts.count <= 2 {
            var isPM: Bool?
            if parts.count == 2 {
                switch parts[1] {
                case "am", "a.m.", "a.m": isPM = false
                case "pm", "p.m.", "p.m": isPM = true
                default: return nil
                }
            }
            self.init(hour: hour, minute: 0, isPM: isPM, is24Hour: false)
            return
        }
        guard let match = s.wholeMatch(of: Self.digitPattern),
              let hour = Int(match.output.1) else { return nil }
        let minute = match.output.2.flatMap { Int($0) } ?? 0
        guard minute < 60 else { return nil }
        var isPM: Bool?
        if let meridiem = match.output.3 { isPM = meridiem.hasPrefix("p") }
        if isPM != nil {
            guard (1...12).contains(hour) else { return nil }
            self.init(hour: hour, minute: minute, isPM: isPM, is24Hour: false)
        } else if hour == 0 || (13...23).contains(hour) {
            self.init(hour: hour, minute: minute, isPM: nil, is24Hour: true)
        } else {
            guard (1...12).contains(hour) else { return nil }
            self.init(hour: hour, minute: minute, isPM: nil, is24Hour: false)
        }
    }

    private init(hour: Int, minute: Int, isPM: Bool?, is24Hour: Bool) {
        self.hour = hour
        self.minute = minute
        self.isPM = isPM
        self.is24Hour = is24Hour
    }

    private func minutes(pm: Bool) -> Int {
        let base = hour % 12 + (pm ? 12 : 0)
        return base * 60 + minute
    }

    var fixedMinutes: Int? {
        if is24Hour { return hour * 60 + minute }
        if let isPM { return minutes(pm: isPM) }
        return nil
    }

    /// Morning then afternoon reading of a bare hour.
    var candidates: [Int] {
        if let fixed = fixedMinutes { return [fixed] }
        return [minutes(pm: false), minutes(pm: true)]
    }

    /// 7–11 in the morning; 12 and 1–6 in the afternoon.
    var dayPlanMinutes: Int {
        minutes(pm: hour == 12 || hour <= 6)
    }
}

/// Time rows that sit beside each other under one parent, and the text
/// edits one change to them makes.
@MainActor
enum TimeRows {
    static func range(of block: Block) -> TimeRange? {
        guard case .bullet(let text) = block.kind else { return nil }
        return TimeRange.parse(String(text.characters))
    }

    /// The time-row siblings of `blockID`, in order, with the index of
    /// `blockID` among them.
    static func siblings(of blockID: BlockID, in document: Document) -> (rows: [(id: BlockID, range: TimeRange)], index: Int)? {
        let siblings: [Block]
        if let parent = document.parent(of: blockID) {
            guard let parentBlock = document.find(parent) else { return nil }
            siblings = parentBlock.children
        } else {
            siblings = document.children
        }
        let rows = siblings.compactMap { block in range(of: block).map { (id: block.id, range: $0) } }
        guard let index = rows.firstIndex(where: { $0.id == blockID }) else { return nil }
        return (rows, index)
    }

    enum Edit {
        case start(Int)
        case end(Int)
    }

    /// The new range for every row the edit touches: the edited row, and
    /// every later row shifted by however far its end moved.
    static func plan(_ edit: Edit, on blockID: BlockID, in document: Document) -> [BlockID: TimeRange] {
        guard let (rows, index) = siblings(of: blockID, in: document) else { return [:] }
        let old = rows[index].range
        var updated = old
        switch edit {
        case .start(let minutes):
            updated.start = minutes
            if updated.end <= updated.start { updated.end = updated.start + max(old.duration, 15) }
        case .end(let minutes):
            updated.end = minutes
            if updated.end <= updated.start { updated.end = updated.start + 15 }
        }
        var out: [BlockID: TimeRange] = [rows[index].id: updated]
        let delta = updated.end - old.end
        if delta != 0 {
            for row in rows[(index + 1)...] {
                out[row.id] = row.range.shifted(by: delta)
            }
        }
        return out
    }
}
