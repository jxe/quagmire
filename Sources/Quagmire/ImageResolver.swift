import Foundation

/// A pasted image awaiting persistence. The editor hands these to the
/// document-scoped async image host before inserting any Markdown block.
public struct PastedImage: Sendable, Equatable {
    /// Raw image bytes, already encoded in `format`'s extension.
    public let data: Data
    /// File extension without the leading dot (e.g. `"png"`, `"jpg"`).
    public let ext: String

    public init(data: Data, ext: String) {
        self.data = data
        self.ext = ext
    }
}

/// Provider-neutral bytes used by image rows. Local-file hosts can retain a
/// file URL; replicas and remote-backed hosts can return in-memory data.
public enum EditorImageResource: Sendable, Equatable {
    case file(URL)
    case data(Data)
}
