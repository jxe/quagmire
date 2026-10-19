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
    /// The lifted row's size, for the gap a destination opens.
    var size: CGSize = .zero
    #if os(macOS)
    var panel: MacBlockDragPanel?
    #endif

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
    /// The page drop target accepts the drag by its plain text, which
    /// SwiftUI matches reliably, and recognizes it by the drag in flight in
    /// this process. The text is the blocks' own, so a text field that takes
    /// the drop gets their text.
    static let dropTypes: [UTType] = [.utf8PlainText, .plainText]

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
    /// window. The lifted row keeps following the pointer as `lift`, drawn
    /// with `anchor` under the pointer; the system's drag image is empty.
    static func begin(_ drag: ExternalBlockDrag, event: NSEvent, text: String, lift: AnyView, size: CGSize, anchor: CGSize) -> Bool {
        guard let view = event.window?.contentView else { return false }
        let item = NSPasteboardItem()
        item.setString(drag.token, forType: pasteboardType)
        item.setString(text, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let point = view.convert(event.locationInWindow, from: nil)
        let origin = CGPoint(
            x: point.x - anchor.width,
            y: view.isFlipped ? point.y - anchor.height : point.y - (size.height - anchor.height)
        )
        let blank = NSImage(size: size, flipped: false) { _ in true }
        draggingItem.setDraggingFrame(CGRect(origin: origin, size: size), contents: blank)
        drag.panel = MacBlockDragPanel(content: lift, size: size, anchor: anchor)
        drag.panel?.show(at: NSEvent.mouseLocation)
        ExternalBlockDrag.active = drag
        let session = view.beginDraggingSession(with: [draggingItem], event: event, source: MacBlockDraggingSource.shared)
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }
}

/// The lifted row, drawn above every window while it is dragged between
/// them, so it looks the same as the in-window lift the whole way.
@MainActor
final class MacBlockDragPanel {
    private static let margin: CGFloat = 32
    private let panel: NSPanel
    private let size: CGSize
    private let anchor: CGSize

    init(content: AnyView, size: CGSize, anchor: CGSize) {
        self.size = size
        self.anchor = anchor
        let margin = Self.margin
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .shadow(color: .black.opacity(ReorderLiftStyle.shadowOpacity), radius: ReorderLiftStyle.shadowRadius, y: ReorderLiftStyle.shadowY)
            .scaleEffect(ReorderLiftStyle.liftedScale, anchor: UnitPoint(x: anchor.width / max(size.width, 1), y: anchor.height / max(size.height, 1)))
            .padding(margin))
    }

    /// Put the row's anchor under `point` (screen coordinates).
    func move(to point: NSPoint) {
        let margin = Self.margin
        panel.setFrameOrigin(NSPoint(
            x: point.x - anchor.width - margin,
            y: point.y + anchor.height - size.height - margin
        ))
    }

    func show(at point: NSPoint) {
        move(to: point)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}

/// Offers blocks to this app's windows only: another app has nothing to
/// receive them with.
private final class MacBlockDraggingSource: NSObject, NSDraggingSource {
    @MainActor static let shared = MacBlockDraggingSource()

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated { ExternalBlockDrag.active?.panel?.move(to: screenPoint) }
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        // The destination has already taken what it needs from the drag.
        MainActor.assumeIsolated {
            ExternalBlockDrag.active?.panel?.close()
            ExternalBlockDrag.active = nil
        }
    }
}

/// Page-level drop target for blocks dragged from another editor window.
struct MacBlockDropDelegate: DropDelegate {
    let onUpdate: (CGPoint) -> Void
    let onDrop: (CGPoint) -> Bool
    let onCancel: () -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        MainActor.assumeIsolated { ExternalBlockDrag.active != nil }
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
