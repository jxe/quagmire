import Foundation
import LinkPresentation
import Quagmire
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum LinkPreviewFetcher {
    private static let iconPixelSize: CGFloat = 28

    static func fetch(url: URL) async -> LinkPreview? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        let metadata: LPLinkMetadata
        do {
            metadata = try await provider.startFetchingMetadata(for: url)
        } catch {
            return nil
        }
        let iconPNG = await loadIconPNG(from: metadata.iconProvider)
        guard metadata.title != nil || iconPNG != nil else { return nil }
        return LinkPreview(url: url, title: metadata.title, iconPNG: iconPNG)
    }

    private static func loadIconPNG(from itemProvider: NSItemProvider?) async -> Data? {
        guard let itemProvider else { return nil }
        #if os(macOS)
        guard itemProvider.canLoadObject(ofClass: NSImage.self) else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            itemProvider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
        return image.flatMap(resizeToPNG)
        #else
        guard itemProvider.canLoadObject(ofClass: UIImage.self) else { return nil }
        let image: UIImage? = await withCheckedContinuation { continuation in
            itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        return image.flatMap(resizeToPNG)
        #endif
    }

    #if os(macOS)
    private static func resizeToPNG(_ image: NSImage) -> Data? {
        let target = NSSize(width: iconPixelSize, height: iconPixelSize)
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
    #else
    private static func resizeToPNG(_ image: UIImage) -> Data? {
        let target = CGSize(width: iconPixelSize, height: iconPixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
            .pngData()
    }
    #endif
}
