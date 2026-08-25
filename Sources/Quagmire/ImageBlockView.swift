import SwiftUI

/// Renders one document-scoped image source. Loading is asynchronous and keyed
/// by both document and source so a late result from an old page or edited
/// block cannot replace the current presentation.
struct ImageBlockView: View {
    let source: String
    let alt: String
    let theme: EditorTheme
    @Environment(\.editorHost) private var host: EditorHost?
    @Environment(\.editorDocument) private var document: Document?
    @State private var loadState: ImageLoadState = .loading
    #if !os(macOS)
    @State private var presentingFullSize = false
    #endif

    var body: some View {
        Group {
            switch loadState {
            case .loaded(let resource):
                if let loaded = image(from: resource) {
                    loaded
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 400, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                        .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(alt))
                        .onTapGesture { openFullSize(resource) }
                        #if os(macOS)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        #else
                        .sheet(isPresented: $presentingFullSize) {
                            FullSizeImageView(resource: resource, alt: alt) {
                                presentingFullSize = false
                            }
                        }
                        #endif
                } else {
                    missingPlaceholder
                }
            case .loading:
                loadingPlaceholder
            case .missing:
                missingPlaceholder
            }
        }
        .task(id: "\(String(describing: document?.id))\u{0}\(source)") {
            loadState = .loading
            guard let host, let document else {
                loadState = .missing
                return
            }
            let resource = await host.imageResource(for: source, in: document)
            guard !Task.isCancelled else { return }
            loadState = resource.map(ImageLoadState.loaded) ?? .missing
        }
    }

    private func openFullSize(_ resource: EditorImageResource) {
        #if os(macOS)
        presentImageViewerWindow(resource: resource, alt: alt)
        #else
        presentingFullSize = true
        #endif
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading image…")
                .font(theme.body())
                .foregroundStyle(theme.mutedForeground)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Loading image")
    }

    private var missingPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(theme.mutedForeground)
            Text("Missing image: \(source)")
                .font(theme.body())
                .foregroundStyle(theme.mutedForeground)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private enum ImageLoadState {
    case loading
    case loaded(EditorImageResource)
    case missing
}

private func image(from resource: EditorImageResource) -> SwiftUI.Image? {
    #if os(macOS)
    let value: NSImage?
    switch resource {
    case .file(let url): value = NSImage(contentsOf: url)
    case .data(let data): value = NSImage(data: data)
    }
    return value.map(SwiftUI.Image.init(nsImage:))
    #else
    let value: UIImage?
    switch resource {
    case .file(let url): value = UIImage(contentsOfFile: url.path)
    case .data(let data): value = UIImage(data: data)
    }
    return value.map(SwiftUI.Image.init(uiImage:))
    #endif
}

/// Modal viewer for a single image. Two discrete zoom modes — fit-to-window
/// and actual size — preserve the previous local-file behavior for both file
/// and data-backed resources.
private struct FullSizeImageView: View {
    let resource: EditorImageResource
    let alt: String
    let onClose: () -> Void

    private enum Zoom { case fit, actual }
    @State private var zoom: Zoom = .fit

    var body: some View {
        ZStack(alignment: .topTrailing) {
            #if os(macOS)
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            #else
            Color(UIColor.systemBackground).ignoresSafeArea()
            #endif

            imageContent.frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let loaded = image(from: resource) {
            switch zoom {
            case .fit:
                loaded
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
                    .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(alt))
                    .contentShape(Rectangle())
                    .onTapGesture { zoom = .actual }
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering { NSCursor.zoomIn.push() } else { NSCursor.pop() }
                    }
                    #endif
            case .actual:
                ScrollView([.horizontal, .vertical]) {
                    loaded
                        .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(alt))
                        .onTapGesture { zoom = .fit }
                        #if os(macOS)
                        .onHover { hovering in
                            if hovering { NSCursor.zoomOut.push() } else { NSCursor.pop() }
                        }
                        #endif
                }
            }
        } else {
            Text("Could not load image")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}

#if os(macOS)
import AppKit

@MainActor
private final class ImageViewerWindowHolder {
    static let shared = ImageViewerWindowHolder()
    private var window: NSWindow?

    func present(resource: EditorImageResource, alt: String) {
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
            let windowFrame = screenFrame.insetBy(dx: screenFrame.width * 0.05, dy: screenFrame.height * 0.05)
            w = NSWindow(
                contentRect: windowFrame,
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            window = w
        }

        w.title = alt.isEmpty ? "Image" : alt
        w.contentView = NSHostingView(
            rootView: FullSizeImageView(resource: resource, alt: alt) { [weak w] in
                w?.orderOut(nil)
            }
        )
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private func presentImageViewerWindow(resource: EditorImageResource, alt: String) {
    ImageViewerWindowHolder.shared.present(resource: resource, alt: alt)
}
#endif
