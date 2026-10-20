import Foundation

/// A recording kept after it was transcribed, so the speaker can listen to
/// it again for a while. Kept recordings are device-local: the host keeps
/// them outside any synced content and prunes them by age and total size.
public struct TranscribedVoiceRecording: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let transcript: String
    public let createdAt: Date
    public let audioFileName: String
    /// The page the transcript was delivered to. Records kept before pages
    /// were recorded have none and never match a block.
    public let pageKey: String?
}

/// Kept recordings, one audio file plus one JSON record each, in a single
/// directory. Main-actor isolated so the recording session and the editor's
/// block actions can share one instance and its in-memory index.
@MainActor
public final class TranscribedVoiceRecordingStore {
    public let directoryURL: URL
    public let maximumAge: TimeInterval
    public let maximumBytes: Int64

    private var cachedRecordings: [TranscribedVoiceRecording]?
    private var cachedWords: [UUID: [String]] = [:]

    public init(
        directoryURL: URL,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60,
        maximumBytes: Int64 = 250 * 1_024 * 1_024
    ) {
        self.directoryURL = directoryURL
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
    }

    /// A fresh location inside the store for audio that is still being
    /// recorded. It only becomes a kept recording once `keep` records it;
    /// `prune` removes it if that never happens.
    public func newAudioURL(fileExtension: String) throws -> URL {
        try createDirectory()
        return directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    /// Keeps the audio at `url`, moving it into the store unless it is
    /// already there, and then prunes. Empty or missing audio is not kept.
    @discardableResult
    public func keep(
        audioAt url: URL,
        transcript: String,
        pageKey: String?,
        now: Date = Date()
    ) throws -> TranscribedVoiceRecording? {
        let fileManager = FileManager.default
        guard let size = Self.fileSize(at: url), size > 0 else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        try createDirectory()
        let id = UUID()
        let destination: URL
        if url.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL {
            destination = url
        } else {
            destination = directoryURL
                .appendingPathComponent(id.uuidString)
                .appendingPathExtension(url.pathExtension)
            try fileManager.moveItem(at: url, to: destination)
        }
        let recording = TranscribedVoiceRecording(
            id: id,
            transcript: transcript,
            createdAt: now,
            audioFileName: destination.lastPathComponent,
            pageKey: pageKey
        )
        try JSONEncoder().encode(recording).write(to: recordURL(for: recording.id), options: .atomic)
        cachedRecordings = nil
        prune(now: now)
        return recording
    }

    /// Kept recordings, newest first.
    public func recordings() -> [TranscribedVoiceRecording] {
        if let cachedRecordings { return cachedRecordings }
        let recordings = recordURLs().compactMap { url -> TranscribedVoiceRecording? in
            guard let data = try? Data(contentsOf: url),
                  let recording = try? JSONDecoder().decode(TranscribedVoiceRecording.self, from: data),
                  FileManager.default.fileExists(atPath: audioURL(for: recording).path) else {
                return nil
            }
            return recording
        }
        .sorted { $0.createdAt > $1.createdAt }
        cachedRecordings = recordings
        return recordings
    }

    public func audioURL(for recording: TranscribedVoiceRecording) -> URL {
        directoryURL.appendingPathComponent(recording.audioFileName)
    }

    /// The kept recording on `pageKey` whose transcript `text` came from, if
    /// any. Words are compared in order, ignoring punctuation and case, so a
    /// few edits (such as polishing away fillers) or a transcript split into
    /// several paragraphs still match. Most of the block's words must appear
    /// in the transcript in order, and the shared run must be at least four
    /// words or half the transcript, so short or common phrases don't match
    /// unrelated recordings. When several match, the newest wins.
    ///
    /// Text matching is a stopgap. When line provenance lands
    /// (plans/later/history-006-line-provenance.md), record the change that
    /// inserted a transcript and match blocks by blame instead.
    public func recording(matching text: String, onPage pageKey: String) -> TranscribedVoiceRecording? {
        let blockWords = Self.words(in: text)
        guard !blockWords.isEmpty else { return nil }
        let required = Int((Double(blockWords.count) * 0.7).rounded(.up))
        for recording in recordings() where recording.pageKey == pageKey {
            let transcriptWords = transcriptWords(for: recording)
            let shared = Self.longestCommonSubsequence(blockWords, transcriptWords)
            if shared >= required, shared >= 4 || shared * 2 >= transcriptWords.count {
                return recording
            }
        }
        return nil
    }

    public func remove(_ recording: TranscribedVoiceRecording) {
        try? FileManager.default.removeItem(at: audioURL(for: recording))
        try? FileManager.default.removeItem(at: recordURL(for: recording.id))
        cachedRecordings = nil
    }

    /// Removes recordings older than `maximumAge`, then the oldest until the
    /// rest fit in `maximumBytes`, and audio that was never kept.
    public func prune(now: Date = Date()) {
        let kept = recordings()
        var keptFileNames = Set<String>()
        var totalBytes: Int64 = 0
        var overBudget = false
        for recording in kept {
            let size = Self.fileSize(at: audioURL(for: recording)) ?? 0
            overBudget = overBudget || totalBytes + size > maximumBytes
            if overBudget || now.timeIntervalSince(recording.createdAt) > maximumAge {
                remove(recording)
            } else {
                totalBytes += size
                keptFileNames.insert(recording.audioFileName)
                keptFileNames.insert(recordURL(for: recording.id).lastPathComponent)
            }
        }
        // Audio still being recorded is left alone for a day.
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in entries where !keptFileNames.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if url.pathExtension == "json" || now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? fileManager.removeItem(at: url)
            }
        }
        cachedRecordings = nil
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directoryURL
        try? directory.setResourceValues(values)
    }

    private func recordURLs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }
    }

    private func recordURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func transcriptWords(for recording: TranscribedVoiceRecording) -> [String] {
        if let words = cachedWords[recording.id] { return words }
        let words = Self.words(in: recording.transcript)
        cachedWords[recording.id] = words
        return words
    }

    nonisolated static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { String($0) }
    }

    nonisolated static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for word in a {
            for (index, other) in b.enumerated() {
                current[index + 1] = word == other
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    nonisolated private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
