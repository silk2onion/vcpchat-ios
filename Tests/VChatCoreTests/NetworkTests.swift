import Foundation
import Testing
@testable import VChatCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VCHAT_FIXTURE_URL"] != nil), .serialized)
struct NetworkTests {
    var base: String { ProcessInfo.processInfo.environment["VCHAT_FIXTURE_URL"]! }
    func request(_ model: String = "burst", key: String = "fixture-chat") -> ChatRequest {
        ChatRequest(configuration: ConnectionConfiguration(server: base, model: model), apiKey: key, messages: [ChatTurn(role: "user", content: "test")])
    }
    @Test func authenticatedModels() async throws {
        let session = SessionActor()
        #expect(try await session.models(configuration: ConnectionConfiguration(server: base), apiKey: "fixture-chat").count == 350)
    }
    @Test func unauthorizedModelsReportsHTTP() async throws {
        let session = SessionActor()
        do { _ = try await session.models(configuration: ConnectionConfiguration(server: base), apiKey: "wrong"); Issue.record("Invalid model-list key must fail") }
        catch { #expect(error as? ClientError == .http(401)) }
    }
    @Test func burstCoalescesAndFlushesUnicodeTail() async throws {
        let session = SessionActor()
        var updates: [SessionUpdate] = []
        for try await update in try await session.stream(request()) { updates.append(update) }
        let final = try #require(updates.last)
        #expect(final.state == .complete)
        #expect(final.text == String(repeating: "字", count: 500) + "🌸尾巴")
        #expect(final.rawEvents >= 501)
        #expect(final.parserWasOffMainThread)
        let isolated = updates.allSatisfy { $0.parserWasOffMainThread }
        #expect(isolated)
        #expect(updates.count < 100)
        print("Burst: \(final.rawEvents) SSE events → \(updates.count) UI snapshots; final UTF-8 tail intact")
    }
    @Test func slowConsumerGetsCompleteSnapshot() async throws {
        let session = SessionActor()
        var final: SessionUpdate?
        for try await update in try await session.stream(request()) {
            final = update
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(final?.state == .complete)
        #expect(final?.text.hasSuffix("🌸尾巴") == true)
    }
    @Test func abruptDisconnectRetainsPartialText() async throws {
        let session = SessionActor()
        var last: SessionUpdate?
        do {
            for try await update in try await session.stream(request("abrupt")) { last = update }
            Issue.record("EOF without DONE must fail")
        } catch { #expect(error as? ClientError == .interrupted) }
        #expect(last?.text == "部分内容保留")
        #expect(last?.state == .failed)
    }
    @Test func stopRetainsTextAndDoesNotKillNextGeneration() async throws {
        let session = SessionActor()
        var stopped: SessionUpdate?
        for try await update in try await session.stream(request("slow")) {
            stopped = update
            if update.rawEvents >= 2 && update.state == .streaming { await session.stop() }
        }
        #expect(stopped?.state == .stopped)
        #expect(stopped?.text.isEmpty == false)
        var final: SessionUpdate?
        for try await update in try await session.stream(request()) { final = update }
        #expect(final?.state == .complete)
    }
    @Test func unauthorizedChatFails() async throws {
        let session = SessionActor()
        do {
            for try await _ in try await session.stream(request(key: "wrong")) {}
            Issue.record("Invalid key must fail")
        } catch { #expect(error as? ClientError == .http(401)) }
    }
    @Test func websocketRequiresAckAndRunsAlongsideChat() async throws {
        let session = SessionActor()
        let stream = try await session.connectPush(configuration: ConnectionConfiguration(server: base), key: "fixture-log")
        var iterator = stream.makeAsyncIterator()
        let ack = try #require(await iterator.next())
        #expect(ack.connected && ack.kind == "connection_ack")
        var final: SessionUpdate?
        for try await update in try await session.stream(request()) { final = update }
        #expect(final?.state == .complete)
        let info = try #require(await iterator.next())
        #expect(info.kind == "vcp_log")
        await session.disconnectPush()
    }
    @Test func websocketWrongKeyDoesNotReportConnected() async throws {
        let session = SessionActor()
        do {
            for try await update in try await session.connectPush(configuration: ConnectionConfiguration(server: base), key: "wrong") {
                #expect(!update.connected)
            }
            Issue.record("Invalid WebSocket key must fail")
        } catch { #expect(error as? ClientError == .authentication) }
    }
}
