import Foundation
import Testing
@testable import VChatCore

struct TopicMigrationTests {
    @Test func jevLabelsPreservePayloadAndLegacy() {
        for (field,title) in [("JEV:「始」请用 '天气' 完成 {联网搜索}「末」","天气"),("JEV:「始」{联网搜索}「末」","联网搜索"),("JEV:「始」看看窗外「末」","JEV 请求"),("tool_name:「始」传统工具「末」","传统工具")] {
            let segments = VCPMarkup.parse("<<<[TOOL_REQUEST]>>>\n"+field+"\n<<<[END_TOOL_REQUEST]>>>")
            guard case .tool(let name,_,let body,true) = segments.first else { Issue.record("missing tool"); return }
            #expect(name == title); #expect(body.contains(field))
        }
    }

    @Test(arguments: ["agent", "group"]) func forkIncludesAnchorWithoutCopyingFutureOrSending(_ ownerType: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await ChatStore.open(path: dir.appendingPathComponent("db").path)
        let source = ChatTopic(ownerType: ownerType, ownerId: "owner", title: "原路线")
        try await store.put(source, kind: "topic", id: source.id)
        let first = StoredMessage(topicID: source.id, role: "user", content: "问题", status: "pending", createdAt: 17)
        let anchor = StoredMessage(topicID: source.id, agentID: "speaker", authorName: "甲", role: "assistant", content: "回答", reasoning: "理由", createdAt: 17, attachments: [.init(name: "a.txt",mime: "text/plain",kind: "text",text: "abc")])
        let future = StoredMessage(topicID: source.id, role: "user", content: "后续", createdAt: 17)
        try await store.enqueue(first); try await store.save(anchor); try await store.save(future)
        let copy = try await store.branchTopic(at: anchor)
        let history = try await store.messages(topicID: copy.id)
        #expect(copy.ownerId == source.ownerId && copy.ownerType == ownerType)
        #expect(copy.turnIndex == (ownerType == "group" ? 1 : 0))
        #expect(history.map(\.content) == ["问题","回答"]); #expect(history[0].status != "pending")
        var expected = anchor; expected.id = history[1].id; expected.topicID = copy.id
        #expect(history[1] == expected && history[1].id != anchor.id)
        try await store.removeMessage(history[1].id)
        #expect(try await store.messages(topicID: source.id) == [first, anchor, future])
        #expect(try await store.pending() == 1)
    }
    @Test func localMemoIndexAndPointRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await ChatStore.open(path: dir.appendingPathComponent("db").path)
        let agent = VCPAgent(id: "owner",name: "测试")
        try await store.put(agent, kind: "agent", id: agent.id)
        for (id,owner) in [("topic","owner"),("other","someone")] {
            try await store.put(ChatTopic(id: id,ownerId: owner),kind: "topic",id: id)
        }
        for (i,s) in ["first","Swift Array<Int> 🐈","THIRD"].enumerated() {
            try await store.save(.init(topicID: "topic",role: "user",content: s,createdAt: Double(i)))
        }
        var policy = TopicToolPolicy(); policy.memo = true; policy.readableAgents = ["owner"]
        func call(_ command: String,_ extra: [String:JSONValue] = [:]) async throws -> JSONValue {
            let args: [String:JSONValue] = ["topic_id": .string("topic"),"agentId": .string("owner")]
            return try await store.executeTopicTool(command,arguments: .object(args.merging(extra) { _,new in new }),requestID: "",policy: policy).value
        }
        let outline = try await call("OutlineTopic",["limit": .number(2)])
        #expect(outline["outline"].array.map { $0["seq"].number } == [2,3])
        let hits = try await call("SearchTopic",["query": .string("arr.y"),"isRegex": .bool(true)])
        #expect(hits["hits"].array.first?["seq"].number == 2)
        let miss = try await call("SearchTopic",["query": .string("third"),"caseSensitive": .bool(true)])
        #expect(miss["hits"].array.isEmpty)
        let one = try await call("GetTopicContent",["startSeq": .number(2),"endSeq": .number(3),"limit": .number(1)])
        #expect(one["messages"].array.first?["content"].text == "Swift Array<Int> 🐈"); #expect(one["next_offset"].number == 1)
        let next = try await call("GetTopicContent",["startSeq": .number(2),"endSeq": .number(3),"offset": .number(1)])
        #expect(next["messages"].array.first?["seq"].number == 3); #expect(next["next_offset"] == .null)
        let legacy = try await call("GetTopicContent",["limit": .number(1)])
        #expect(legacy["messages"].array.first?["content"].text == "first")
        await #expect(throws: (any Error).self) { try await call("SearchTopic",["topic_id": .string("other"),"query": .string("third")]) }
    }
}
