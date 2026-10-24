import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// The forms a pasteboard carries beside its plain string, handed to
/// `EditorHost.parseBlocksFromPasteboard(_:rich:)` for hosts that read
/// structure another app's string dropped.
public struct PasteboardRichContent: Sendable, Equatable {
    /// The pasteboard's HTML, as markup.
    public var html: String?
    /// Custom types a web page or Electron app wrote with
    /// `DataTransfer.setData` (Chromium's `org.chromium.web-custom-data`),
    /// keyed by type. Notion keeps its blocks here, as
    /// `text/_notion-blocks-v3-production`.
    public var webCustomData: [String: String]

    public init(html: String? = nil, webCustomData: [String: String] = [:]) {
        self.html = html
        self.webCustomData = webCustomData
    }

    public var isEmpty: Bool { html == nil && webCustomData.isEmpty }

    static let chromiumWebCustomDataType = "org.chromium.web-custom-data"

    #if os(macOS)
    init(_ pasteboard: NSPasteboard) {
        let html = pasteboard.string(forType: .html)
            ?? pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        let custom = pasteboard.data(forType: NSPasteboard.PasteboardType(Self.chromiumWebCustomDataType))
        self.init(html: html, webCustomData: custom.map(Self.decodeChromiumWebCustomData) ?? [:])
    }
    #else
    init(_ pasteboard: UIPasteboard) {
        let type = UTType.html.identifier
        let html = pasteboard.value(forPasteboardType: type) as? String
            ?? pasteboard.data(forPasteboardType: type).flatMap { String(data: $0, encoding: .utf8) }
        let custom = pasteboard.data(forPasteboardType: Self.chromiumWebCustomDataType)
        self.init(html: html, webCustomData: custom.map(Self.decodeChromiumWebCustomData) ?? [:])
    }
    #endif

    /// Chromium writes web custom data as a `base::Pickle`: a UInt32 payload
    /// size, a UInt32 count of pairs, then each key and value as a UInt32
    /// length in UTF-16 code units followed by little-endian UTF-16, padded to
    /// four bytes. Anything malformed reads as no data.
    static func decodeChromiumWebCustomData(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var offset = 4
        func uint32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            offset += 4
            return value
        }
        func string16() -> String? {
            guard let units = uint32() else { return nil }
            let length = units * 2
            guard length <= bytes.count - offset else { return nil }
            var codeUnits: [UInt16] = []
            codeUnits.reserveCapacity(units)
            for index in stride(from: offset, to: offset + length, by: 2) {
                codeUnits.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            }
            offset += (length + 3) & ~3
            return String(decoding: codeUnits, as: UTF16.self)
        }
        guard let count = uint32(), count < 4096 else { return [:] }
        var result: [String: String] = [:]
        for _ in 0..<count {
            guard let key = string16(), let value = string16() else { return [:] }
            result[key] = value
        }
        return result
    }
}
