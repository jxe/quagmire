import Foundation
import SwiftUI

/// Where the caret or text selection sits in a block's text. Offsets are
/// UTF-16 code units, the platform text views' own units, and are clamped to
/// the block's text.
public enum EditorTextSelection: Sendable, Equatable {
    case start
    case end
    case caret(Int)
    case range(Range<Int>)

    func utf16Range(length: Int) -> Range<Int> {
        func clamp(_ offset: Int) -> Int { max(0, min(offset, length)) }
        switch self {
        case .start: return 0..<0
        case .end: return length..<length
        case .caret(let offset): return clamp(offset)..<clamp(offset)
        case .range(let range): return clamp(range.lowerBound)..<clamp(range.upperBound)
        }
    }
}

/// A focus change the host asked for. The mounted `EditorView` carries it out
/// through the same transitions as the user's own clicks and keys, so live
/// text is committed, hidden rows are revealed, and non-text blocks are
/// selected rather than edited.
enum HostFocusRequest: Equatable {
    case edit(BlockID, EditorTextSelection)
    case select(BlockID)
    case endEditing
}

/// The caret or selection last reported by the live editor, in UTF-16 offsets.
struct LiveTextRange: Equatable {
    let block: BlockID
    let range: Range<Int>
}

extension EditorState {
    /// Edit `block` with the caret or selection placed. A block without
    /// editable text (code, divider, page link) is selected instead; a block
    /// that is not in the document is ignored. Takes effect once the editor is
    /// on screen, so a host may call this right after creating the state.
    public func edit(_ block: BlockID, selection: EditorTextSelection = .end) {
        hostFocusRequest = .edit(block, selection)
    }

    /// Select `block` in navigation mode, committing any text being edited.
    public func select(_ block: BlockID) {
        hostFocusRequest = .select(block)
    }

    /// Leave edit mode with the edited block still selected, as Escape does.
    public func endEditing() {
        hostFocusRequest = .endEditing
    }

    /// The caret or selection in the block being edited, in UTF-16 offsets;
    /// nil in navigation mode.
    public var textSelection: Range<Int>? {
        guard let editingBlock, let liveTextRange, liveTextRange.block == editingBlock else { return nil }
        return liveTextRange.range
    }

    func takeHostFocusRequest() -> HostFocusRequest? {
        defer { if hostFocusRequest != nil { hostFocusRequest = nil } }
        return hostFocusRequest
    }

    func noteTextSelection(_ range: Range<Int>, in block: BlockID) {
        let next = LiveTextRange(block: block, range: range)
        if liveTextRange != next { liveTextRange = next }
    }
}

/// The live text view, as the editor's focus requests reach it. A view
/// attaches when it joins a window and detaches when it leaves; it reports
/// every selection change.
@MainActor
protocol LiveTextSelectionView: AnyObject {
    var liveBlockID: BlockID? { get }
    /// Become first responder if needed and select `range` (UTF-16, clamped).
    func applyLiveSelection(_ range: NSRange)
}

@MainActor
final class LiveTextSelection {
    private weak var view: (any LiveTextSelectionView)?
    var onChange: ((NSRange, BlockID) -> Void)?

    init() {}

    func attach(_ view: any LiveTextSelectionView) { self.view = view }

    func detach(_ view: any LiveTextSelectionView) {
        if self.view === view { self.view = nil }
    }

    /// Select `range` in the live editor when it is editing `block`.
    func select(_ range: NSRange, in block: BlockID) -> Bool {
        guard let view, view.liveBlockID == block else { return false }
        view.applyLiveSelection(range)
        return true
    }

    func report(_ range: NSRange, in block: BlockID) {
        onChange?(range, block)
    }
}

private struct LiveTextSelectionKey: EnvironmentKey {
    static let defaultValue: LiveTextSelection? = nil
}

extension EnvironmentValues {
    var liveTextSelection: LiveTextSelection? {
        get { self[LiveTextSelectionKey.self] }
        set { self[LiveTextSelectionKey.self] = newValue }
    }
}

extension EditorView {
    /// Carry out the host's pending focus request, if any.
    func performHostFocusRequest() {
        guard let request = state.takeHostFocusRequest() else { return }
        switch request {
        case .edit(let id, let selection):
            guard let block = document.find(id) else { return }
            switch block.kind {
            case .code, .divider, .documentLink:
                transferFocus(to: .nav(cursor: id))
                return
            default:
                break
            }
            guard !readOnly else {
                transferFocus(to: .nav(cursor: id))
                return
            }
            let length = (String(block.text.characters) as NSString).length
            let range = selection.utf16Range(length: length)
            // Already editing it: select in place rather than remounting.
            if state.editingBlock == id,
               liveTextSelection.select(NSRange(location: range.lowerBound, length: range.count), in: id) {
                return
            }
            transferFocus(to: .editor(id, initialCursor: .range(range)))
        case .select(let id):
            guard document.find(id) != nil else { return }
            transferFocus(to: .nav(cursor: id))
        case .endEditing:
            guard let id = state.editingBlock else { return }
            transferFocus(to: .nav(cursor: id))
        }
    }
}
