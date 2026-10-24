import SwiftUI

/// The popover a time row's clock opens: its start and end, each nudged by
/// − and + or scrubbed by dragging across it. Moving the end moves every
/// later time row by the same amount.
struct TimeRowEditor: View {
    let range: TimeRange
    let feedback: () -> Void
    let onEdit: (TimeRows.Edit) -> Void

    var body: some View {
        HStack(spacing: 20) {
            TimeRowClockField(
                label: "Start",
                minutes: range.start,
                feedback: feedback,
                onChange: { onEdit(.start($0)) }
            )
            TimeRowClockField(
                label: "End",
                minutes: range.end,
                feedback: feedback,
                onChange: { onEdit(.end($0)) }
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .presentationCompactAdaptation(.popover)
    }
}

/// One end of the range: a small label over the time, with − and + beside
/// it. Dragging sideways across the time scrubs it a step per few points,
/// with a tick at each step, and writes once on release.
private struct TimeRowClockField: View {
    let label: String
    let minutes: Int
    let feedback: () -> Void
    let onChange: (Int) -> Void

    @State private var scrubOffset: Int?

    private static let step = 15
    private static let pointsPerStep: CGFloat = 14

    private var shown: Int { minutes + (scrubOffset ?? 0) }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                nudge("minus.circle", by: -Self.step)
                Text(TimeRange.displayClock(shown))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .frame(minWidth: 84, minHeight: 32)
                    .contentShape(Rectangle())
                    .gesture(scrub)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onChange(minutes + Self.step)
                        case .decrement: onChange(minutes - Self.step)
                        @unknown default: break
                        }
                    }
                nudge("plus.circle", by: Self.step)
            }
        }
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let steps = Int((value.translation.width / Self.pointsPerStep).rounded(.towardZero))
                let offset = steps * Self.step
                if offset != scrubOffset {
                    feedback()
                    withAnimation(.snappy(duration: 0.12)) { scrubOffset = offset }
                }
            }
            .onEnded { _ in
                if let offset = scrubOffset, offset != 0 { onChange(minutes + offset) }
                scrubOffset = nil
            }
    }

    private func nudge(_ symbol: String, by delta: Int) -> some View {
        Button {
            feedback()
            onChange(minutes + delta)
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(delta < 0 ? "Earlier" : "Later")
    }
}
