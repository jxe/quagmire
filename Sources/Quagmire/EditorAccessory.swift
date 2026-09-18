import SwiftUI

/// A location within one editor session. Missing block anchors are never guessed.
public enum EditorAccessoryAnchor: Hashable, Sendable {
    case document
    case block(BlockID)
}

/// Host-owned presentation outside the document, its serialization and undo history.
/// Marker builders supply a label, not an interactive control; Quagmire supplies
/// the accessible disclosure button. Detail views may contain host controls.
@MainActor
public struct EditorAccessory: Identifiable {
    public let id: String
    public let anchor: EditorAccessoryAnchor
    public let accessibilityLabel: String
    public let isExpanded: Binding<Bool>
    let marker: AnyView
    let detail: AnyView

    public init<Marker: View, Detail: View>(
        id: String, anchor: EditorAccessoryAnchor, accessibilityLabel: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder marker: () -> Marker,
        @ViewBuilder detail: () -> Detail
    ) {
        self.id = id; self.anchor = anchor; self.accessibilityLabel = accessibilityLabel
        self.isExpanded = isExpanded; self.marker = AnyView(marker()); self.detail = AnyView(detail())
    }
}

/// A new token permits revealing the same accessory again without changing focus.
public struct EditorAccessoryReveal: Equatable, Sendable {
    public let id: String
    public let token: UUID
    public init(_ id: String) { self.id = id; self.token = UUID() }
}

public extension EditorView {
    /// IDs must be unique within this editor. Expansion remains host-owned.
    func accessories(_ values: [EditorAccessory], reveal: EditorAccessoryReveal? = nil,
                     onUnavailable: @escaping ([String]) -> Void = { _ in }) -> Self {
        var copy = self
        copy.editorAccessories = values
        copy.accessoryReveal = reveal
        copy.unavailableAccessories = onUnavailable
        return copy
    }
}

extension EditorView {
    var missingAccessoryIDs: [String] {
        let counts = Dictionary(grouping: editorAccessories, by: \.id)
        return Array(Set(editorAccessories.compactMap { accessory in
            if counts[accessory.id]?.count != 1 { return accessory.id }
            if case let .block(id) = accessory.anchor, document.find(id) == nil { return accessory.id }
            return nil
        })).sorted()
    }
    func accessories(at anchor: EditorAccessoryAnchor) -> [EditorAccessory] {
        // Duplicate host IDs fail closed instead of crashing SwiftUI's identity map.
        let counts = Dictionary(grouping: editorAccessories, by: \.id)
        return editorAccessories.filter { $0.anchor == anchor && counts[$0.id]?.count == 1 }
    }
    func accessoryMarkers(at anchor: EditorAccessoryAnchor) -> AnyView? {
        let values = accessories(at: anchor)
        guard !values.isEmpty else { return nil }
        return AnyView(VStack(spacing: 4) {
            ForEach(values) { accessory in
                Button { accessory.isExpanded.wrappedValue.toggle() } label: {
                    accessory.marker.frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessory.accessibilityLabel)
                .accessibilityValue(accessory.isExpanded.wrappedValue ? "Expanded" : "Collapsed")
                .help(accessory.accessibilityLabel)
            }
        })
    }
    func accessoryDetails(at anchor: EditorAccessoryAnchor) -> AnyView? {
        let values = accessories(at: anchor).filter { $0.isExpanded.wrappedValue }
        guard !values.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            ForEach(values) { accessory in
                accessory.detail
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessory.accessibilityLabel)
            }
        }.padding(.vertical, 8))
    }
    var documentAccessories: AnyView? {
        guard !accessories(at: .document).isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            HStack { accessoryMarkers(at: .document); Spacer() }
            accessoryDetails(at: .document)
        })
    }
    func revealAccessory() {
        guard let request = accessoryReveal,
              let accessory = editorAccessories.first(where: { $0.id == request.id }),
              !missingAccessoryIDs.contains(request.id) else { return }
        switch accessory.anchor {
        case .document:
            accessory.isExpanded.wrappedValue = true
            Task { @MainActor in
                await Task.yield()
#if os(macOS)
                scrollPosition.scrollTo(edge: .top)
#else
                PageScrollController.shared.scroll(toY: 0)
#endif
            }
        case let .block(id):
            guard document.find(id) != nil else { unavailableAccessories([accessory.id]); return }
            accessory.isExpanded.wrappedValue = true
            revealHiddenBlocks([id])
            scrollToFindMatch(id)
        }
    }
}
