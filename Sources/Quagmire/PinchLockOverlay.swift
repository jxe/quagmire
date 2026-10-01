import SwiftUI

// MARK: - Pinch lock (iOS)

/// Sits at the trailing edge of the pinch's draft row from the moment the
/// pinch can insert. Before arming it is a faint open lock whose ring fills
/// as the fingers slide toward it; on arming it becomes the solid lock,
/// together with the style buttons.
struct PinchLockBadge: View {
    let phase: PinchLockPhase
    /// Slide toward arming, 0…1; ignored once armed.
    let progress: CGFloat

    var body: some View {
        let isLocked = phase != .none
        Image(systemName: isLocked ? "lock.fill" : "lock.open")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isLocked ? Color.accentColor : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 34, height: 34)
            .glassEffect(.regular, in: Circle())
            .overlay {
                Circle()
                    .trim(from: 0, to: isLocked ? 1 : progress)
                    .stroke(
                        Color.accentColor.opacity(isLocked ? 0 : 0.85),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(1)
            }
            .opacity(isLocked ? 1 : 0.5 + 0.5 * progress)
            .scaleEffect(isLocked ? 1 : 0.88 + 0.08 * progress)
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: isLocked)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel(isLocked ? "Recording locked" : "Slide right to lock recording")
            .allowsHitTesting(false)
    }
}

/// Shown while a pinch is locked. The floating toggles turn the result into
/// a heading or an indented bullet; they appear as soon as the lock arms.
/// Once the fingers lift (`isHeld`), the editor is covered: a tap anywhere
/// finishes the insert and a horizontal swipe inserts a divider instead.
struct PinchLockOverlay: View {
    let isHeld: Bool
    let style: PinchInsertStyle
    let onToggle: (PinchInsertStyle) -> Void
    let onFinish: () -> Void
    let onDivider: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if isHeld {
                captureLayer
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    toggle("Heading", systemImage: "textformat.size", style: .heading)
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
                        switch PinchLockZone.release(for: value.translation) {
                        case .tap: onFinish()
                        case .swipe: onDivider()
                        case .none: break
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Recording")
            .accessibilityAction(named: "Finish", onFinish)
            .accessibilityAction(named: "Insert divider", onDivider)
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
