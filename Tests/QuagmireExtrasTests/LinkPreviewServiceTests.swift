import Foundation
import Quagmire
import Testing
@testable import QuagmireExtras

@Suite("External link previews")
struct LinkPreviewServiceTests {
    actor FetchCounter {
        private(set) var count = 0

        func fetch(url: URL, title: String?) async -> LinkPreview? {
            count += 1
            try? await Task.sleep(for: .milliseconds(20))
            return LinkPreview(url: url, title: title, iconPNG: nil)
        }
    }

    @Test func cachePersistsSuccessAndFailureWithTTL() throws {
        let directory = temporaryDirectory("link-cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://example.test")!
        let writtenAt = Date(timeIntervalSince1970: 100)
        let writer = LinkPreviewCache(directory: directory, ttl: 60, now: { writtenAt })
        writer.write(LinkPreview(url: url, title: "Example", iconPNG: Data([1, 2])), for: url)

        let fresh = LinkPreviewCache(
            directory: directory,
            ttl: 60,
            now: { Date(timeIntervalSince1970: 159) }
        ).read(for: url)
        #expect(fresh?.preview?.title == "Example")
        #expect(fresh?.preview?.iconPNG == Data([1, 2]))
        #expect(fresh?.isStale == false)

        let stale = LinkPreviewCache(
            directory: directory,
            ttl: 60,
            now: { Date(timeIntervalSince1970: 161) }
        ).read(for: url)
        #expect(stale?.isStale == true)

        writer.write(nil, for: url)
        let failed = writer.read(for: url)
        #expect(failed != nil)
        #expect(failed?.preview == nil)
    }

    @Test func concurrentRequestsShareOneFetchAndThenUseDiskCache() async {
        let directory = temporaryDirectory("link-service")
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = FetchCounter()
        let url = URL(string: "https://example.test/shared")!
        let service = LinkPreviewService(cacheDirectory: directory) { url in
            await counter.fetch(url: url, title: "Shared")
        }

        async let first = service.preview(for: url)
        async let second = service.preview(for: url)
        let values = await [first, second]

        #expect(values.compactMap(\.self).map(\.title) == ["Shared", "Shared"])
        #expect(await counter.count == 1)
        #expect(await service.preview(for: url)?.title == "Shared")
        #expect(await counter.count == 1)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quagmire-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}
