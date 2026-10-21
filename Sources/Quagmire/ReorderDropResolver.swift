import CoreGraphics

struct ReorderDropFrame: Equatable {
    var frame: CGRect
}

enum ReorderDropResolver {
    /// Picks a row-shaped drop target (a document link) where the finger is
    /// over it as drawn. The middle of a row acquires it; its top and bottom
    /// edge bands stay insertion points beside it. Once acquired, the whole
    /// row (plus `retentionPadding`) keeps it, so nearby layout that animates
    /// does not drop the target.
    static func rowTargetIndex(
        forY y: CGFloat,
        rowFrames: [ReorderDropFrame],
        previousIndex: Int? = nil,
        edgeFraction: CGFloat = 0.25,
        retentionPadding: CGFloat = 0
    ) -> Int? {
        if let previousIndex, rowFrames.indices.contains(previousIndex) {
            let retained = rowFrames[previousIndex].frame.insetBy(dx: 0, dy: -retentionPadding)
            if y >= retained.minY, y <= retained.maxY { return previousIndex }
        }

        return rowFrames.indices
            .filter { index in
                let frame = rowFrames[index].frame
                let band = frame.height * edgeFraction
                return y > frame.minY + band && y < frame.maxY - band
            }
            .min { lhs, rhs in
                abs(rowFrames[lhs].frame.midY - y) < abs(rowFrames[rhs].frame.midY - y)
            }
    }

    /// The insertion slot once document-link rows hold it. The slot follows
    /// the lift's top edge, which crosses a link row's midline about when the
    /// finger reaches the row; moving the gap past it then would slide the
    /// row out from under the finger. So the gap passes a link row only once
    /// the finger reaches that row's far edge band, as drawn now
    /// (`linkFrames`, keyed by visible row index, under `current`).
    static func slotHeldByLinks(
        _ candidate: Int,
        current: Int?,
        pointerY y: CGFloat,
        linkFrames: [(index: Int, frame: CGRect)],
        edgeFraction: CGFloat = 0.25
    ) -> Int {
        guard let current, candidate != current else { return candidate }
        if candidate > current {
            for link in linkFrames.sorted(by: { $0.index < $1.index })
            where link.index >= current && link.index < candidate {
                if y < link.frame.maxY - link.frame.height * edgeFraction { return link.index }
            }
        } else {
            for link in linkFrames.sorted(by: { $0.index > $1.index })
            where link.index >= candidate && link.index < current {
                if y > link.frame.minY + link.frame.height * edgeFraction { return link.index + 1 }
            }
        }
        return candidate
    }

    static func insertionIndex(
        forY y: CGFloat,
        rowFrames: [ReorderDropFrame],
        previousIndex: Int? = nil,
        hysteresis: CGFloat = 10
    ) -> Int {
        guard !rowFrames.isEmpty else { return 0 }

        let sortedFrames = rowFrames.sorted {
            if $0.frame.midY == $1.frame.midY {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.midY < $1.frame.midY
        }
        let rawIndex = sortedFrames.reduce(0) { count, row in
            y > row.frame.midY ? count + 1 : count
        }

        guard let previousIndex else { return rawIndex }
        let clampedPrevious = max(0, min(previousIndex, sortedFrames.count))
        guard rawIndex != clampedPrevious else { return rawIndex }
        guard abs(rawIndex - clampedPrevious) == 1 else { return rawIndex }

        if rawIndex > clampedPrevious {
            let boundary = sortedFrames[clampedPrevious].frame.midY
            return y > boundary + hysteresis ? rawIndex : clampedPrevious
        } else {
            let boundary = sortedFrames[rawIndex].frame.midY
            return y < boundary - hysteresis ? rawIndex : clampedPrevious
        }
    }

    static func reorderInsertionIndex(
        forY y: CGFloat,
        rowFrames: [ReorderDropFrame],
        sourceRange: ClosedRange<Int>?,
        previousIndex: Int? = nil,
        hysteresis: CGFloat = 10
    ) -> Int {
        let index = insertionIndex(
            forY: y,
            rowFrames: rowFrames,
            previousIndex: previousIndex,
            hysteresis: hysteresis
        )
        guard let sourceRange, !rowFrames.isEmpty else { return index }

        let sortedFrames = rowFrames.sorted {
            if $0.frame.midY == $1.frame.midY {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.midY < $1.frame.midY
        }
        guard sourceRange.lowerBound >= 0,
              sourceRange.upperBound < sortedFrames.count
        else { return index }

        let firstSourceFrame = sortedFrames[sourceRange.lowerBound].frame
        if sourceRange.lowerBound > 0,
           index == sourceRange.lowerBound,
           y < firstSourceFrame.minY {
            return sourceRange.lowerBound - 1
        }

        let afterSourceIndex = sourceRange.upperBound + 1
        let lastSourceFrame = sortedFrames[sourceRange.upperBound].frame
        if afterSourceIndex < sortedFrames.count,
           index == afterSourceIndex,
           y > lastSourceFrame.maxY {
            return afterSourceIndex + 1
        }

        return index
    }
}
