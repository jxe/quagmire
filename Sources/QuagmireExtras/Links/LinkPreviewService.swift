import Foundation
import Quagmire

public actor LinkPreviewService {
    public typealias Fetcher = @Sendable (URL) async -> LinkPreview?

    public static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60

    private let cache: LinkPreviewCache
    private let fetcher: Fetcher
    private var inFlight: [URL: Task<LinkPreview?, Never>] = [:]

    public init(
        cacheDirectory: URL,
        ttl: TimeInterval = LinkPreviewService.defaultTTL
    ) {
        self.cache = LinkPreviewCache(directory: cacheDirectory, ttl: ttl)
        self.fetcher = { url in await LinkPreviewFetcher.fetch(url: url) }
    }

    public init(
        cacheDirectory: URL,
        ttl: TimeInterval = LinkPreviewService.defaultTTL,
        fetcher: @escaping Fetcher
    ) {
        self.cache = LinkPreviewCache(directory: cacheDirectory, ttl: ttl)
        self.fetcher = fetcher
    }

    init(cache: LinkPreviewCache, fetcher: @escaping Fetcher) {
        self.cache = cache
        self.fetcher = fetcher
    }

    public func preview(for url: URL) async -> LinkPreview? {
        if let cached = cache.read(for: url), !cached.isStale {
            return cached.preview
        }
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task { [cache, fetcher] in
            let preview = await fetcher(url)
            cache.write(preview, for: url)
            return preview
        }
        inFlight[url] = task
        let preview = await task.value
        inFlight[url] = nil
        return preview
    }
}
