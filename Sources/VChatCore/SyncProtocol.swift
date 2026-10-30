import Foundation
import CryptoKit

/// Wire 1.5 canonical data; adapted from VCPChat's mobile-sync protocol.
public enum SyncWire {
    public static func fail(_ message: String) -> ClientError { .server(message) }
    public static func object(_ value: JSONValue) throws -> [String:JSONValue] { guard case .object(let v) = value else { throw fail("同步响应对象无效") }; return v }
    public static func rows(_ value: JSONValue) throws -> [JSONValue] { guard case .array(let v) = value else { throw fail("同步响应缺少列表") }; for row in v { _ = try object(row) }; return v }
    public static func time(_ value: JSONValue) throws -> Double { guard let n = value.number,n.isFinite,n >= 0,n <= 9_007_199_254_740_991,n.rounded() == n else { throw fail("同步版本时间无效") }; return n }
    public static func integer(_ value: JSONValue) throws -> Double {
        if case .string(let v) = value {
            guard v.range(of: "^(0|[1-9][0-9]*)$",options: .regularExpression) != nil,let integer = UInt64(v),integer <= 9_007_199_254_740_991 else { throw fail("同步整数无效") }; return Double(integer)
        }; return try time(value)
    }
    public static func milliseconds(_ seconds: Double) -> Double { (seconds * 1000).rounded() }
    public static var now: Double { milliseconds(Date().timeIntervalSince1970) }
    public static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined() }
    public static func hash(_ value: JSONValue) -> String { sha(Data(stable(value).utf8)) }
    public static func stable(_ value: JSONValue,key: String = "") -> String {
        switch value {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .string(let v): let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]; return String(decoding: try! e.encode(v),as: UTF8.self)
        case .array(let v): return "[" + v.map { stable($0) }.joined(separator: ",") + "]"
        case .object(let v): return "{" + v.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { stable(.string($0)) + ":" + stable(v[$0]!,key: $0) }.joined(separator: ",") + "}"
        case .number(let n):
            guard n.isFinite else { return "null" }; if n == 0 { return key == "temperature" ? "0.0" : "0" }
            if key == "temperature",n.rounded() == n,abs(n) < 1e21 { return integerDigits(n) + ".0" }
            return number(n)
        }
    }
    /// toFixed(1) prints the exact binary integer, not its shortest-roundtrip alias.
    private static func integerDigits(_ n: Double) -> String {
        let bits = abs(n).bitPattern,exponent = Int((bits >> 52) & 2047)-1023,significand = (bits & 0x000f_ffff_ffff_ffff) | (1 << 52)
        let sign = n < 0 ? "-" : ""
        if exponent <= 52 { return sign + String(significand >> (52-exponent)) }
        var digits = String(significand).reversed().map { Int(String($0))! }
        for _ in 0..<(exponent-52) {
            var carry = 0
            for i in digits.indices { let v = digits[i]*2+carry; digits[i] = v%10; carry = v/10 }
            if carry > 0 { digits.append(carry) }
        }
        return sign + digits.reversed().map(String.init).joined()
    }
    /// Swift's shortest-roundtrip decimal, expressed using ECMAScript's exponent thresholds.
    private static func number(_ n: Double) -> String {
        let negative = n < 0, raw = String(abs(n)).lowercased().split(separator: "e").map(String.init)
        let parts = raw[0].split(separator: ".",omittingEmptySubsequences: false).map(String.init)
        var digits = parts.joined(), point = parts[0].count + (raw.count == 2 ? Int(raw[1])! : 0)
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let sign = negative ? "-" : ""
        if abs(n) >= 1e-6 && abs(n) < 1e21 {
            if point <= 0 { return sign + "0." + String(repeating: "0",count: -point) + digits }
            if point >= digits.count { return sign + digits + String(repeating: "0",count: point-digits.count) }
            let i = digits.index(digits.startIndex,offsetBy: point); return sign + digits[..<i] + "." + digits[i...]
        }
        return sign + String(digits.prefix(1)) + (digits.count > 1 ? "." + digits.dropFirst() : "") + "e" + (point-1 >= 0 ? "+" : "") + String(point-1)
    }
    public static let agentFields = ["name","systemPrompt","model","temperature","contextTokenLimit","maxOutputTokens","streamOutput"]
    public static let groupFields = ["name","members","mode","memberTags","groupPrompt","invitePrompt","useUnifiedModel","unifiedModel","enableContextMessageWindow","contextMessageWindowSize","tagMatchMode","createdAt"]
    public static func dtoHash(_ data: JSONValue,identity: SyncIdentity) -> String {
        let fields = identity.entityType == "owner" ? (identity.ownerType == "agent" ? agentFields : groupFields) : (identity.ownerType == "agent" ? ["id","name","createdAt","locked","unread"] : ["id","name","createdAt"])
        var filtered = data.object.filter { fields.contains($0.key) && $0.value != .null }
        if let n = filtered["temperature"]?.number { filtered["temperature"] = .number(floor(n*100+0.5)/100) }
        return hash(.object(filtered))
    }
    public static func fingerprint(_ m: JSONValue) -> String {
        var v: [String:JSONValue] = ["id":m["id"],"role":m["role"],"content":m["content"],"timestamp":m["timestamp"]]
        for k in ["name","agentId"] { if case .string = m[k] { v[k] = m[k] } }
        let hashes = m["attachments"].array.map { $0["hash"].text.isEmpty ? $0["_fileManagerData"]["hash"].text : $0["hash"].text }.filter { !$0.isEmpty }.sorted()
        if !hashes.isEmpty { v["attachmentHashes"] = .array(hashes.map(JSONValue.string)) }; return hash(.object(v))
    }
    public static func aggregate(_ hashes: [String]) -> String { hashes.isEmpty ? "" : sha(Data(hashes.sorted().joined().utf8)) }
    public static func message(_ raw: JSONValue,topic: String,warnings: inout Int) throws -> JSONValue {
        _ = try object(raw); let id = raw["id"].text, role = raw["role"].text
        guard case .string = raw["id"],!id.isEmpty,case .string = raw["role"],!role.isEmpty,raw["status"].text != "removed",raw["deletedAt"] == .null else { throw fail("同步消息身份或删除状态无效") }
        var out: [String:JSONValue] = ["id":.string(id),"role":.string(role),"timestamp":.number(try integer(raw["timestamp"]))]
        if raw["content"] == .null { out["content"] = .string("") } else { guard case .string = raw["content"] else { throw fail("同步正文必须为文字") }; out["content"] = raw["content"] }
        if let at = try? time(raw["updatedAt"]) { out["updatedAt"] = .number(at) }
        for k in ["name","agentId","groupId","topicId","finishReason"] where raw[k] != .null {
            if k == "topicId" { out[k] = .string(topic) }
            else { guard case .string = raw[k] else { throw fail("同步字段 \(k) 无效") }; out[k] = raw[k] }
        }
        if raw["isGroupMessage"] != .null { guard raw["isGroupMessage"].bool != nil else { throw fail("群消息标记无效") }; out["isGroupMessage"] = raw["isGroupMessage"] }
        if raw["attachments"] != .null {
            guard case .array(let rows) = raw["attachments"] else { throw fail("同步附件列表无效") }
            var attachments: [JSONValue] = []
            for a in rows {
                let v = try object(a), nested = a["_fileManagerData"]
                if nested != .null,case .object = nested {} else if nested != .null { warnings += 1; continue }
                func shaField(_ value: JSONValue) -> String? { let s = value.text; return s.range(of: "^[a-fA-F0-9]{64}$",options: .regularExpression) != nil ? s.lowercased() : nil }
                let top = shaField(a["hash"]), inner = shaField(nested["hash"])
                guard let h = top ?? inner,top == nil || inner == nil || top == inner else { warnings += 1; continue }
                var row: [String:JSONValue] = ["type":.string(a["type"].text),"name":.string(v["name"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "unnamed"),"hash":.string(h),"size":.number(a["size"] == .null ? 0 : try integer(a["size"]))]
                for key in ["extractedText","imageFrames","createdAt"] {
                    let val = v[key] ?? nested[key]; if val == .null { continue }
                    if key == "createdAt" { row[key] = .number(try integer(val)) }
                    else if key == "imageFrames" { guard case .array(let items) = val,items.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw fail("附件帧列表无效") }; row[key] = val }
                    else { guard case .string = val else { throw fail("附件文字无效") }; row[key] = val }
                }; attachments.append(.object(row))
            }; if !attachments.isEmpty { out["attachments"] = .array(attachments) }
        }; return .object(out)
    }
}
public struct SyncIdentity: Codable, Sendable, Equatable, Hashable {
    public var entityType: String; public var ownerType: String; public var ownerId: String; public var topicId: String?
    public init(entityType: String,ownerType: String,ownerId: String,topicId: String? = nil) { self.entityType = entityType; self.ownerType = ownerType; self.ownerId = ownerId; self.topicId = topicId }
    public init(_ raw: JSONValue,kind: String) throws {
        guard ["agent","group"].contains(raw["ownerType"].text),case .string = raw["ownerId"],!raw["ownerId"].text.isEmpty,kind != "topic" || (raw["topicId"].text != "" && raw["topicId"].text.utf8.count > 0) else { throw SyncWire.fail("同步返回身份不完整") }
        self.init(entityType: kind,ownerType: raw["ownerType"].text,ownerId: raw["ownerId"].text,topicId: kind == "topic" ? raw["topicId"].text : nil)
    }
    public var key: String { ([entityType,ownerType,ownerId] + (entityType == "topic" ? [topicId ?? ""] : [])).joined(separator: "\0") }
    public var topicKey: String { [ownerType,ownerId,topicId ?? ""].joined(separator: "\0") }
    public var owner: SyncIdentity { .init(entityType: "owner",ownerType: ownerType,ownerId: ownerId) }
    public var json: [String:JSONValue] { var v: [String:JSONValue] = ["entityType":.string(entityType),"ownerType":.string(ownerType),"ownerId":.string(ownerId)]; if let topicId { v["topicId"] = .string(topicId) }; return v }
}
/// Reject duplicate object keys before JSONDecoder can silently discard them.
public enum StrictJSON {
    public static func decode(_ data: Data) throws -> JSONValue {
        var scan = Scanner(bytes: Array(data)); try scan.value(depth: 0); scan.space(); guard scan.i == scan.bytes.count else { throw SyncWire.fail("同步 JSON 尾部无效") }
        return try JSONDecoder().decode(JSONValue.self,from: data)
    }
    private struct Scanner {
        let bytes: [UInt8]; var i = 0
        mutating func space() { while i < bytes.count,[9,10,13,32].contains(bytes[i]) { i += 1 } }
        mutating func string() throws -> String {
            let start = i; guard i < bytes.count,bytes[i] == 34 else { throw SyncWire.fail("同步 JSON 字符串无效") }; i += 1
            while i < bytes.count { let b = bytes[i]; i += 1; if b == 92 { guard i < bytes.count else { break }; i += 1 } else if b == 34 { return try JSONDecoder().decode(String.self,from: Data(bytes[start..<i])) } }
            throw SyncWire.fail("同步 JSON 字符串未结束")
        }
        mutating func take(_ b: UInt8) throws { space(); guard i < bytes.count,bytes[i] == b else { throw SyncWire.fail("同步 JSON 结构无效") }; i += 1 }
        mutating func value(depth: Int) throws {
            guard depth < 256 else { throw SyncWire.fail("同步 JSON 嵌套过深") }; space(); guard i < bytes.count else { throw SyncWire.fail("同步 JSON 不完整") }
            switch bytes[i] {
            case 34: _ = try string()
            case 123:
                i += 1; space(); if i < bytes.count,bytes[i] == 125 { i += 1; return }; var keys = Set<String>()
                while true { space(); let k = try string(); guard keys.insert(k).inserted else { throw SyncWire.fail("同步 JSON 存在重复字段：\(k)") }; try take(58); try value(depth: depth+1); space(); if i < bytes.count,bytes[i] == 125 { i += 1; return }; try take(44) }
            case 91:
                i += 1; space(); if i < bytes.count,bytes[i] == 93 { i += 1; return }
                while true { try value(depth: depth+1); space(); if i < bytes.count,bytes[i] == 93 { i += 1; return }; try take(44) }
            default:
                let start = i; while i < bytes.count,![9,10,13,32,44,93,125].contains(bytes[i]) { i += 1 }; guard i > start else { throw SyncWire.fail("同步 JSON 值无效") }
            }
        }
    }
}
