import Foundation
@testable import Quagmire
import Testing

@Suite("Pasteboard rich content")
struct PasteboardRichContentTests {
    /// Chromium's pickle: payload size, pair count, then UTF-16 strings
    /// padded to four bytes.
    private func pickle(_ pairs: [(String, String)]) -> Data {
        var payload = Data()
        func uint32(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { payload.append(contentsOf: $0) }
        }
        func string16(_ value: String) {
            let units = Array(value.utf16)
            uint32(units.count)
            for unit in units { withUnsafeBytes(of: unit.littleEndian) { payload.append(contentsOf: $0) } }
            if units.count % 2 == 1 { payload.append(contentsOf: [0, 0]) }
        }
        uint32(pairs.count)
        for (key, value) in pairs {
            string16(key)
            string16(value)
        }
        var data = Data()
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    @Test func decodesChromiumWebCustomData() {
        let data = pickle([("text/_notion-blocks-v3-production", "{\"blocks\":[]}"), ("odd", "é▸")])
        #expect(PasteboardRichContent.decodeChromiumWebCustomData(data) == [
            "text/_notion-blocks-v3-production": "{\"blocks\":[]}",
            "odd": "é▸",
        ])
    }

    @Test func truncatedDataReadsAsNothing() {
        let data = pickle([("key", "value")])
        #expect(PasteboardRichContent.decodeChromiumWebCustomData(data.prefix(data.count - 3)).isEmpty)
        #expect(PasteboardRichContent.decodeChromiumWebCustomData(Data()).isEmpty)
    }
}
