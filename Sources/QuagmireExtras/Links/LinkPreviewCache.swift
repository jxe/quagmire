import CryptoKit
import Foundation
import Quagmire

struct LinkPreviewCache: Sendable {
    struct Entry: Sendable {
        let preview: LinkPreview?
        let isStale: Bool
    }

    let directory: URL
    let ttl: TimeInterval
    private let now: @Sendable () -> Date

    init(
        directory: URL,
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.ttl = ttl
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func read(for url: URL) -> Entry? {
        let key = Self.key(for: url)
        let jsonURL = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: jsonURL),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return nil
        }
        let stale = now().timeIntervalSince1970 - record.fetchedAt > ttl
        switch record.status {
        case .ok:
            let iconURL = directory.appendingPathComponent("\(key).png")
            return Entry(
                preview: LinkPreview(
                    url: url,
                    title: record.title,
                    iconPNG: try? Data(contentsOf: iconURL)
                ),
                isStale: stale
            )
        case .failed:
            return Entry(preview: nil, isStale: stale)
        }
    }

    func write(_ preview: LinkPreview?, for url: URL) {
        let key = Self.key(for: url)
        let jsonURL = directory.appendingPathComponent("\(key).json")
        let iconURL = directory.appendingPathComponent("\(key).png")
        let record: Record
        if let preview {
            record = Record(
                url: url.absoluteString,
                title: preview.title,
                fetchedAt: now().timeIntervalSince1970,
                status: .ok
            )
            if let iconPNG = preview.iconPNG {
                try? iconPNG.write(to: iconURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: iconURL)
            }
        } else {
            record = Record(
                url: url.absoluteString,
                title: nil,
                fetchedAt: now().timeIntervalSince1970,
                status: .failed
            )
            try? FileManager.default.removeItem(at: iconURL)
        }
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct Record: Codable {
        enum Status: String, Codable { case ok, failed }
        let url: String
        let title: String?
        let fetchedAt: TimeInterval
        let status: Status
    }
}
