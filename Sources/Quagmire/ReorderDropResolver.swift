import CoreGraphics

struct ReorderDropFrame: Equatable {
    var frame: CGRect
}

enum ReorderDropResolver {
    /// Picks a row-shaped drop target before the insertion-slot resolver opens
    /// a drift gap. The acquisition padding makes thin rows approachable from
    /// their surrounding whitespace; the larger retention padding keeps an
    /// acquired target from escaping when nearby layout animates.
    static func rowTargetIndex(
        forY y: CGFloat,
        rowFrames: [ReorderDropFrame],
        previousIndex: Int? = nil,
        acquisitionPadding: CGFloat = 6,
        retentionPadding: CGFloat = 12
    ) -> Int? {
        if let previousIndex, rowFrames.indices.contains(previousIndex) {
            let retained = rowFrames[previousIndex].frame.insetBy(dx: 0, dy: -retentionPadding)
            if y >= retained.minY, y <= retained.maxY { return previousIndex }
        }

        return rowFrames.indices
            .filter { index in
                let acquired = rowFrames[index].frame.insetBy(dx: 0, dy: -acquisitionPadding)
                return y >= acquired.minY && y <= acquired.maxY
            }
            .min { lhs, rhs in
                abs(rowFrames[lhs].frame.midY - y) < abs(rowFrames[rhs].frame.midY - y)
            }
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
