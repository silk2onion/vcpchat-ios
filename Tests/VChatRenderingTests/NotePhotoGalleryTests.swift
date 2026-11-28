import Foundation
import Testing
@testable import VChatRendering

struct NotePhotoGalleryTests {
    @Test func orderedGalleryFromRenderedNote() async throws {
        let first = "https://example.com/a.png", second = "https://example.com/comfyuigen/output?id=2"
        let source = "![海水](\(first))\n\n> [画室原图](\(second))\n\n![重复](\(first))\n\n" +
            "\u{60}https://example.com/example.png\u{60}\n\n[普通链接](https://example.com/home)"
        let blocks = try await MessageRenderer().render(source,options: .init(),dark: false)
        let gallery = NotePhotoGallery(blocks: blocks,selected: try #require(MessageMedia(source: second)))
        #expect(gallery.items.map(\.source) == [first,second]); #expect(gallery.index == 1)
        #expect(!NotePhotoGallery.imageLink(try #require(URL(string: "https://example.com/attachments/report.pdf"))))
    }
}
