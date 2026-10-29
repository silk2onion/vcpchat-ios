import { describe, expect, test } from "vitest";
import { ensureSeed } from "./index";
import { createMemoryRepository } from "./memory";

describe("local history", () => {
  test("seeds an empty library and cascades deletes", async () => {
    const repository = createMemoryRepository();
    await ensureSeed(repository);
    const agents = await repository.listAgents();
    expect(agents).toHaveLength(1);
    expect(agents[0].name).toBe("助手");
    const topics = await repository.listTopics();
    await repository.saveMessage({
      id: "m1",
      topicId: topics[0].id,
      role: "user",
      content: "在吗",
      reasoning: "",
      attachments: [],
      createdAt: 2,
      status: "complete",
    });
    await repository.saveGroup({ id: "g", name: "圆桌", memberIds: [agents[0].id], mode: "rotate", createdAt: 3 });
    await repository.deleteAgent(agents[0].id);
    expect(await repository.listTopics()).toEqual([]);
    expect(await repository.listMessages(topics[0].id)).toEqual([]);
    expect((await repository.listGroups())[0].memberIds).toEqual([]);
    await ensureSeed(repository);
    expect(await repository.listAgents()).toHaveLength(1);
  });
});
