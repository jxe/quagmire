import Foundation

/// Blocks the host shows with a document but that are not part of it: never
/// saved, never edited, and absent from transactions and undo. The editor
/// draws a region's rows like any others under a heading row of its own, so
/// they can be selected, found, opened, copied, and dragged into the page,
/// which inserts a copy. The host receives blocks dropped on a region through
/// `EditorHost.receiveBlocks(_:inRegion:of:)`.
///
/// Region block IDs must not collide with the document's; a region block
/// whose ID the document also holds is left out of the region.
public struct DocumentRegion: Identifiable, Equatable, Sendable {
    /// Where the region stands relative to the document's own blocks.
    public enum Anchor: Hashable, Sendable {
        /// After every block of the document.
        case end
    }

    /// The region's heading row.
    public var id: BlockID
    public var anchor: Anchor
    public var title: AttributedString
    public var headingLevel: HeadingLevel
    public var blocks: [Block]

    public init(id: BlockID, anchor: Anchor = .end, title: AttributedString, headingLevel: HeadingLevel = .h1, blocks: [Block]) {
        self.id = id
        self.anchor = anchor
        self.title = title
        self.headingLevel = headingLevel
        self.blocks = blocks
    }
}
