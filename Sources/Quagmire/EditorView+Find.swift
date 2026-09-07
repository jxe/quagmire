import SwiftUI

struct PageFindMatch: Equatable, Sendable {
    let blockID: BlockID
    let occurrence: Int
}

func pageFindMatches(in blocks: [Block], query: String) -> [PageFindMatch] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }

    var matches: [PageFindMatch] = []
    func visit(_ block: Block) {
        let text: String
        switch block.kind {
        case .code(let source, _):
            text = source
        case .image(_, let alt):
            text = alt
        case .unsupported(let payload, let display):
            text = display + "\n" + payload
        default:
            text = String(block.text.characters)
        }

        var searchRange = text.startIndex..<text.endIndex
        var occurrence = 0
        while let range = text.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        ) {
            matches.append(PageFindMatch(blockID: block.id, occurrence: occurrence))
            occurrence += 1
            guard range.upperBound < text.endIndex else { break }
            searchRange = range.upperBound..<text.endIndex
        }

        for child in block.children {
            visit(child)
        }
    }

    for block in blocks {
        visit(block)
    }
    return matches
}

extension EditorView {
    func presentFind() {
        if let editingBlock = state.editingBlock {
            transferFocus(to: .nav(cursor: editingBlock))
        }
        findPresented = true
        findFocusRequest &+= 1
    }

    func dismissFind() {
        findPresented = false
        forcePageFocusGrab()
    }

    func selectFindMatch(_ match: PageFindMatch) {
        revealHiddenBlocks([match.blockID])
        state.setCursor(match.blockID)
        scrollToFindMatch(match.blockID)
    }

    func moveFindSelection(by delta: Int, matches: [PageFindMatch]) {
        guard !matches.isEmpty else { return }
        let current = min(max(findSelectionIndex, 0), matches.count - 1)
        findSelectionIndex = (current + delta + matches.count) % matches.count
        selectFindMatch(matches[findSelectionIndex])
    }

    func updateFindQuery(matches: [PageFindMatch]) {
        findSelectionIndex = 0
        guard let first = matches.first else { return }
        selectFindMatch(first)
    }

    func scrollToFindMatch(_ blockID: BlockID) {
        // Revealing a match can expand one or more ancestors, so let the visible
        // row layout refresh before asking either platform's scroll mechanism
        // for the target.
        Task { @MainActor in
            await Task.yield()
            #if os(macOS)
            scrollPosition.scrollTo(id: blockID, anchor: .center)
            #else
            await Task.yield()
            guard let frame = layoutCache.internalFrame(of: blockID) else { return }
            let centeredY = frame.midY + 32 - (scrollMetrics.viewportHeight / 2)
            PageScrollController.shared.scroll(toY: max(0, centeredY))
            #endif
        }
    }

    func findBar(matches: [PageFindMatch]) -> some View {
        let selectedIndex = matches.isEmpty ? 0 : min(findSelectionIndex, matches.count - 1)
        return PageFindBar(
            query: $findQuery,
            focusRequest: findFocusRequest,
            selectedIndex: selectedIndex,
            matchCount: matches.count,
            onQueryChange: { updateFindQuery(matches: pageFindMatches(in: document.children, query: $0)) },
            onPrevious: { moveFindSelection(by: -1, matches: matches) },
            onNext: { moveFindSelection(by: 1, matches: matches) },
            onClose: { dismissFind() }
        )
    }
}

private struct PageFindBar: View {
    @Binding var query: String
    let focusRequest: Int
    let selectedIndex: Int
    let matchCount: Int
    let onQueryChange: (String) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in Page", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)
                .onSubmit(onNext)
                .onChange(of: query) { _, newValue in onQueryChange(newValue) }
                #if os(macOS)
                .onExitCommand(perform: onClose)
                #endif
            Text(matchCount == 0 ? "No results" : "\(selectedIndex + 1) of \(matchCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Previous Match", systemImage: "chevron.up", action: onPrevious)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
            Button("Next Match", systemImage: "chevron.down", action: onNext)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
            Button("Close Find", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: 520)
        .onAppear { isFocused = true }
        .onChange(of: focusRequest) { _, _ in isFocused = true }
    }
}
