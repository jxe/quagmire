import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Blocks dragged out of one editor landing in another editor's document,
/// such as a page open in a second window. Handed to the destination's host
/// by `EditorHost.receiveBlocks(_:at:in:)`.
@MainActor
public struct EditorBlockTransfer {
    /// The subtrees as they will land, in document order. A move keeps the
    /// source's identities (unless the destination already uses one); a copy
    /// has fresh ones.
    public let blocks: [Block]
    /// The source's subtrees, prepared by the source host's
    /// `prepareBlocksForTransfer`, in the same shape as `blocks`.
    public let originals: [Block]
    /// The document the blocks are dragged from.
    public let source: Document
    /// The host of the editor the blocks are dragged from.
    public let sourceHost: any EditorHost
    /// Option was held: the source keeps its blocks.
    public let isCopy: Bool

    public init(blocks: [Block], originals: [Block], source: Document, sourceHost: any EditorHost, isCopy: Bool) {
        self.blocks = blocks
        self.originals = originals
        self.source = source
        self.sourceHost = sourceHost
        self.isCopy = isCopy
    }
}

/// A block drag that left its editor's window and became a system drag.
/// One drag runs at a time per process; the destination editor finds the
/// source here, so the pasteboard carries only a token.
@MainActor
final class ExternalBlockDrag {
    static var active: ExternalBlockDrag?

    let token = UUID().uuidString
    weak var document: Document?
    let host: any EditorHost
    /// The lifted ids, as an in-document move takes them.
    let ids: [BlockID]
    /// Prepared subtree roots in document order.
    let roots: [Block]
    /// Removes the roots from the source editor after a cross-document move
    /// has landed: an undoable edit there, like Move to Document.
    let finishMove: @MainActor () -> Void

    init(document: Document, host: any EditorHost, ids: [BlockID], roots: [Block], finishMove: @escaping @MainActor () -> Void) {
        self.document = document
        self.host = host
        self.ids = ids
        self.roots = roots
        self.finishMove = finishMove
    }
}

#if os(macOS)
@MainActor
enum MacExternalBlockDrag {
    static let identifier = "com.github.jxe.quagmire.block-drag"
    static let pasteboardType = NSPasteboard.PasteboardType(identifier)
    static let contentType = UTType(importedAs: identifier)

    /// A lift becomes a system drag once the pointer is over another of this
    /// app's windows, or over this window's tab bar. Outside every window it
    /// stays an in-window lift, so dragging past the window's edge still
    /// autoscrolls.
    static func shouldHandOff(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDragged, let window = event.window else { return false }
        let point = NSEvent.mouseLocation
        if window.frame.contains(point) {
            guard let tabs = window.tabbedWindows, tabs.count > 1 else { return false }
            return !window.contentLayoutRect.contains(window.convertPoint(fromScreen: point))
        }
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number != window.windowNumber,
              let other = NSApp.window(withWindowNumber: number) else { return false }
        return other.isVisible && !(other is NSPanel)
    }

    /// Start a system drag for `drag` from the mouse event that left the
    /// window. `image` is drawn under the pointer at `imageOffset`.
    static func begin(_ drag: ExternalBlockDrag, event: NSEvent, image: NSImage?, imageOffset: CGSize) -> Bool {
        guard let view = event.window?.contentView else { return false }
        let item = NSPasteboardItem()
        item.setString(drag.token, forType: pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = image ?? NSImage(size: CGSize(width: 1, height: 1))
        let point = view.convert(event.locationInWindow, from: nil)
        let origin = CGPoint(
            x: point.x - imageOffset.width,
            y: view.isFlipped ? point.y - imageOffset.height : point.y - (image.size.height - imageOffset.height)
        )
        draggingItem.setDraggingFrame(CGRect(origin: origin, size: image.size), contents: image)
        ExternalBlockDrag.active = drag
        let session = view.beginDraggingSession(with: [draggingItem], event: event, source: MacBlockDraggingSource.shared)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }
}

/// Offers blocks to this app's windows only: another app has nothing to
/// receive them with.
private final class MacBlockDraggingSource: NSObject, NSDraggingSource {
    @MainActor static let shared = MacBlockDraggingSource()

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        // The destination has already taken what it needs from the drag.
        MainActor.assumeIsolated { ExternalBlockDrag.active = nil }
    }
}

/// Page-level drop target for blocks dragged from another editor window.
struct MacBlockDropDelegate: DropDelegate {
    let onUpdate: (CGPoint) -> Void
    let onDrop: (CGPoint) -> Bool
    let onCancel: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [MacExternalBlockDrag.contentType])
    }

    func dropEntered(info: DropInfo) {
        onUpdate(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onUpdate(info.location)
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func dropExited(info _: DropInfo) {
        onCancel()
    }

    func performDrop(info: DropInfo) -> Bool {
        let accepted = onDrop(info.location)
        onCancel()
        return accepted
    }
}
#endif
