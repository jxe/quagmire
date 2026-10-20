import SwiftUI

// MARK: - Pinch lock (iOS)

/// A text caret in an empty provisional row, standing in for the keyboard a
/// typing pinch will open, and the slide's only cue on that side. Steady
/// while the slide approaches; once typing arms it pops big, overshooting,
/// and stays big and blinking until the pinch lets go (`PinchLandingCaret`
/// then shrinks it into the real caret) or slides back.
struct ProvisionalCaret: View {
    let blinks: Bool
    /// Blinking starts on the visible beat, so arming never reads as the
    /// caret vanishing.
    @State private var blinkStart = Date.now

    var body: some View {
        TimelineView(.periodic(from: blinkStart, by: 0.5)) { context in
            let beat = Int(context.date.timeIntervalSince(blinkStart) * 2)
            let visible = !blinks || beat % 2 == 0
            PinchCaretShape()
                .opacity(visible ? 1 : 0)
        }
        .scaleEffect(
            x: blinks ? PinchCaretShape.armedWidthScale : 1,
            y: blinks ? PinchCaretShape.armedHeightScale : 1
        )
        .shadow(color: Color.accentColor.opacity(blinks ? 0.6 : 0), radius: 8)
        // Underdamped, so arming overshoots: the pop.
        .animation(.spring(response: 0.3, dampingFraction: 0.42), value: blinks)
        .onChange(of: blinks) { blinkStart = .now }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

/// The armed caret again, over the new row's editor once a typing pinch
/// lets go, shrinking into the real caret while the keyboard rises.
struct PinchLandingCaret: View {
    @State private var landed = false

    var body: some View {
        PinchCaretShape()
            .scaleEffect(
                x: landed ? 1 : PinchCaretShape.armedWidthScale,
                y: landed ? 1 : PinchCaretShape.armedHeightScale
            )
            .shadow(color: Color.accentColor.opacity(landed ? 0 : 0.6), radius: 8)
            .opacity(landed ? 0 : 1)
            .onAppear {
                // About the keyboard's own rise.
                withAnimation(.easeInOut(duration: 0.35)) { landed = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PinchCaretShape: View {
    static let armedWidthScale: CGFloat = 5
    static let armedHeightScale: CGFloat = 2.2

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2)
            .padding(.vertical, 2)
    }
}

/// A red bar on the trailing screen edge beside the pinch's draft row as an
/// open pinch slides toward the lock: faint and thin as the slide begins,
/// growing brighter, then snapping thick and full-colour, with no
/// in-between, once the lock arms. (Sliding the other way, toward typing,
/// is cued by the draft row's caret instead.)
struct PinchEdgeGlow: View {
    let lockProgress: CGFloat
    let lockArmed: Bool

    var body: some View {
        HStack(spacing: 0) {
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
