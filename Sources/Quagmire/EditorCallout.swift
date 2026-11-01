import SwiftUI

/// A quote the host recognizes as something more, such as an agent task:
/// drawn as a tinted callout with the callout's symbol in place of the quote
/// bar, and a host view at its trailing edge (a Run button). The stored block
/// stays a quote, so hosts without the callout show an ordinary quote. Like
/// `EditorBulletMarker`, a callout may offer a Turn Into entry that returns
/// the replacement block, applied as one undo step.
@MainActor
public struct EditorCallout: Identifiable {
    public let id: String
    /// The Turn Into title, and the spoken name of the callout.
    public let title: String
    public let systemImage: String
    public let tint: Color
    public let turnIntoShortcut: KeyEquivalent?
    /// Typed at the start of a paragraph (`"! "`), turns it into this callout,
    /// like the built-in Markdown shortcuts.
    public let trigger: String?

    private let recognizer: @MainActor (Block) -> Bool
    private let turnIntoHandler: (@MainActor (Block) -> Block?)?
    private let trailingContent: @MainActor (Block) -> AnyView

    /// - Parameters:
    ///   - recognizes: Whether a quote block is drawn as this callout.
    ///   - turnInto: The replacement for a block turned into this callout,
    ///     keeping its ID. Nil leaves the callout out of Turn Into.
    ///   - trailing: Host controls drawn at the callout's trailing edge.
    public init<Trailing: View>(
        id: String,
        title: String,
        systemImage: String,
        tint: Color,
        turnIntoShortcut: KeyEquivalent? = nil,
        trigger: String? = nil,
        recognizes: @escaping @MainActor (Block) -> Bool,
        turnInto: (@MainActor (Block) -> Block?)? = nil,
        @ViewBuilder trailing: @escaping @MainActor (Block) -> Trailing
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.turnIntoShortcut = turnIntoShortcut
        self.trigger = trigger
        self.recognizer = recognizes
        self.turnIntoHandler = turnInto
        self.trailingContent = { AnyView(trailing($0)) }
    }

    public func recognizes(_ block: Block) -> Bool {
        guard case .quote = block.kind else { return false }
        return recognizer(block)
    }

    var offersTurnInto: Bool { turnIntoHandler != nil }

    func turnInto(_ block: Block) -> Block? { turnIntoHandler?(block) }

    func trailing(for block: Block) -> AnyView { trailingContent(block) }
}

public extension EditorView {
    /// Callouts for quotes this editor recognizes. The first callout that
    /// recognizes a quote draws it; IDs must be unique.
    func callouts(_ values: [EditorCallout]) -> Self {
        var copy = self
        copy.editorCallouts = values
        return copy
    }
}

extension EditorView {
    func callout(for block: Block) -> EditorCallout? {
        guard case .quote = block.kind, !editorCallouts.isEmpty else { return nil }
        return editorCallouts.first { $0.recognizes(block) }
    }

    /// Turns each block into the callout in one undo step. Blocks the
    /// callout declines are left alone.
    @discardableResult
    func convert(blockIDs: [BlockID], to callout: EditorCallout) -> KeyPress.Result {
        let replacements = blockIDs.compactMap { id -> Block? in
            guard let block = document.find(id), textForBlockTypeChange(block) != nil,
                  let replacement = callout.turnInto(block), replacement.id == id else { return nil }
            return replacement
        }
        guard !replacements.isEmpty else { return .ignored }
        mutate("Turn Into") {
            for replacement in replacements {
                document.replaceSubtree(replacement.id, with: [replacement])
            }
        }
        for replacement in replacements {
            state.expandedToggles.remove(replacement.id)
            state.expandedTemplates.remove(replacement.id)
        }
        return .handled
    }
}
