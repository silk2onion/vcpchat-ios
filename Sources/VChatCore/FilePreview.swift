import Foundation

public enum FilePreviewContent: Sendable,Equatable {
    case image(Data),text(String),unsupported
}
/// Preview limits belong to the file library, not the model's smaller upload contract.
public actor FilePreviewReader {
    public init() {}
    public func prepare(_ data: Data,mime: String) throws -> FilePreviewContent {
        guard data.count <= 20_000_000 else { throw ClientError.server("文件预览上限 20 MB") }
        let type = mime.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if type.hasPrefix("image/"),type != "image/svg+xml" { return .image(data) }
        if type.hasPrefix("text/") || ["application/json","application/xml"].contains(type) {
            return .text(String(decoding: data,as: UTF8.self))
        }
        return .unsupported
    }
}
