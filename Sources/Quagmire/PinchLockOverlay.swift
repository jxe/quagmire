import SwiftUI

// MARK: - Pinch lock (iOS)

/// A text caret in an empty provisional row, standing in for the keyboard a
/// typing pinch will open. Steady while the slide approaches, blinking once
/// typing is armed.
struct ProvisionalCaret: View {
    let blinks: Bool
    /// Blinking starts on the visible beat, so arming never reads as the
    /// caret vanishing.
    @State private var blinkStart = Date.now

    var body: some View {
        TimelineView(.periodic(from: blinkStart, by: 0.5)) { context in
            let beat = Int(context.date.timeIntervalSince(blinkStart) * 2)
            let visible = !blinks || beat % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: 2)
                .padding(.vertical, 2)
                .opacity(visible ? 1 : 0)
        }
        .onChange(of: blinks) { blinkStart = .now }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

/// A bar on the screen edge beside the pinch's draft row, on the side an
/// open pinch is sliding toward: faint and thin as the slide begins, growing
/// brighter, then snapping thick and full-colour, with no in-between, once
/// that side arms. Leading is typing, in the accent colour of the caret it
/// brings; trailing is the lock, red like the recording it keeps going.
struct PinchEdgeGlow: View {
    let typeProgress: CGFloat
    let typeArmed: Bool
    let lockProgress: CGFloat
    let lockArmed: Bool

    var body: some View {
        HStack(spacing: 0) {
            bar(progress: typeProgress, armed: typeArmed, color: .accentColor, leading: true)
            Spacer(minLength: 0)
            bar(progress: lockProgress, armed: lockArmed, color: .red, leading: false)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func bar(progress: CGFloat, armed: Bool, color: Color, leading: Bool) -> some View {
        let eased = 1 - (1 - progress) * (1 - progress)
        // Visible width; the capsule is twice this, half past the edge, so
        // only its rounded inner side shows.
        let width: CGFloat = armed ? 7 : 3
        return Capsule()
            .fill(color)
            .background {
                Capsule().fill(color).blur(radius: 8).opacity(armed ? 0.8 : 0)
            }
            .saturation(armed ? 1 : 0.4)
            .opacity(armed ? 1 : 0.7 * eased)
            .frame(width: width * 2)
            .offset(x: leading ? -width : width)
            // Arming is a step, not a tween.
            .transaction { $0.animation = nil }
    }
}

/// Elapsed time beside the draft row, from the moment the recorder starts
/// until the insert commits. It floats by the lock's red edge bar with no
/// background of its own; a halo in the page's colour keeps it legible over
/// whatever is behind it.
struct PinchRecordingIndicator: View {
    let since: Date
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let halo: Color = colorScheme == .dark ? .black : .white
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .shadow(color: halo, radius: 1)
            .shadow(color: halo, radius: 3)
            .shadow(color: halo.opacity(0.6), radius: 6)
            .padding(.trailing, 6)
            .transition(.opacity)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Shown while a pinch is locked. The floating toggles turn the result into
/// a heading or an indented bullet; they appear as soon as the lock arms.
/// Once the fingers lift (`isHeld`), the lock becomes a stop button between
/// them and the editor is covered: a tap on the stop button or anywhere else
/// finishes the insert.
struct PinchLockOverlay: View {
    let isHeld: Bool
    let style: PinchInsertStyle
    let onToggle: (PinchInsertStyle) -> Void
    let onFinish: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if isHeld {
                captureLayer
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    toggle("Heading", systemImage: "textformat.size", style: .heading)
                    if isHeld {
                        stopButton
                    }
                    toggle("Indent", systemImage: "increase.indent", style: .indentedBullet)
                }
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity)
    }

    private var captureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        if PinchLockZone.isTap(value.translation) { onFinish() }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Recording")
            .accessibilityAction(named: "Finish", onFinish)
    }

    private var stopButton: some View {
        Button(action: onFinish) {
            Image(systemName: "stop.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.red).interactive(), in: Circle())
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .accessibilityLabel("Stop recording")
    }

    private func toggle(_ title: String, systemImage: String, style option: PinchInsertStyle) -> some View {
        let isOn = style == option
        return Button {
            onToggle(option)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 22)
                .frame(minHeight: 52)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
