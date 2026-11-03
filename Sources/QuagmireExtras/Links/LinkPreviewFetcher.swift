import Foundation
import ImageIO
import Quagmire
import UniformTypeIdentifiers

/// Reads a page's title and icon with a plain HTTP request and the page's
/// `<head>`, entirely off the main thread.
///
/// LinkPresentation's `LPMetadataProvider` loads the page in a WebKit view
/// created on the main thread: on a cache miss that froze the editor for
/// 100–400 ms while a page opened. Titles come from `og:title` or `<title>`,
/// icons from the page's `<link rel="icon">` (or `/favicon.ico`), scaled down
/// with ImageIO. Pages that only fill in their title with script show no title.
enum LinkPreviewFetcher {
    private static let iconPixelSize = 28
    /// Enough of a page to hold its `<head>`.
    private static let headBytes = 256 * 1024

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = [
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
        ]
        return URLSession(configuration: configuration)
    }()

    static func fetch(url: URL) async -> LinkPreview? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let base = http.url ?? url
        let isHTML = http.mimeType.map { $0.contains("html") } ?? true
        // Only the head is read: the rest of the page (or a large file) is
        // never downloaded.
        var data = Data()
        if isHTML {
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= headBytes { break }
                    if byte == UInt8(ascii: ">"), data.count >= 7,
                       data.suffix(7).elementsEqual("</head>".utf8, by: { $0 | 0x20 == $1 | 0x20 }) { break }
                }
            } catch {}
        }
        bytes.task.cancel()
        let page = HTMLHead(String(decoding: data, as: UTF8.self))
        let title = page.title
        let iconURL = page.iconHref.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            ?? URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL
        var iconPNG: Data?
        if let iconURL { iconPNG = await loadIconPNG(from: iconURL) }
        guard title != nil || iconPNG != nil else { return nil }
        return LinkPreview(url: url, title: title, iconPNG: iconPNG)
    }

    private static func loadIconPNG(from url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return scaledPNG(data)
    }

    /// The image's largest frame scaled to fit the icon size, as PNG.
    static func scaledPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: iconPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, largestFrame(of: source), options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// An `.ico` holds several sizes; the largest scales down best.
    private static func largestFrame(of source: CGImageSource) -> Int {
        var best = 0
        var bestWidth = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > bestWidth { best = index; bestWidth = width }
        }
        return best
    }
}

/// The few things a link preview reads from a page's `<head>`.
struct HTMLHead {
    var title: String?
    var iconHref: String?

    init(_ html: String) {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        var ogTitle: String?
        var icons: [(rank: Int, href: String)] = []
        for tag in Self.tags(named: ["meta", "link"], in: head) {
            let attributes = tag.attributes
            if tag.name == "meta" {
                let key = (attributes["property"] ?? attributes["name"])?.lowercased()
                if ogTitle == nil, key == "og:title" || key == "twitter:title",
                   let content = attributes["content"], !content.isEmpty {
                    ogTitle = content
                }
            } else if let rel = attributes["rel"]?.lowercased(), let href = attributes["href"], !href.isEmpty {
                let words = Set(rel.split(separator: " ").map(String.init))
                if words.contains("apple-touch-icon") || words.contains("apple-touch-icon-precomposed") {
                    icons.append((0, href))
                } else if words.contains("icon") {
                    icons.append((attributes["type"]?.contains("svg") == true ? 3 : 1, href))
                }
            }
        }
        let titleTag = Self.titleElement(in: head)
        title = (ogTitle ?? titleTag).map(Self.decodeEntities)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // ImageIO can't draw SVG: prefer touch icons, then bitmap icons.
        iconHref = icons.filter { $0.rank < 3 }.min { $0.rank < $1.rank }?.href
    }

    private struct Tag {
        var name: String
        var attributes: [String: String]
    }

    private static func tags(named names: Set<String>, in html: String) -> [Tag] {
        var result: [Tag] = []
        var rest = html[...]
        while let open = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: open)...]
            let nameEnd = rest.firstIndex { !$0.isLetter && !$0.isNumber } ?? rest.endIndex
            let name = rest[..<nameEnd].lowercased()
            guard let close = rest.firstIndex(of: ">") else { break }
            if names.contains(name) {
                result.append(Tag(name: name, attributes: attributes(in: rest[nameEnd..<close])))
            }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// `key="value"`, `key='value'` and `key=value` pairs; keys lowercased.
    private static func attributes(in text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        func skipSpace() { while index < text.endIndex, text[index].isWhitespace || text[index] == "/" { index = text.index(after: index) } }
        while true {
            skipSpace()
            guard index < text.endIndex else { break }
            let keyStart = index
            while index < text.endIndex, !text[index].isWhitespace, text[index] != "=", text[index] != "/" { index = text.index(after: index) }
            let key = text[keyStart..<index].lowercased()
            skipSpace()
            guard index < text.endIndex, text[index] == "=" else {
                if !key.isEmpty { result[key] = "" }
                continue
            }
            index = text.index(after: index)
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let value: Substring
            if text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                let start = text.index(after: index)
                let end = text[start...].firstIndex(of: quote) ?? text.endIndex
                value = text[start..<end]
                index = end < text.endIndex ? text.index(after: end) : end
            } else {
                let start = index
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
                value = text[start..<index]
            }
            if !key.isEmpty, result[key] == nil { result[key] = String(value) }
        }
        return result
    }

    private static func titleElement(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html[open.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: openEnd..<html.endIndex) else { return nil }
        return String(html[html.index(after: openEnd)..<close.lowerBound])
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                     "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        var result = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let entity = after[..<semi]
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[String(entity)]
                }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }
}
