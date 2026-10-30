import Foundation
import VChatCore

public struct RenderOptions: Codable, Sendable, Equatable {
    public var enabled = true
    public var code = true
    public var math = true
    public var mermaid = true
    public var html = true
    public var motion = true
    public var media = true
    public init() {}
}
public struct CodeSpan: Sendable, Equatable {
    public var text: String
    public var color: [Double]?
    public init(text: String, color: [Double]? = nil) { self.text = text; self.color = color }
}
public enum InlineRun: Sendable, Equatable { case text(AttributedString); case math(String) }
public enum RenderBlock: Sendable, Equatable {
    case vcp(VCPMarkup.Segment)
    case literal(String)
    case paragraph([InlineRun])
    case heading(Int, [InlineRun])
    case code(String, String, [CodeSpan])
    case quote([RenderBlock])
    case list([[RenderBlock]], Int?)
    case table([[[InlineRun]]])
    case rule
    case math(String)
}
