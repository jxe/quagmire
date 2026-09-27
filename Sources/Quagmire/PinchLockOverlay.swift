import SwiftUI

// MARK: - Pinch lock (iOS)

/// Sits at the trailing edge of the pinch's draft row once the lock arms,
/// appearing together with the style buttons.
struct PinchLockBadge: View {
    let phase: PinchLockPhase

    var body: some View {
        if phase != .none {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: Circle())
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("Recording locked")
                .allowsHitTesting(false)
        }
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
