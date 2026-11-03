import Foundation
import Testing
@testable import QuagmireExtras

@Suite("Link preview page heads")
struct HTMLHeadTests {
    @Test("og:title wins over <title>, entities are decoded, and a touch icon wins over an SVG")
    func readsTitleAndIcon() {
        let head = HTMLHead("""
        <!doctype html><html><head>
        <TITLE>
          Plain   title
        </TITLE>
        <meta property='og:title' content="Rock &amp; Roll &#8212; &quot;Live&quot;">
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel=icon href=/favicon-32.png>
        <link rel="apple-touch-icon" href="/touch.png" />
        </head><body><title>not this</title></body></html>
        """)
        #expect(head.title == "Rock & Roll — \"Live\"")
        #expect(head.iconHref == "/touch.png")
    }

    @Test("A page with only <title> and a bitmap icon")
    func titleOnly() {
        let head = HTMLHead("<head><title>Hello &lt;world&gt;</title><link rel=\"shortcut icon\" href=\"f.ico\"></head>")
        #expect(head.title == "Hello <world>")
        #expect(head.iconHref == "f.ico")
    }

    @Test("No title and an SVG-only icon give nothing")
    func nothing() {
        let head = HTMLHead("<head><link rel=\"icon\" type=\"image/svg+xml\" href=\"/i.svg\"></head>")
        #expect(head.title == nil)
        #expect(head.iconHref == nil)
    }
}
