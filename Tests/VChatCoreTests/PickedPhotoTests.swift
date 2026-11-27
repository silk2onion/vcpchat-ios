import Foundation
import Testing
import VChatCore

struct PickedPhotoTests {
    @Test func pickerNamesDistinguishImagesAcrossBatches() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aagAAAAASUVORK5CYII="))
        let gif = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
        let first = try await AttachmentImporter().preparePickedPhoto(png, mime: "image/jpeg")
        let second = try await AttachmentImporter().preparePickedPhoto(gif, mime: "image/gif")
        let again = try await AttachmentImporter().preparePickedPhoto(png, mime: "image/png")
        #expect(first.name != second.name)
        #expect(first.name == again.name)
        #expect(first.name.hasSuffix(".png") && second.name.hasSuffix(".gif"))
        #expect(first.bytes == png && second.bytes == gif)
    }
}
