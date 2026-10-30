import Foundation
import Testing
@testable import VChatCore

struct DecoderTests {
    @Test func sseFramingAndReasoning() throws {
        var decoder = SSEDecoder()
        let parsed1 = try decoder.line(": heartbeat")
        #expect(parsed1 == nil)
        let parsed2 = try decoder.line("event: message")
        #expect(parsed2 == nil)
        let parsed3 = try decoder.line("data: {\"choices\":[{\"delta\":{\"content\":\"你好🌸\",\"reasoning_content\":\"想一想\"}}]}\r")
        #expect(parsed3 == nil)
        let parsed4 = try decoder.line("\r")
        let value = try #require(parsed4)
        #expect(value.text == "你好🌸")
        #expect(value.reasoning == "想一想")
        #expect(!value.done)
        let parsed5 = try decoder.line("data:[DONE]")
        #expect(parsed5 == nil)
        let final = try decoder.finish()
        #expect(final?.done == true)
    }
    @Test func multilineSSEAndErrors() throws {
        var decoder = SSEDecoder()
        _ = try decoder.line("data: {\"choices\":[")
        _ = try decoder.line("data: {\"delta\":{\"content\":\"代码\"},\"finish_reason\":\"stop\"}]}")
        let parsed6 = try decoder.line("")
        let value = try #require(parsed6)
        #expect(value.text == "代码" && value.done)
        #expect(throws: ClientError.server("quota")) { try SSEDecoder.decode("{\"error\":{\"message\":\"quota\"}}") }
        #expect(throws: (any Error).self) { try SSEDecoder.decode("invalid") }
        #expect(throws: ClientError.tooLarge) { var d = SSEDecoder(); _ = try d.line("data:" + String(repeating: "a", count: 1_000_001)) }
    }
    @Test func byteFramingKeepsEmptyLinesAndCRLF() throws {
        var decoder = SSEByteDecoder()
        let source = "\u{FEFF}data: {\"choices\":[{\"delta\":{\"content\":\"你好🌸\"}}]}\r\n\r\ndata: [DONE]\n\n"
        var deltas: [TokenDelta] = []
        for byte in source.utf8 { if let delta = try decoder.byte(byte) { deltas.append(delta) } }
        #expect(deltas.count == 2)
        #expect(deltas.first?.text == "你好🌸")
        #expect(deltas.last?.done == true)
    }
    @Test func pacerBudgets() {
        var pacer = FramePacer(framesPerSecond: 60)
        let start = ContinuousClock.now
        let ready7 = pacer.ready(at: start)
        #expect(ready7)
        let ready8 = !pacer.ready(at: start + .milliseconds(15))
        #expect(ready8)
        let ready9 = pacer.ready(at: start + .milliseconds(16))
        #expect(ready9)
        #expect(FramePacer(framesPerSecond: 120).interval == .milliseconds(8))
    }
    @Test func endpointNormalization() throws {
        for server in ["https://example.com", "https://example.com/v1", "https://example.com/v1/chat/completions"] {
            #expect(try ConnectionConfiguration(server: server).endpoint("v1/models").absoluteString == "https://example.com/v1/models")
        }
        #expect(try ConnectionConfiguration(server: "https://example.com/proxy/v1/chat/completions").endpoint("VCPlog").path == "/proxy/VCPlog")
        #expect(throws: ClientError.invalidConfiguration) { try ConnectionConfiguration(server: "https://user:pass@example.com").baseURL() }
    }
    @Test func desktopImportOnlyReadsConnection() throws {
        let data = Data(#"{"vcpServerUrl":"https://example.com/v1/chat/completions","vcpApiKey":"test-only","vcpLogKey":"test-log","fileKey":"not-imported","unrelated":"not-imported"}"#.utf8)
        let imported = try DesktopConnection(data: data)
        #expect(imported.apiKey == "test-only")
        #expect(imported.logKey == "test-log")
        #expect(imported.configuration.model.isEmpty)
        #expect(throws: (any Error).self) { try DesktopConnection(data: Data("{}".utf8)) }
    }
}
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VCHAT_TEST_ARTIFACTS"] != nil))
struct StorageTests {
    @Test func walPersistenceSearchAndRecovery() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["VCHAT_TEST_ARTIFACTS"])
        let url = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let path = url.appendingPathComponent("test.sqlite").path
        let store = try await ChatStore.open(path: path)
        #expect(try await store.journalMode() == "wal")
        var message = StoredMessage(role: "user", content: "原生聊天记录测试 alpha", status: "pending")
        try await store.enqueue(message)
        #expect(try await store.pending() == 1)
        #expect(try await store.search("聊天记录").map(\.id) == [message.id])
        #expect(try await store.search("alpha").count == 1)
        #expect(try await store.search("\" OR *").isEmpty)
        message.content = "内容已经更新 beta"
        try await store.save(message)
        #expect(try await store.search("alpha").isEmpty)
        #expect(try await store.search("已经更新").count == 1)
        try await store.markSent(message.id)
        #expect(try await store.pending() == 0)
        #expect(try await store.messages().first?.status == "complete")
        let partial = StoredMessage(role: "assistant", content: "未完成但保留", status: "streaming")
        try await store.save(partial)
        let reopened = try await ChatStore.open(path: path)
        try await reopened.recoverInterrupted()
        #expect(try await reopened.messages().last?.status == "interrupted")
        #expect(try await reopened.messages().last?.content == partial.content)
        // Report actual local search latency, not a guaranteed device-wide bound.
        let start = ContinuousClock.now
        for _ in 0..<20 { _ = try await reopened.search("已经更新") }
        print("FTS5 fixture: 20 searches in \(start.duration(to: .now))")
    }
}
