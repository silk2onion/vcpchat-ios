import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreImage

public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var mime: String
    public var kind: String
    public var dataUrl: String?
    public var text: String?
    public var hash: String?
    public var desktopOnly: Bool?
    public init(id: String = UUID().uuidString, name: String, mime: String, kind: String, dataUrl: String? = nil, text: String? = nil, hash: String? = nil, desktopOnly: Bool? = nil) {
        self.id = id; self.name = name; self.mime = mime; self.kind = kind; self.dataUrl = dataUrl; self.text = text; self.hash = hash; self.desktopOnly = desktopOnly
    }
    public var bytes: Data? {
        if let dataUrl, let comma = dataUrl.firstIndex(of: ",") { return Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...])) }
        return text.map { Data($0.utf8) }
    }
}
public actor AttachmentImporter {
    public init() {}
    public func read(_ url: URL) throws -> ChatAttachment {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_500_000 else { throw ClientError.server("附件不能超过图片 1.5 MB / 文本 200 KB 的限制") }
        return try prepare(Data(contentsOf: url), name: url.lastPathComponent, mime: type?.preferredMIMEType ?? "application/octet-stream")
    }
    public func prepare(_ data: Data, name: String, mime: String) throws -> ChatAttachment {
        let mime = mime.lowercased(), ext = (name as NSString).pathExtension.lowercased()
        guard mime != "image/svg+xml", ext != "svg" else { throw ClientError.server("不接受 SVG 附件") }
        if mime.hasPrefix("image/") {
            guard data.count <= 1_500_000 else { throw ClientError.server("\(name) 超过 1.5 MB") }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw ClientError.server("无法读取图片") }
            return ChatAttachment(name: name, mime: mime, kind: "image", dataUrl: "data:\(mime);base64," + data.base64EncodedString(), hash: SyncWire.sha(data))
        }
        guard mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime) || ["txt", "md", "json", "csv", "log", "xml", "yaml", "yml"].contains(ext) else { throw ClientError.server("\(name) 不是图片或文本") }
        guard data.count <= 200_000 else { throw ClientError.server("\(name) 超过 200 KB") }
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.server("文本附件需要 UTF-8 编码") }
        return ChatAttachment(name: name, mime: mime, kind: "text", text: text, hash: SyncWire.sha(data))
    }
    /// Camera pixels cross into this actor without UIKit objects or capture metadata.
    /// Normalize orientation and size here, leaving the UI free while encoding.
    public func prepareCameraPhoto(_ image: CGImage, orientation: UInt32, name: String) throws -> ChatAttachment {
        guard (1...8).contains(orientation) else { throw ClientError.server("无法识别照片方向") }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let context = CIContext(options: [.cacheIntermediates: false])
        for maxSide in [2560.0, 1920.0, 1280.0] {
            let scale = min(1, maxSide / max(oriented.extent.width, oriented.extent.height))
            let resized = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let raster = context.createCGImage(resized, from: resized.extent.integral) else { throw ClientError.server("无法处理拍摄的照片") }
            for quality in [0.85, 0.65, 0.45] {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ClientError.server("照片编码失败") }
                CGImageDestinationAddImage(destination, raster, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ClientError.server("照片编码失败") }
                if data.length <= 1_500_000 { return try prepare(data as Data, name: name, mime: "image/jpeg") }
            }
        }
        throw ClientError.server("照片压缩后仍超过 1.5 MB，请从图库选择较小的图片")
    }
    public static func assertCount(_ current: Int, adding: Int) throws { guard current + adding <= 4 else { throw ClientError.server("最多 4 个附件") } }
}
public struct APIContentPart: Codable, Sendable, Equatable {
    public struct ImageURL: Codable, Sendable, Equatable { public var url: String }
    public var type: String
    public var text: String?
    public var image_url: ImageURL?
    public static func text(_ value: String) -> Self { Self(type: "text", text: value) }
    public static func image(_ value: String) -> Self { Self(type: "image_url", image_url: ImageURL(url: value)) }
}
public enum AttachmentContext {
    public static func parts(text: String, attachments: [ChatAttachment]) -> [APIContentPart] {
        let active = attachments.filter { $0.desktopOnly != true && ($0.kind == "image" ? ($0.bytes?.count ?? Int.max) <= 1_500_000 : ($0.text?.utf8.count ?? Int.max) <= 200_000) }
        let blocks = [text.trimmingCharacters(in: .whitespacesAndNewlines)] + active.compactMap { a in a.kind == "text" ? a.text.map { "附件 \(a.name):\n\($0)" } : nil }
        let merged = blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (merged.isEmpty ? [] : [.text(merged)]) + active.compactMap { $0.kind == "image" ? $0.dataUrl.map(APIContentPart.image) : nil }
    }
}
