import Foundation
import ImageIO
import UniformTypeIdentifiers
public enum MobileSyncMode: String, Sendable { case pull,both }
public struct MobileSyncResult: Sendable { public var profile: SyncProfile; public var after: SyncSnapshot; public var attachmentWarnings: Int }
/// The entire sync state machine and canonicalization live off MainActor.
public actor MobileSync {
    private var running = false
    public init() {}
    public func run(settings: MobileSyncSettings,token: String,mode: MobileSyncMode,profile original: SyncProfile,local: SyncSnapshot,versions: [String:Double] = [:],progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> MobileSyncResult {
        guard !running else { throw SyncWire.fail("同步正在进行") }; running = true
        do {
            guard !token.isEmpty else { throw SyncWire.fail("请填写桌面同步 Token") }
            let endpoint = try MobileSyncSettings.endpoint(settings.httpURL); guard endpoint.absoluteString == original.endpoint else { throw SyncWire.fail("同步来源已改变") }
            var p = original; try p.overlay(local,versions: versions)
            if mode == .pull,p != original { throw SyncWire.fail("此同步来源在本机有改动，请选双向同步；本次未覆盖内容") }
            let channel = SyncChannel(); await channel.open(try MobileSyncSettings.socket(settings.socketURL,token: token))
            let http = SyncHTTP(endpoint: endpoint,token: token)
            do {
                await progress("正在核对同步协议…")
                let version = try await channel.request(.object(["type":.string("VERSION_CHECK"),"versions":.array([.object(["component":.string("mobile_app"),"version":.string("0.2.1")]),.object(["component":.string("wire"),"version":.string("1.5")])])]),expected: "VERSION_ACK")
                let versions = try SyncWire.rows(version["versions"])
                guard versions.count == 2,versions.contains(where: { $0["component"].text == "wire" && $0["version"].text == "1.5" }),versions.contains(where: { $0["component"].text == "desktop_plugin" }),["cds","legacy"].contains(version["backendMode"].text) else { throw SyncWire.fail("桌面同步协议不兼容，需要 Wire 1.5") }
                await progress("正在同步联系人与群组…"); p = try await metadata("owner",profile: p,channel: channel,http: http,mode: mode)
                await progress("正在同步头像…"); p = try await avatars(profile: p,channel: channel,http: http,mode: mode)
                try await channel.send(.object(["type":.string("PHASE_COMPLETED"),"phase":.string("owner_metadata")]))
                await progress("正在同步会话列表…"); p = try await metadata("topic",profile: p,channel: channel,http: http,mode: mode)
                try await channel.send(.object(["type":.string("PHASE_START"),"phase":.string("messages")]))
                let topics = p.entities.values.filter { $0.identity.entityType == "topic" && $0.deletedAt == nil && p.entities[$0.identity.owner.key]?.deletedAt == nil && p.entities[$0.identity.owner.key] != nil }.sorted { $0.identity.key < $1.identity.key }
                var warningCount = 0
                for (index,e) in topics.enumerated() {
                    try Task.checkCancellation(); await progress("正在同步消息 \(index+1)/\(topics.count)…")
                    let id = e.identity,key = id.topicKey; var manifest: [String:JSONValue] = [:]
                    for m in p.messages[key] ?? [] { manifest[m["id"].text] = .object(["messageHash":m["contentHash"],"updatedAt":m["updatedAt"]]) }
                    for (mid,at) in p.messageDeletes[key] ?? [:] { manifest[mid] = .object(["deletedAt":.number(at)]) }
                    var request = id.json; request.removeValue(forKey: "entityType"); request["contentHash"] = .string(e.contentHash); request["messages"] = .object(manifest)
                    let response = try await channel.request(.object(["type":.string("SYNC_MESSAGE_DIFF_REQUEST"),"topics":.array([.object(request)])]),expected: "SYNC_MESSAGE_DIFF_RESULT")
                    let results = try SyncWire.rows(response["results"])
                    guard results.count == 1,try SyncIdentity(results[0],kind: "topic") == id,results[0]["ok"].bool == true else { throw SyncWire.fail("消息差分身份或状态无效") }
                    let diff = results[0]; guard case .array(let rawWanted) = diff["pullMessageIds"],rawWanted.allSatisfy({ if case .string(let v) = $0 { !v.isEmpty } else { false } }) else { throw SyncWire.fail("消息差分格式无效") }
                    let wanted = Set(rawWanted.map(\.text)); guard wanted.count == rawWanted.count else { throw SyncWire.fail("消息差分有重复身份") }
                    if !wanted.isEmpty {
                        var req = id.json; req.removeValue(forKey: "entityType"); req["messageIds"] = .array(rawWanted)
                        let frames = try await http.ndjson("/messages/pull",.object(["topics":.array([.object(req)])]))
                        guard frames.count == 1,frames[0]["kind"].text == "topic",try SyncIdentity(frames[0],kind: "topic") == id else { throw SyncWire.fail("消息返回身份不符") }
                        let raw = frames[0]; var upstreamWarnings = 0
                        if raw["legacyAttachmentWarnings"] != .null { upstreamWarnings = Int(try SyncWire.integer(raw["legacyAttachmentWarnings"])); guard raw["warningSamples"] == .null || { if case .array(let a) = raw["warningSamples"] { return a.allSatisfy { if case .string = $0 { true } else { false } } }; return false }() else { throw SyncWire.fail("附件告警列表无效") } }
                        var seen = Set<String>(),received: [JSONValue] = []; warningCount += upstreamWarnings
                        for r in try SyncWire.rows(raw["messages"]) {
                            var m = try SyncWire.message(r,topic: id.topicId!,warnings: &warningCount).object
                            let mid = m["id"]!.text; guard seen.insert(mid).inserted,wanted.contains(mid),r["contentHash"].text == SyncWire.fingerprint(.object(m)) else { throw SyncWire.fail("消息指纹或身份校验失败") }
                            m["updatedAt"] = .number(try SyncWire.time(r["updatedAt"])); m["contentHash"] = r["contentHash"]
                            if let old = p.messages[key]?.first(where: { $0["id"].text == mid }),old["localId"] != .null { m["localId"] = old["localId"] }
                            received.append(.object(m)); p.messageDeletes[key]?.removeValue(forKey: mid)
                        }
                        guard seen == wanted else { throw SyncWire.fail("消息返回不完整") }
                        p.messages[key] = ((p.messages[key] ?? []).filter { !wanted.contains($0["id"].text) } + received).sorted { ($0["timestamp"].number ?? 0,$0["id"].text) < ($1["timestamp"].number ?? 0,$1["id"].text) }
                    }
                    for deletion in try SyncWire.rows(diff["deleteMessages"]) {
                        guard case .string(let mid) = deletion["msgId"],!mid.isEmpty else { throw SyncWire.fail("消息删除记录无效") }
                        p.messageDeletes[key,default: [:]][mid] = try SyncWire.time(deletion["deletedAt"]); p.messages[key]?.removeAll { $0["id"].text == mid }
                    }
                    if diff["pushTopic"].bool == true {
                        guard mode == .both else { throw SyncWire.fail("此会话有待写回消息，请使用双向同步；本机内容已保留") }
                        var frame = id.json; frame.removeValue(forKey: "entityType"); frame["kind"] = .string("topic")
                        frame["messages"] = .array((p.messages[key] ?? []).map { var v = $0.object; v.removeValue(forKey: "localId"); return .object(v) })
                        frame["deletedMessages"] = .array((p.messageDeletes[key] ?? [:]).map { .object(["msgId":.string($0.key),"deletedAt":.number($0.value)]) })
                        var data = try JSONEncoder().encode(JSONValue.object(frame)); data.append(10)
                        let acks = try await http.ndjson("/messages/push",data: data)
                        guard acks.count == 1,acks[0]["kind"].text == "topic",try SyncIdentity(acks[0],kind: "topic") == id else { throw SyncWire.fail("消息写回未确认") }
                    } else if diff["pushTopic"].bool != false { throw SyncWire.fail("消息写回状态无效") }
                }
                let session = SyncWire.now,nonce = UUID().uuidString
                let ack = try await channel.request(.object(["type":.string("PHASE_COMPLETED"),"phase":.string("messages"),"sessionId":.number(session),"attemptId":.number(1),"nonce":.string(nonce)]),expected: "PHASE_ACK")
                guard ack["phase"].text == "messages",ack["sessionId"].number == session,ack["attemptId"].number == 1,ack["nonce"].text == nonce else { throw SyncWire.fail("同步最终确认不匹配，未写入本机") }
                try Task.checkCancellation(); p.refreshRoots(); p.lastSync = SyncWire.now; let result = MobileSyncResult(profile: p,after: p.toLocal(extras: local),attachmentWarnings: warningCount)
                await channel.close(); running = false; return result
            } catch { await channel.close(); throw error }
        } catch { running = false; throw error }
    }
    private func metadata(_ kind: String,profile: SyncProfile,channel: SyncChannel,http: SyncHTTP,mode: MobileSyncMode) async throws -> SyncProfile {
        var p = profile; let phase = kind == "owner" ? "owner_metadata" : "topic_metadata"
        try await channel.send(.object(["type":.string("PHASE_START"),"phase":.string(phase)]))
        let owners = p.entities.values.filter { $0.identity.entityType == "owner" && $0.deletedAt == nil }.map(\.identity)
        let items = p.entities.values.filter { $0.identity.entityType == kind && (kind == "owner" || owners.contains($0.identity.owner)) }.sorted { $0.identity.key < $1.identity.key }.map(\.manifest)
        var manifest: [String:JSONValue] = ["type":.string("SYNC_MANIFEST_REQUEST"),"manifestType":.string(kind),"items":.array(items)]
        if kind == "topic" { manifest["targetedOwners"] = .array(owners.map { .object(["ownerType":.string($0.ownerType),"ownerId":.string($0.ownerId)]) }) }
        let response = try await channel.request(.object(manifest),expected: "SYNC_MANIFEST_RESULT"); guard response["manifestType"].text == kind else { throw SyncWire.fail("同步清单类型不符") }
        var seen = Set<String>(),pulls: [SyncIdentity] = [],pushes: [SyncEntity] = []
        for action in try SyncWire.rows(response["results"]) {
            let id = try SyncIdentity(action,kind: kind); guard seen.insert(id.key).inserted,kind != "topic" || owners.contains(id.owner) else { throw SyncWire.fail("同步清单重复或超出来源范围") }; let e = p.entities[id.key]
            switch action["action"].text {
            case "PULL": pulls.append(id)
            case "PUSH": guard mode == .both,let e,e.deletedAt == nil else { throw SyncWire.fail("桌面缺少本机项，请使用双向同步；本机内容已保留") }; pushes.append(e)
            case "PULL_DELETE": let at = try SyncWire.time(action["deletedAt"]); p.entities[id.key]?.deletedAt = at
            case "PUSH_DELETE": guard mode == .both,let at = e?.deletedAt else { throw SyncWire.fail("删除写回需要双向同步及本机删除记录") }; var v = id.json; v.removeValue(forKey: "entityType"); v["type"] = .string("SYNC_ENTITY_DELETE"); v["targetType"] = .string(kind); v["deletedAt"] = .number(at); try await channel.send(.object(v))
            case "SKIP": break
            default: throw SyncWire.fail("桌面返回未知同步动作")
            }
        }
        for offset in stride(from: 0,to: pulls.count,by: 40) {
            let wanted = Array(pulls[offset..<min(offset+40,pulls.count)]); let result = try await http.json("/entities/pull",.object(["items":.array(wanted.map { .object($0.json) })]))
            let rows = try SyncWire.rows(result["results"]); var remaining = Set(wanted)
            guard rows.count == wanted.count else { throw SyncWire.fail("实体拉取不完整") }
            for row in rows {
                let id = try SyncIdentity(row,kind: kind); guard remaining.remove(id) != nil,row["ok"].bool == true else { throw SyncWire.fail("实体返回身份重复、越界或未成功") }
                _ = try SyncWire.object(row["data"]); var e = SyncEntity(identity: id,data: row["data"],updatedAt: (try? SyncWire.time(row["data"]["updatedAt"])) ?? 0)
                e.localId = p.entities[id.key]?.localId; e.contentHash = p.entities[id.key]?.contentHash ?? ""
                if kind == "topic" { guard row["data"]["configHash"].text == e.configHash else { throw SyncWire.fail("会话版本校验失败，未写入") }; e.updatedAt = try SyncWire.time(row["data"]["updatedAt"]) }
                p.entities[id.key] = e
            }
        }
        for e in pushes {
            var data = e.data.object; if kind == "topic" { data["configHash"] = .string(e.configHash); data["updatedAt"] = .number(e.updatedAt) }
            var item = e.identity.json; item["data"] = .object(data)
            let reply = try await http.json("/entities/push",.object(["items":.array([.object(item)])])); let rows = try SyncWire.rows(reply["results"])
            guard rows.count == 1,rows[0]["ok"].bool == true,try SyncIdentity(rows[0],kind: kind) == e.identity else { throw SyncWire.fail("实体写回未确认") }
        }
        if kind == "topic" { try await channel.send(.object(["type":.string("PHASE_COMPLETED"),"phase":.string(phase)])) }; return p
    }
    private func avatars(profile: SyncProfile,channel: SyncChannel,http: SyncHTTP,mode: MobileSyncMode) async throws -> SyncProfile {
        var p = profile
        let items = p.avatars.values.map { value -> JSONValue in var v = value.object; v.removeValue(forKey: "image"); if v["deletedAt"] != nil { v.removeValue(forKey: "binaryHash"); v.removeValue(forKey: "updatedAt") }; return .object(v) }
        let reply = try await channel.request(.object(["type":.string("SYNC_MANIFEST_REQUEST"),"manifestType":.string("avatar"),"items":.array(items)]),expected: "SYNC_MANIFEST_RESULT")
        guard reply["manifestType"].text == "avatar" else { throw SyncWire.fail("头像清单类型不符") }; var seen = Set<String>()
        for action in try SyncWire.rows(reply["results"]) {
            let type = action["ownerType"].text,id = action["ownerId"].text,key = type + "\0" + id
            guard ["agent","group","user"].contains(type),!id.isEmpty,type != "user" || id == "user_avatar",seen.insert(key).inserted else { throw SyncWire.fail("头像身份重复或无效") }
            var c = URLComponents(); c.queryItems = [URLQueryItem(name: "ownerType",value: type),URLQueryItem(name: "ownerId",value: id)]
            let path = "/avatars/" + (action["action"].text == "PUSH" ? "push" : "pull") + "?" + c.percentEncodedQuery!
            switch action["action"].text {
            case "PULL":
                let reply = try await http.binary(path); guard let source = CGImageSourceCreateWithData(reply.data as CFData,nil),CGImageSourceGetCount(source) > 0,let identifier = CGImageSourceGetType(source),let mime = UTType(identifier as String)?.preferredMIMEType else { throw SyncWire.fail("同步头像不是可识别图片") }
                p.avatars[key] = .object(["ownerType":.string(type),"ownerId":.string(id),"binaryHash":.string(SyncWire.sha(reply.data)),"updatedAt":.number(0),"image":.string("data:\(mime);base64," + reply.data.base64EncodedString())])
            case "PUSH":
                guard mode == .both,let image = p.avatars[key]?["image"].text,let comma = image.firstIndex(of: ","),let bytes = Data(base64Encoded: String(image[image.index(after: comma)...])),bytes.count <= 20_000_000 else { throw SyncWire.fail("头像需要双向同步写回") }
                let mime = String(image.prefix(while: { $0 != ";" }).dropFirst(5)); let ack = try StrictJSON.decode(await http.binary(path,data: bytes,mime: mime).data)
                guard ack["ok"].bool == true,ack["ownerType"].text == type,ack["ownerId"].text == id else { throw SyncWire.fail("头像写回未确认") }
            case "PULL_DELETE": let at = try SyncWire.time(action["deletedAt"]); if var v = p.avatars[key]?.object { v["deletedAt"] = .number(at); v.removeValue(forKey: "image"); p.avatars[key] = .object(v) }
            case "PUSH_DELETE": guard mode == .both,let old = p.avatars[key] else { throw SyncWire.fail("头像删除需要双向同步") }; let at = try SyncWire.time(old["deletedAt"]); try await channel.send(.object(["type":.string("SYNC_ENTITY_DELETE"),"targetType":.string("avatar"),"ownerType":.string(type),"ownerId":.string(id),"deletedAt":.number(at)]))
            case "SKIP": break
            default: throw SyncWire.fail("头像同步动作无效")
            }
        }; return p
    }
}
