import Foundation
import JavaScriptCore

public struct RegexRule: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var title = ""
    public var findPattern = ""
    public var replaceWith = ""
    public var enabled = true
    public var applyToRoles = ["assistant"]
    public var applyToFrontend = true
    public var applyToContext = false
    public var minDepth = 0
    public var maxDepth = -1
    public init() {}
}
public enum TurnDepths {
    public static func calculate(_ messages: [StoredMessage]) -> [String: Int] {
        var result: [String: Int] = [:], depth = 0, index = messages.count - 1
        while index >= 0 {
            result[messages[index].id] = depth
            if messages[index].role == "assistant", index > 0, messages[index - 1].role == "user" { index -= 1; result[messages[index].id] = depth }
            index -= 1; depth += 1
        }
        return result
    }
}
/// Preserve JavaScript regex/replacement semantics used by VChat and SillyTavern.
/// JSCore has no DOM or network access; all execution is isolated from the UI actor.
public actor RegexEngine {
    public static let shared = RegexEngine()
    private var context: JSContext?
    public init() {}
    private func call(_ name: String, _ arguments: [Any]) throws -> JSValue {
        if context == nil {
            context = JSContext()
            context?.evaluateScript(#"""
            function vcpCompile(p) { const m=p.match(/^\/([\s\S]*)\/([dgimsuvy]*)$/); return m?new RegExp(m[1],m[2]):new RegExp(p,'g'); }
            function vcpValidate(p) { vcpCompile(p); return true; }
            function vcpReplace(t,p,r) { return t.replace(vcpCompile(p),r); }
            """#)
        }
        guard let context else { throw ClientError.server("无法启动正则引擎") }
        context.exception = nil
        let result = context.objectForKeyedSubscript(name)?.call(withArguments: arguments)
        if let error = context.exception { let detail = error.toString() ?? "表达式无效"; context.exception = nil; throw ClientError.server(detail) }
        guard let result, !result.isUndefined else { throw ClientError.server("正则处理失败") }
        return result
    }
    public func validate(_ pattern: String) throws { _ = try call("vcpValidate", [pattern]) }
    public func apply(_ text: String, rules: [RegexRule], scope: String, role: String, depth: Int = 0) throws -> String {
        var text = text
        for rule in rules where rule.enabled && rule.applyToRoles.contains(role) && (scope == "frontend" ? rule.applyToFrontend : rule.applyToContext) && (rule.minDepth < 0 || depth >= rule.minDepth) && (rule.maxDepth < 0 || depth <= rule.maxDepth) {
            do { text = try call("vcpReplace", [text, rule.findPattern, rule.replaceWith]).toString() ?? text }
            catch { throw ClientError.server("「\(rule.title)」：\(error.localizedDescription)") }
        }
        return text
    }
    public func importFile(_ url: URL) throws -> [RegexRule] {
        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try importData(Data(contentsOf: url))
    }
    public func importData(_ data: Data) throws -> [RegexRule] {
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let values = (object as? [Any]) ?? [object]
        return try values.map { value in
            guard let value = value as? [String: Any] else { throw ClientError.server("请选择 VChat 或 SillyTavern 正则 JSON") }
            let st = value["scriptName"] is String
            var rule = RegexRule()
            rule.title = (value[st ? "scriptName" : "title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            rule.findPattern = value[st ? "findRegex" : "findPattern"] as? String ?? ""
            guard !rule.title.isEmpty, !rule.findPattern.isEmpty else { throw ClientError.server("规则缺少名称或查找表达式") }
            do { try validate(rule.findPattern) } catch { throw ClientError.server("「\(rule.title)」表达式无效：\(error.localizedDescription)") }
            rule.replaceWith = value[st ? "replaceString" : "replaceWith"] as? String ?? ""
            if st { rule.applyToRoles = (value["placement"] as? [Int] ?? []).compactMap { $0 == 1 ? "user" : $0 == 2 ? "assistant" : nil } }
            else { rule.applyToRoles = (value["applyToRoles"] as? [String] ?? ["assistant"]).filter { ["user", "assistant"].contains($0) } }
            rule.applyToFrontend = value[st ? "markdownOnly" : "applyToFrontend"] as? Bool ?? true
            rule.applyToContext = value[st ? "promptOnly" : "applyToContext"] as? Bool ?? false
            rule.minDepth = value["minDepth"] as? Int ?? 0; rule.maxDepth = value["maxDepth"] as? Int ?? -1
            rule.enabled = (value["enabled"] as? Bool) != false && (value["disabled"] as? Bool) != true
            return rule
        }
    }
}
