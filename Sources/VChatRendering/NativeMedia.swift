import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VChatCore
public struct MessageMedia: Sendable,Equatable,Identifiable {
    public var source: String; public var caption: String; public var kind: String
    public var id: String { kind + "\0" + source }
    public init?(source: String,caption: String = "",videoOnly: Bool = false) {
        guard Self.isSafe(source) else { return nil }; let video = Self.isVideo(source)
        if videoOnly && !video { return nil }; self.source = source; self.caption = caption; kind = video ? "video" : "image"
    }
    public static func isSafe(_ source: String) -> Bool {
        guard !source.unicodeScalars.contains(where: { $0.value < 32 }),source.utf8.count <= 30_000_000 else { return false }
        if source.lowercased().hasPrefix("data:") { return source.range(of: "^data:(?:image/(?!svg)[a-z0-9.+-]+|video/[a-z0-9.+-]+);base64,",options: [.regularExpression,.caseInsensitive]) != nil }
        guard let u = URL(string: source),["http","https"].contains(u.scheme?.lowercased()),u.host != nil,u.user == nil,u.password == nil else { return false }; return true
    }
    public static func isVideo(_ source: String) -> Bool {
        if source.lowercased().hasPrefix("data:video/") { return true }
        return URL(string: source)?.path.range(of: "\\.(mp4|m4v|mov|webm|ogv)$",options: [.regularExpression,.caseInsensitive]) != nil
    }
    static func html(_ raw: String) -> Self? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"(?is)^<(img|video)\b([^>]*)>(?:\s*(?:<source\b[^>]*>\s*)*</video>)?\s*$"#),let match = regex.firstMatch(in: trimmed,range: NSRange(trimmed.startIndex...,in: trimmed)) else { return nil }
        let text = trimmed as NSString,tag = text.substring(with: match.range(at: 1)).lowercased()
        func attribute(_ key: String) -> String {
            guard let r = try? NSRegularExpression(pattern: "(?is)(?:^|\\s)" + key + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#),let m = r.firstMatch(in: trimmed,range: NSRange(trimmed.startIndex...,in: trimmed)) else { return "" }
            for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound { return text.substring(with: m.range(at: i)).replacingOccurrences(of: "&amp;",with: "&") }; return ""
        }
        let src = attribute("src"); guard var result = Self(source: src,caption: attribute("alt")) else { return nil }; if tag == "video" { result.kind = "video" }; return result
    }
}
public struct MediaRaster: Sendable {
    public var image: CGImage; public var animation: Data?
    public var width: Double { Double(image.width) }; public var height: Double { Double(image.height) }
}
public struct VideoResource: Sendable { public var url: URL; var temporary: Bool }
public actor NativeMediaLoader {
    public static let shared = NativeMediaLoader()
    private let http = VCPHTTP(allowingRedirects: false)
    private var cache: [String:MediaRaster] = [:],recent: [String] = []
    private var bytes = 0
    private var temporary: Set<URL> = []
    private let videoCacheDirectory: URL?
    public init(videoCacheDirectory: URL? = nil) { self.videoCacheDirectory = videoCacheDirectory }
    public func image(_ source: String) async throws -> MediaRaster {
        guard MessageMedia.isSafe(source) else { throw ClientError.server("图片地址无效") }
        if let value = cache[source] { recent.removeAll { $0 == source }; recent.append(source); return value }
        let data: Data
        if source.lowercased().hasPrefix("data:") { data = try Self.embedded(source) }
        else { let reply = try await http.response(URL(string: source)!,limit: 20_000_000); guard (200..<300).contains(reply.status) else { throw ClientError.http(reply.status) }; data = reply.data }
        try Task.checkCancellation()
        if let value = cache[source] { return value }
        guard let input = CGImageSourceCreateWithData(data as CFData,nil),let props = CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [CFString:Any],let w = props[kCGImagePropertyPixelWidth] as? Double,let h = props[kCGImagePropertyPixelHeight] as? Double,w > 0,h > 0,w*h <= 60_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(input,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2560,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw ClientError.server("无法读取图片，可打开原链接查看") }
        let animated = CGImageSourceGetCount(input) > 1 && [UTType.gif.identifier,UTType.png.identifier,UTType.webP.identifier].contains(CGImageSourceGetType(input) as String? ?? "")
        let value = MediaRaster(image: image,animation: animated ? data : nil),cost = image.bytesPerRow*image.height + (animated ? data.count : 0)
        while !recent.isEmpty && (recent.count >= 8 || bytes+cost > 32_000_000) { let old = recent.removeFirst(); if let v = cache.removeValue(forKey: old) { bytes -= v.image.bytesPerRow*v.image.height + (v.animation?.count ?? 0) } }
        if cost <= 32_000_000 { cache[source] = value; recent.append(source); bytes += cost }; return value
    }
    public func video(_ source: String) throws -> VideoResource {
        guard MessageMedia.isSafe(source) else { throw ClientError.server("视频地址无效") }
        if !source.lowercased().hasPrefix("data:") { return VideoResource(url: URL(string: source)!,temporary: false) }
        let data = try Self.embedded(source),mime = String(source.dropFirst(5).prefix(while: { $0 != ";" })).lowercased()
        guard mime.hasPrefix("video/") else { throw ClientError.server("视频类型无效") }
        let folder = try videoCacheDirectory ?? FileManager.default.url(for: .cachesDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent((Bundle.main.bundleIdentifier ?? "VChatNative") + "/Media",isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(UTType(mimeType: mime)?.preferredFilenameExtension ?? "mp4")
        try data.write(to: url,options: .atomic); temporary.insert(url); return VideoResource(url: url,temporary: true)
    }
    public func release(_ resource: VideoResource) { if resource.temporary,temporary.remove(resource.url) != nil { try? FileManager.default.removeItem(at: resource.url) } }
    private static func embedded(_ source: String) throws -> Data {
        guard let comma = source.firstIndex(of: ","),let data = Data(base64Encoded: String(source[source.index(after: comma)...])),data.count <= 20_000_000 else { throw ClientError.server("媒体文件无效或超过 20 MB") }; return data
    }
}
