import Foundation
import Testing
@testable import VChatCore

struct SyncCheckpointIndexTests {
    @Test func legacyAndNewCheckpointsRemainIndividuallyRestorable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try await ChatStore.open(path: url.appendingPathComponent("chat.sqlite").path)
        let p = SyncProfile(id: "source", endpoint: "http://localhost:5974")
        let other = SyncProfile(id: "other", endpoint: "http://localhost:5976")
        var snap = SyncSnapshot()
        snap.agents = [VCPAgent(id:"sync:source:agent",name:"A")]
        snap.topics = [ChatTopic(id:"t",ownerId:snap.agents[0].id)]
        snap.messages = [StoredMessage(topicID:"t",role:"user",content:String(repeating: "引号\"\\{}[],", count: 20000))]
        let old = SyncCheckpoint(id:"old",profileID:p.id,at:17,before:snap,after:.init(),previous:p)
        try await db.put(old,kind:"sync-checkpoint",id:old.id)
        try await db.put(SyncCheckpoint(id:"else",profileID:other.id,at:19,before:.init(),after:.init(),previous:other),kind:"sync-checkpoint",id:"else")
        try await db.commitSync(profile:p,previous:p,before:.init(),after:.init())
        let rows = try await db.checkpointSummaries()
        #expect(rows.count == 3 && rows.filter { $0.profileID == p.id }.count == 2)
        let r = try #require(rows.first { $0.id == "old" })
        #expect(r.at == 17 && r.beforeTopics == 1 && r.afterTopics == 0)
        #expect(try await db.restoreSync(id:r.id) == p.id)
        #expect(try await db.messages(topicID:"t").first?.content == snap.messages[0].content)
        #expect(try await db.checkpointSummaries().count == 4)
        #expect(try await db.records(SyncCheckpoint.self,kind:"sync-checkpoint").contains { $0.id == old.id && $0.before == snap })
    }
}
