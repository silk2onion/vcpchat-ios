import Foundation
/// Shared by the request builder and the visible model label.
public enum ModelResolution {
    public static func resolve(global: String,agent: VCPAgent,group: VCPGroup?) -> String {
        let unified = group?.unifiedModel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !unified.isEmpty { return unified }
        return agent.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? global : agent.model
    }
    public static func summary(global: String,agent: VCPAgent?,group: VCPGroup?,agents: [VCPAgent]) -> String {
        if let group {
            let unified = group.unifiedModel.trimmingCharacters(in: .whitespacesAndNewlines); if !unified.isEmpty { return unified }
            let models = Set(group.memberIds.compactMap { id in agents.first { $0.id == id }.map { resolve(global: global,agent: $0,group: nil) } })
            if models.count > 1 { return "按成员模型" }; if let model = models.first { return model.isEmpty ? "未选择模型" : model }
        }
        let model = agent.map { resolve(global: global,agent: $0,group: nil) } ?? global
        return model.isEmpty ? "未选择模型" : model
    }
}
public enum AgentIdentity {
    public static func author(agentID: String,name: String,topicID: String,topics: [ChatTopic],agents: [VCPAgent],groups: [VCPGroup]) -> VCPAgent? {
        if !agentID.isEmpty,let agent = agents.first(where: { $0.id == agentID }) { return agent }
        guard let topic = topics.first(where: { $0.id == topicID }) else { return nil }
        if topic.ownerType == "agent" { return agents.first { $0.id == topic.ownerId } }
        guard let group = groups.first(where: { $0.id == topic.ownerId }) else { return nil }
        return group.memberIds.compactMap { id in agents.first { $0.id == id } }.first { $0.name == name }
    }
}
