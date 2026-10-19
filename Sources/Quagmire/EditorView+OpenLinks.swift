import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A page a row links to: its document link, or a page link in its text.
struct OpenableLink: Hashable {
    let title: String
    let reference: DocumentReference
}

extension EditorView {
    /// Where a link click opens: with ⌘ held, a new tab behind the current one
    /// (selected with ⌘⇧), when the host has tabs; otherwise in place.
    func clickOpenTarget() -> DocumentOpenTarget {
        Self.clickOpenTarget(for: host)
    }

    static func clickOpenTarget(for host: any EditorHost) -> DocumentOpenTarget {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command), host.documentOpenTargets.contains(.newTab) {
            return .newTab(selecting: flags.contains(.shift))
        }
        #endif
        return .current
    }

    static func open(_ reference: DocumentReference, at target: DocumentOpenTarget, host: any EditorHost) {
        if target == .current {
            host.openDocument(reference)
        } else {
            host.openDocument(reference, at: target)
        }
    }

    /// The pages `block` links to that can be opened, in reading order.
    func openableLinks(in block: Block) -> [OpenableLink] {
        var links: [OpenableLink] = []
        var seen = Set<DocumentReference>()
        if case .documentLink(let label, let reference) = block.kind {
            let lookup = host.lookupDocument(reference)
            if lookup.can(.navigate), seen.insert(reference).inserted {
                links.append(OpenableLink(title: lookup.title ?? String(label.characters), reference: reference))
            }
            return links
        }
        for run in block.text.runs {
            guard let url = run.link, !isExternalLinkURL(url),
                  let reference = host.resolveReference(from: url, in: document),
                  host.lookupDocument(reference).can(.navigate),
                  seen.insert(reference).inserted else { continue }
            let text = String(block.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            links.append(OpenableLink(title: text.isEmpty ? (host.lookupDocument(reference).title ?? "Page") : text, reference: reference))
        }
        return links
    }

    /// Open, Open in New Tab and Open in New Window for each of `links`, as
    /// far as the host offers them; one submenu per link when there are several.
    @ViewBuilder
    func linkContextMenu(_ links: [OpenableLink]) -> some View {
        let targets = host.documentOpenTargets
        if links.count == 1, let link = links.first {
            linkMenuItems(link, targets: targets)
        } else {
            ForEach(links, id: \.self) { link in
                Menu(link.title) { linkMenuItems(link, targets: targets) }
            }
        }
    }

    @ViewBuilder
    private func linkMenuItems(_ link: OpenableLink, targets: DocumentOpenTargets) -> some View {
        let host = host
        Button("Open") { Self.open(link.reference, at: .current, host: host) }
        if targets.contains(.newTab) {
            Button("Open in New Tab") { Self.open(link.reference, at: .newTab(selecting: true), host: host) }
        }
        if targets.contains(.newWindow) {
            Button("Open in New Window") { Self.open(link.reference, at: .newWindow, host: host) }
        }
    }
}
