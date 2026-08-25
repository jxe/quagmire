import Foundation

public struct PendingVoiceRecording<Destination: Codable & Sendable>: Codable, Identifiable, Sendable {
    public let id: UUID
    public let destination: Destination
    public let createdAt: Date

    init(id: UUID = UUID(), destination: Destination, createdAt: Date) {
        self.id = id
        self.destination = destination
        self.createdAt = createdAt
    }
}

extension PendingVoiceRecording: Equatable where Destination: Equatable {}

public struct PendingVoiceRecordingStore<Destination: Codable & Sendable>: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func begin(
        destination: Destination,
        now: Date = Date()
    ) throws -> PendingVoiceRecording<Destination> {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let recording = PendingVoiceRecording(destination: destination, createdAt: now)
        let data = try JSONEncoder().encode(recording)
        try data.write(to: metadataURL(for: recording), options: .atomic)
        return recording
    }

    public func audioURL(for recording: PendingVoiceRecording<Destination>) -> URL {
        directoryURL
            .appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("caf")
    }

    public func pendingRecordings() throws -> [PendingVoiceRecording<Destination>] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let recording = try? JSONDecoder().decode(
                    PendingVoiceRecording<Destination>.self,
                    from: data
                  ),
                  FileManager.default.fileExists(atPath: audioURL(for: recording).path) else {
                return nil
            }
            return recording
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ recording: PendingVoiceRecording<Destination>) throws {
        let fileManager = FileManager.default
        for url in [audioURL(for: recording), metadataURL(for: recording)]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func metadataURL(for recording: PendingVoiceRecording<Destination>) -> URL {
        directoryURL
            .appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("json")
    }
}
