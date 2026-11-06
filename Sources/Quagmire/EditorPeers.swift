import SwiftUI

/// Someone else in the document, as the host knows from presence: a person
/// or an agent, at a block. Quagmire draws their initials in the accessory
/// lane beside the block (stacked when several share it), can wash the row
/// in their colour, and floats an optional bubble just under the row without
/// moving the text. Peers are host-owned presentation: never part of the
/// document, its undo history or serialization.
@MainActor
public struct EditorPeer: Identifiable {
    public let id: String
    public let block: BlockID
    public let color: Color
    /// One or two letters.
    public let initials: String
    /// The name read out and shown on hover, such as "Ana" or "Claude (Ana)".
    public let label: String
    public let isAgent: Bool
    /// The host's picture of the peer, such as a profile photo, drawn in the
    /// badge's circle in place of the initials. An agent keeps its sparkle.
    let avatar: AnyView?
    let bubble: AnyView?

    public init(id: String, block: BlockID, color: Color, initials: String, label: String, isAgent: Bool = false,
                avatar: AnyView? = nil) {
        self.id = id; self.block = block; self.color = color; self.initials = initials
        self.label = label; self.isAgent = isAgent; self.avatar = avatar; self.bubble = nil
    }

    /// A peer with a bubble, such as an agent's status line. The bubble floats
    /// just under the row, over whatever follows, so draw it as a card.
    public init<Bubble: View>(id: String, block: BlockID, color: Color, initials: String, label: String,
                              isAgent: Bool = false, avatar: AnyView? = nil, @ViewBuilder bubble: () -> Bubble) {
        self.id = id; self.block = block; self.color = color; self.initials = initials
        self.label = label; self.isAgent = isAgent; self.avatar = avatar; self.bubble = AnyView(bubble())
    }
}

public extension EditorView {
    /// Show `values` beside their blocks. `tint` washes each peer's row in
    /// their colour (off by default).
    func peers(_ values: [EditorPeer], tint: Bool = false) -> Self {
        var copy = self
        copy.editorPeers = values
        copy.tintsPeerRows = tint
        return copy
    }
}

extension EditorView {
    func peers(at block: BlockID) -> [EditorPeer] {
        editorPeers.filter { $0.block == block && document.find(block) != nil }
    }

    /// Accessory markers and peer initials share the lane: accessories first.
    func laneMarkers(at block: BlockID) -> AnyView? {
        let markers = accessoryMarkers(at: .block(block))
        let here = peers(at: block)
        guard markers != nil || !here.isEmpty else { return nil }
        return AnyView(VStack(spacing: 4) {
            if let markers { markers }
            if !here.isEmpty { EditorPeerStack(peers: here) }
        })
    }

    func peerTint(at block: BlockID) -> Color? {
        guard tintsPeerRows else { return nil }
        // A callout already draws its own panel; a second wash wouldn't line up with it.
        if !editorCallouts.isEmpty, let current = document.find(block), callout(for: current) != nil { return nil }
        return peers(at: block).first?.color
    }

    func peerBubbles(at block: BlockID) -> AnyView? {
        let bubbles = peers(at: block).compactMap { peer in peer.bubble.map { (peer.id, $0) } }
        guard !bubbles.isEmpty else { return nil }
        return AnyView(VStack(alignment: .trailing, spacing: 4) {
            ForEach(bubbles, id: \.0) { $0.1 }
        })
    }

    var hasPeers: Bool { !editorPeers.isEmpty }
}

/// Peers' initials, overlapping slightly when several share a block.
struct EditorPeerStack: View {
    let peers: [EditorPeer]

    var body: some View {
        VStack(spacing: -6) {
            ForEach(peers.prefix(3)) { peer in
                EditorPeerBadge(peer: peer)
            }
        }
        .frame(minWidth: 28, minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peers.map(\.label).joined(separator: ", "))
    }
}

struct EditorPeerBadge: View {
    let peer: EditorPeer

    var body: some View {
        ZStack {
            Circle().fill(peer.color)
            if let avatar = peer.avatar {
                avatar
            } else {
                Text(peer.initials)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                if peer.isAgent {
                    Image(systemName: "sparkle")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(peer.color)
                        .padding(1.5)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: 4)
                }
            }
            .help(peer.label)
    }
}
