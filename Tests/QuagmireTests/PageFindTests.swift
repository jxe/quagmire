import Foundation
import Testing
@testable import Quagmire

@Suite("Find in page")
struct PageFindTests {
    @Test func findsEveryOccurrenceInDocumentOrder() {
        let first = Block.paragraph(text: "Needle and needle")
        let child = Block.code(source: "a needle in code")
        let parent = Block.heading(level: .h2, text: "Parent", children: [child])

        let matches = pageFindMatches(in: [first, parent], query: "needle")

        #expect(matches == [
            PageFindMatch(blockID: first.id, occurrence: 0),
            PageFindMatch(blockID: first.id, occurrence: 1),
            PageFindMatch(blockID: child.id, occurrence: 0),
        ])
    }

    @Test func matchingIsCaseAndDiacriticInsensitive() {
        let block = Block.paragraph(text: "Résumé RESUME")

        #expect(pageFindMatches(in: [block], query: "resume").count == 2)
    }

    @Test func ignoresWhitespaceOnlyQueriesAndSearchesRenderedFallbacks() {
        let image = Block.image(source: "asset.png", alt: "Map of Berlin")
        let unsupported = Block.unsupported(payload: "raw needle payload", display: "Table")

        #expect(pageFindMatches(in: [image, unsupported], query: "   ").isEmpty)
        #expect(pageFindMatches(in: [image, unsupported], query: "berlin").map(\.blockID) == [image.id])
        #expect(pageFindMatches(in: [image, unsupported], query: "needle").map(\.blockID) == [unsupported.id])
    }
}
