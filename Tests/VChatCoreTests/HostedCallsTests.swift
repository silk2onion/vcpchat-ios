import Foundation
import Testing
@testable import VChatCore

struct HostedCallsTests {
    let batch = "<<<[VCP_TOOL_BATCH_START:1]>>>结果<<<[VCP_TOOL_BATCH_END:1]>>>"
    func frame(_ parts: [JSONValue], complete: Bool = false) throws -> TokenDelta {
        let body: JSONValue = .object(["choices": .array([.object(["index": .number(1), "delta": .object(["content": .string("其他候选")])]), .object([complete ? "message" : "delta": .object(["tool_calls": .array(parts)])])])])
        return try SSEDecoder.decode(body.pretty)
    }
    func part(_ i: Int, _ id: String?, _ fn: String, _ arg: String) -> JSONValue {
        var d: [String: JSONValue] = ["index": .number(Double(i)), "function": .object(["name": .string(fn), "arguments": .string(arg)])]
        if let id { d["id"] = .string(id); d["type"] = .string("function") }
        return .object(d)
    }
    @Test func multiRoundFragmentedAndCompleteCalls() async throws {
        var s = HostedReplyStream()
        try s.append(TokenDelta(text: "A"))
        try s.append(frame([part(1,"b","g","ab"),part(0,"a","v","{")]))
        try s.append(frame([part(0,nil,"cp","}"),part(1,nil,"","c")]))
        let shell = "<<<[ROLE_DIVIDE_USER]>>>\n"+batch+"\n<<<[END_ROLE_DIVIDE_USER]>>>\n"
        try s.append(TokenDelta(text: String(shell.dropLast(3))))
        try s.append(TokenDelta(text: String(shell.suffix(3)) + "B"))
        try s.append(frame([part(0,"c","par","incomplete")]))
        try s.append(frame([part(0,"c","final","{}")],complete:true))
        try s.append(TokenDelta(text: batch+"C")); try s.append(TokenDelta(done:true))
        let segs = try #require(s.snapshot)
        #expect(segs.count == 7 && segs[2] == .receipt(shell) && segs[3] == .text("B"))
        let turns = HostedHistory.replay(segs)
        #expect(turns.map(\.role) == ["assistant","tool","tool","user","assistant","tool","user","assistant"])
        #expect(turns.compactMap(\.toolCallID) == ["a","b","c"])
        #expect(turns[0].toolCalls?.map(\.function.name) == ["vcp","g"])
        #expect(turns[0].toolCalls?.map(\.function.arguments) == ["{}","abc"])
        #expect(turns[4].toolCalls?.first?.function.name == "final")
        #expect(turns[4].toolCalls?.first?.function.arguments == "{}")
        #expect(turns.filter { $0.role == "user" }.map(\.content) == [batch,batch])
        #expect(turns.filter { $0.role == "assistant" }.map(\.content) == ["A","B","C"])
        let edited = try #require(HostedHistory.edited(segs, from: s.text, to: "新" + s.text.dropFirst()))
        #expect(HostedHistory.replay(edited)[0].content == "新")
    }

    @Test func nativeDiaryProjectionPreservesSchemaAndEmptyReplacement() {
        func diary(_ extra: [String: JSONValue], function: String = "vcptools") -> VCPMarkup.Diary? {
            VCPMarkup.hostedDiary(function: function, arguments: .object(extra.merging(["tool_name": .string(" DailyNote ")]) { a,_ in a }))
        }
        let note = diary(["content":.string("  **海边**\n第二段"), "valetName":.string("B"), "maid":.string("A"),
                          "fileName":.string("海边手记"), "date":.string("11-26"), "folder":.string("旅行"), "tag":.string("潮位")])
        #expect(note?.content == "  **海边**\n第二段")
        #expect(note?.update == false && note?.agent == "B" && note?.label == "Valet")
        #expect(note?.title == "海边手记" && note?.date == "11-26" && note?.folder == "旅行" && note?.tag == "潮位")
        let edit = diary(["target":.string("旧段落"), "replace":.string("")])
        #expect(edit?.update == true && edit?.target == "旧段落" && edit?.replacement == "")
        #expect(diary(["command":.string("update"), "target":.string("old")]) == nil)
        #expect(diary(["command":.string("read"), "Content":.string("x")]) == nil)
        #expect(diary(["Content":.string("   ")]) == nil)
        #expect(diary(["Content":.string("x")], function:"external") == nil)
        #expect(diary(["tool_name":.string("Calendar"), "Content":.string("x")]) == nil)
    }
    @Test func continuedReceiptAndProseKeepTheirBoundaries() throws {
        var partial = HostedReplyStream()
        try partial.append(frame([part(0,"q","lookup","{}")],complete:true))
        let half = String(batch.dropLast(2)), end = String(batch.suffix(2))
        try partial.append(TokenDelta(text:half))
        let p = try #require(partial.snapshot)
        var continued = HostedReplyStream(prefix:half,segments:p)
        try continued.append(TokenDelta(text:end+"后续"))
        let result = try #require(continued.snapshot)
        #expect(result == HostedHistory.joining(p,text:half,tail:nil,suffix:end+"后续"))
        #expect(HostedHistory.replay(result).map(\.role) == ["assistant","tool","user","assistant"])
        var next = HostedReplyStream(prefix:continued.text,segments:result)
        try next.append(TokenDelta(text:"正文"))
        #expect(next.snapshot?.last == .text("后续正文"))
    }
    @Test func orphanInvalidAndOrdinaryProse() throws {
        var s = HostedReplyStream()
        try s.append(TokenDelta(text:"前文"))
        try s.append(frame([part(0,"a","x","{}")],complete:true))
        let prefix = try #require(s.snapshot)
        for tail in ["", "<<<[VCP_TOOL_BATCH_START:1]>>>", "<<<[VCP_TOOL_BATCH_START:1]>>>内容<<<[VCP_TOOL_BATCH_END:2]>>>", "<<<[ROLE_DIVIDE_USER]>>>"+batch,"<<<[ROLE_DIVIDE_USER]>>>"+batch+"<<<[END_ROLE_DIVIDE_USER]>>>oops"] {
            #expect(HostedHistory.replay(prefix + [.text(tail)]) == [ChatTurn(role:"assistant",content:"前文")])
        }
        #expect(HostedHistory.replay(prefix + [.text("正常正文")]).map(\.content) == ["前文","正常正文"])
        for calls in [[part(0,"a","f","{}"),part(1,"a","g","{}")],[part(0,"a","f","")]] {
            var no = HostedReplyStream(); try no.append(frame(calls,complete:true)); #expect(no.snapshot == nil)
        }
        var plain = HostedReplyStream()
        try plain.append(TokenDelta(text:"原来的工具文本")); #expect(plain.snapshot == nil)
    }
    @Test func backgroundJSONPersistsAndReplaysCallWithoutProse() async throws {
        let msg = #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call-9","type":"function","function":{"name":"lookup","arguments":"{}"}}]}}]}"#
        let response = try FinishedReply(data:Data(msg.utf8))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let path = dir.appendingPathComponent("chat.sqlite").path
        let store = try await ChatStore.open(path:path)
        let m = StoredMessage(topicID:"t",role:"assistant",content:"",status:"connecting")
        try await store.save(m)
        let job = BackgroundReplyJob(messageID:m.id,topicID:"t",userID:nil)
        try await store.registerBackgroundReply(job)
        _ = try await store.finishBackgroundReply(job, reply:response)
        let another = try await ChatStore.open(path:path)
        var saved = try #require(try await another.messages(topicID:"t").first)
        #expect(saved.assistantSegments == response.segments && saved.assistantSegments != nil)
        #expect(HostedHistory.replay(saved.assistantSegments ?? []).isEmpty)
        saved.assistantSegments = HostedHistory.joining(saved.assistantSegments,text:saved.content,tail:nil,suffix:batch)
        saved.content += batch
        let request = try await ConversationBuilder().request(configuration:.init(model:"test"),apiKey:"fixture",profile:.init(),agent:.init(),group:nil,messages:[saved])
        let body = try JSONDecoder().decode(JSONValue.self,from: #require(try request.urlRequest(streaming:true).httpBody))
        let turns = body["messages"].array.filter { $0["role"].text != "system" }
        #expect(turns.count == 3)
        #expect(turns[0].object["content"] == .null && turns[0]["tool_calls"].array.first?["id"].text == "call-9")
        #expect(turns[1]["tool_call_id"].text == "call-9" && turns[2]["content"].text == batch)
    }
}
