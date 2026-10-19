import Foundation

/// Page links behave as single tokens in the live editor: the caret steps over
/// a link rather than into it, a selection that reaches into a link takes all of
/// it, and a delete that touches a link removes the whole link. The read-only
/// row shows a link as its target's title, not the stored label, so editing
/// part of the label would change text the reader never sees. External links
/// keep ordinary text behaviour; their label is the user's own words.
enum AtomicLinks {
    /// The full range of the page link that `position` falls strictly inside,
    /// or nil when `position` is at a link's edge or outside any page link.
    static func linkRange(around position: Int, in storage: NSAttributedString) -> NSRange? {
        guard position > 0, position < storage.length,
              let link = atomicLink(at: position, in: storage),
              let before = atomicLink(at: position - 1, in: storage),
              link.isEqual(before) else { return nil }
        var range = NSRange(location: NSNotFound, length: 0)
        _ = storage.attribute(
            .link,
            at: position,
            longestEffectiveRange: &range,
            in: NSRange(location: 0, length: storage.length)
        )
        return range.location == NSNotFound ? nil : range
    }

    /// The selection to apply instead of `proposed`, so that neither end sits
    /// inside a page link. An end that moved snaps to the link edge in the
    /// direction it was moving, so arrowing (or shift-arrowing) walks over a
    /// link in one step and back again; an end that didn't move (a click, a
    /// double-click inside a link) snaps to the nearer edge, or outward.
    static func snapSelection(from old: NSRange, to proposed: NSRange, in storage: NSAttributedString) -> NSRange {
        guard proposed.location != NSNotFound else { return proposed }
        if proposed.length == 0 {
            let caret = proposed.location
            guard let link = linkRange(around: caret, in: storage) else { return proposed }
            let target: Int
            if old.length == 0, old.location == link.location {
                target = NSMaxRange(link)
            } else if old.length == 0, old.location == NSMaxRange(link) {
                target = link.location
            } else {
                target = caret - link.location < NSMaxRange(link) - caret ? link.location : NSMaxRange(link)
            }
            return NSRange(location: target, length: 0)
        }

        var start = proposed.location
        var end = NSMaxRange(proposed)
        if let link = linkRange(around: start, in: storage) {
            if start > old.location {
                start = NSMaxRange(link)
            } else {
                start = link.location
            }
        }
        if let link = linkRange(around: end, in: storage) {
            if end < NSMaxRange(old) {
                end = link.location
            } else {
                end = NSMaxRange(link)
            }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// `range` widened so that it covers every page link it partly overlaps.
    /// Backspace at a link's end asks to delete its last character; this turns
    /// that into deleting the link.
    static func expandEdit(_ range: NSRange, in storage: NSAttributedString) -> NSRange {
        guard range.location != NSNotFound else { return range }
        var start = range.location
        var end = NSMaxRange(range)
        if let link = linkRange(around: start, in: storage) {
            start = link.location
        }
        if let link = linkRange(around: end, in: storage) {
            end = NSMaxRange(link)
        }
        return NSRange(location: start, length: end - start)
    }

    static func atomicLink(at index: Int, in storage: NSAttributedString) -> NSObject? {
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        let url: URL?
        if let value = value as? URL {
            url = value
        } else if let value = value as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url, !isExternalLinkURL(url) else { return nil }
        return value as? NSObject
    }
}
