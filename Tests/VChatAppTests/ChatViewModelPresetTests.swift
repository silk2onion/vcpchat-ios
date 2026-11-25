import Foundation
import Testing
import VChatCore
@testable import VChatApp

@MainActor
struct ChatViewModelPresetTests {
    private let token = "[[点击按钮:继续]]"
    private let attachment = ChatAttachment(name: "draft.txt", mime: "text/plain", kind: "text", text: "草稿附件")

    // No speakers: exercise real message persistence without a network request.
    private func withRoom(_ body: (ChatViewModel, ChatRoom, ChatStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChatStore(path: directory.appendingPathComponent("chat.sqlite").path)
        let model = ChatViewModel(), topic = ChatTopic(ownerId: "offline", title: "按钮测试")
        let room = ChatRoom(id: topic.id, messages: [])
        model.store = store; model.topics = [topic]; model.activeTopicID = topic.id
        model.rooms[topic.id] = room; model.apiKey = "fixture"
        room.draft = "正在输入"; room.attachments = [attachment]
        try await body(model, room, store)
    }

    @Test(arguments: [false, true])
    func presetPersistsOnlyItsText(identicalDraft: Bool) async throws {
        try await withRoom { model, room, store in
            if identicalDraft { room.draft = token; room.attachments = [] }
            let draft = TopicDraft(id: room.id, text: room.draft, attachments: room.attachments)
            try await store.put(draft, kind: "draft", id: room.id)
            model.sendPreset("  " + token + "\n")
            let turn = try #require(room.generation)
            await turn.value
            let messages = try await store.messages(topicID: room.id)
            #expect(messages.map(\.role) == ["user"])
            #expect(messages.map(\.content) == [token])
            #expect(messages.first?.attachments == [])
            #expect(room.draft == draft.text && room.attachments == draft.attachments)
            let persisted = try await store.records(TopicDraft.self, kind: "draft")
            #expect(persisted.first?.text == draft.text && persisted.first?.attachments == draft.attachments)
        }
    }

    @Test func rejectedPresetsLeaveComposerAndHistoryAlone() async throws {
        try await withRoom { model, room, store in
            @MainActor func rejected(_ text: String, _ expectedError: String?) {
                model.error = nil
                model.sendPreset(text)
                #expect(model.error == expectedError)
                #expect(room.generation == nil)
                #expect(room.draft == "正在输入" && room.attachments == [attachment])
            }
            room.busy = true
            rejected(token, "请等待当前回复完成后再发送")
            room.busy = false; model.synchronizing = true
            rejected(token, "请等待同步完成或取消后再修改会话")
            model.synchronizing = false; model.apiKey = ""
            rejected(token, "请先设置聊天 API Key")
            model.apiKey = "fixture"
            rejected(" \n", nil)
            model.activeTopicID = "absent"
            rejected(token, nil)
            let messages = try await store.messages(topicID: room.id)
            #expect(messages.isEmpty && room.messages.isEmpty)
        }
    }

    @Test func composerStillSendsAttachmentsAndClearsDraft() async throws {
        try await withRoom { model, room, store in
            room.draft = "" // Attachment-only composer sends remain valid.
            var cleared = false
            model.send { cleared = true }
            let turn = try #require(room.generation)
            await turn.value
            let messages = try await store.messages(topicID: room.id)
            #expect(messages.count == 1 && messages.first?.attachments == [attachment])
            #expect(room.attachments.isEmpty && cleared)
        }
    }
}
