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
    private let doneTest: (@MainActor (Block) -> Bool)?
    private let toggleHandler: (@MainActor (Block) -> Block?)?
    private let turnIntoHandler: (@MainActor (Block) -> Block?)?
    private let trailingContent: @MainActor (Block) -> AnyView
    private let detailContent: (@MainActor (Block) -> AnyView?)?

    /// - Parameters:
    ///   - recognizes: Whether a quote block is drawn as this callout.
    ///   - turnInto: The replacement for a block turned into this callout,
    ///     keeping its ID. Nil leaves the callout out of Turn Into.
    ///   - isDone: Whether a callout block is done, drawn like a checked to-do.
    ///   - toggle: The block with its done state flipped, keeping its ID; its
    ///     symbol becomes a button for it, like a to-do's checkbox.
    ///   - trailing: Host controls drawn at the callout's trailing edge. Keep
    ///     them small: the text takes the rest of the width.
    ///   - detail: A host line under the callout's text, such as a result;
    ///     nil draws nothing.
    public init<Trailing: View>(
        id: String,
        title: String,
        systemImage: String,
        tint: Color,
        turnIntoShortcut: KeyEquivalent? = nil,
        trigger: String? = nil,
        recognizes: @escaping @MainActor (Block) -> Bool,
        turnInto: (@MainActor (Block) -> Block?)? = nil,
        isDone: (@MainActor (Block) -> Bool)? = nil,
        toggle: (@MainActor (Block) -> Block?)? = nil,
        detail: (@MainActor (Block) -> AnyView?)? = nil,
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
        self.doneTest = isDone
        self.toggleHandler = toggle
        self.trailingContent = { AnyView(trailing($0)) }
        self.detailContent = detail
    }

    public func recognizes(_ block: Block) -> Bool {
        guard case .quote = block.kind else { return false }
        return recognizer(block)
    }

    var offersTurnInto: Bool { turnIntoHandler != nil }

    func isDone(_ block: Block) -> Bool { doneTest?(block) ?? false }

    var toggles: Bool { toggleHandler != nil }

    func toggled(_ block: Block) -> Block? { toggleHandler?(block) }

    func turnInto(_ block: Block) -> Block? { turnIntoHandler?(block) }

    func trailing(for block: Block) -> AnyView { trailingContent(block) }

    func detail(for block: Block) -> AnyView? { detailContent?(block) }
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

    /// Flips a callout's done state through its `toggle`, as one undo step.
    func toggleCallout(_ id: BlockID) {
        guard let current = document.find(id), let callout = callout(for: current),
              let replacement = callout.toggled(current), replacement.id == id else { return }
        mutate(callout.isDone(current) ? "Mark Not Done" : "Mark Done") {
            document.replaceSubtree(id, with: [replacement])
        }
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
        }
        return .handled
    }
}
