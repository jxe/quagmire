import SwiftUI

/// A symbol that stands in for the dot of the bullets it recognizes. Tapping
/// the symbol opens the marker's popover, and the marker may offer a Turn
/// Into entry. Recognition reads the bullet's text alone, so the stored block
/// stays an ordinary bullet and hosts without the marker show a plain dot.
///
/// Markers are main-actor values because they build SwiftUI content and read
/// the live `Document`. They never mutate it directly: popovers propose
/// replacements through their context, and Turn Into returns a replacement
/// block, which the editor applies as one undo step.
@MainActor
public struct EditorBulletMarker: Identifiable {
    public let id: String
    /// The Turn Into title, and the spoken name of the marker.
    public let title: String
    public let systemImage: String
    public let turnIntoShortcut: KeyEquivalent?

    private let recognizer: @MainActor (String) -> Bool
    private let popoverContent: @MainActor (EditorBulletMarkerContext) -> AnyView
    private let turnIntoHandler: (@MainActor (Block, Document) -> Block?)?

    /// - Parameters:
    ///   - recognizes: Whether a bullet with this text gets the marker.
    ///   - turnInto: The replacement for a text-bearing block turned into
    ///     this marker's bullets, keeping the block's ID. Nil leaves the
    ///     marker out of Turn Into, or skips that block.
    ///   - popover: The content shown when the marker is tapped.
    public init<Content: View>(
        id: String,
        title: String,
        systemImage: String,
        turnIntoShortcut: KeyEquivalent? = nil,
        recognizes: @escaping @MainActor (String) -> Bool,
        turnInto: (@MainActor (Block, Document) -> Block?)? = nil,
        @ViewBuilder popover: @escaping @MainActor (EditorBulletMarkerContext) -> Content
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.turnIntoShortcut = turnIntoShortcut
        self.recognizer = recognizes
        self.turnIntoHandler = turnInto
        self.popoverContent = { AnyView(popover($0)) }
    }

    public func recognizes(_ text: String) -> Bool {
        recognizer(text)
    }

    var offersTurnInto: Bool { turnIntoHandler != nil }

    func turnInto(_ block: Block, in document: Document) -> Block? {
        turnIntoHandler?(block, document)
    }

    func popover(in context: EditorBulletMarkerContext) -> AnyView {
        popoverContent(context)
    }
}

/// What a marker's popover is given: the bullet it was opened from, the live
/// document to read, and the way back into the editor.
@MainActor
public struct EditorBulletMarkerContext {
    public let block: Block
    public let document: Document

    private let replace: @MainActor ([BlockReplacement], String) -> Void
    private let feedback: @MainActor () -> Void

    init(
        block: Block,
        document: Document,
        replace: @escaping @MainActor ([BlockReplacement], String) -> Void,
        feedback: @escaping @MainActor () -> Void
    ) {
        self.block = block
        self.document = document
        self.replace = replace
        self.feedback = feedback
    }

    /// Applies every replacement as one undo step named `actionName`.
    /// Replacements for blocks no longer in the document are skipped.
    public func apply(_ replacements: [BlockReplacement], actionName: String) {
        replace(replacements, actionName)
    }

    /// A selection tick, when the host enables haptic feedback.
    public func selectionFeedback() {
        feedback()
    }
}

public extension EditorView {
    /// Markers for bullets this editor recognizes. The first marker that
    /// recognizes a bullet's text draws it; IDs must be unique.
    func bulletMarkers(_ markers: [EditorBulletMarker]) -> Self {
        var copy = self
        copy.editorBulletMarkers = markers
        return copy
    }
}

extension EditorView {
    func bulletMarker(for block: Block) -> EditorBulletMarker? {
        guard case .bullet(let text) = block.kind, !editorBulletMarkers.isEmpty else { return nil }
        let string = String(text.characters)
        return editorBulletMarkers.first { $0.recognizes(string) }
    }

    func bulletMarkerContext(for block: Block) -> EditorBulletMarkerContext {
        EditorBulletMarkerContext(
            block: block,
            document: document,
            replace: { replacements, actionName in
                let current = replacements.filter { document.find($0.blockID) != nil }
                guard !current.isEmpty else { return }
                mutate(actionName) {
                    for replacement in current {
                        document.mutate(replacement.blockID) { $0.kind = replacement.kind }
                    }
                }
            },
            feedback: { Haptics.selection(enabled: configuration.isHapticFeedbackEnabled) }
        )
    }

    /// Opens `blockID`'s marker popover, as a tap on its marker does.
    func openBulletMarkerPopover(_ blockID: BlockID) {
        guard !readOnly else { return }
        transferFocus(to: .nav(cursor: blockID))
        bulletMarkerPopoverBlockID = blockID
    }
}
