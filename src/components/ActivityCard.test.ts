// @vitest-environment jsdom
import { createApp, h, nextTick } from "vue";
import { createPinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, expect, test } from "vitest";
import type { LogEntry } from "../domain";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "../stores/settings";
import ActivityCard from "./ActivityCard.vue";
const apps: ReturnType<typeof createApp>[] = [];
beforeEach(async () => { setActivePinia(createPinia()); installRepository(createMemoryRepository()); await useSettingsStore().load(); });
afterEach(() => { for (const app of apps.splice(0)) app.unmount(); document.body.innerHTML = ""; });
async function render(payload: Record<string, unknown>) {
  const entry: LogEntry = { id: "e", channel: "info", title: "fixture", detail: "", createdAt: 1, payload };
  const host = document.createElement("div"); document.body.append(host);
  const app = createApp({ render: () => h(ActivityCard, { entry }) }); apps.push(app); app.mount(host);
  await nextTick(); return host;
}
test("RAG has rendered Markdown, exact scores, sources and complete long records", async () => {
  const host = await render({ type: "RAG_RETRIEVAL_DETAILS", dbName: "笔记", query: "**问题**", useRiverMemo: true, results: [{ score: 0, originalScore: 0.1, source: "zero.md", text: "## 标题\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n" + "长记录".repeat(2000) + "TAIL_OK" }, { source: "time.md", text: "时间召回" }] });
  expect(host.querySelector("table")).not.toBeNull();
  expect(host.textContent).toContain("0.000"); expect(host.textContent).toContain("时间"); expect(host.textContent).toContain("TAIL_OK");
  expect(host.querySelector(".rag-query strong")?.textContent).toBe("问题");
});
test("uses real desktop thinking stages and private chat query/response fields", async () => {
  const chain = await render({ type: "META_THINKING_CHAIN", chainName: "取舍", query: "先做什么", stages: [{ stage: 2, clusterName: "可用性", resultCount: 1, results: [{ score: .9, source: "ux.md", text: "**真实交互**" }] }] });
  expect(chain.querySelector(".observer-step strong")?.textContent).toBe("可用性"); expect(chain.textContent).toContain("ux.md · 0.900");
  const chat = await render({ type: "AGENT_PRIVATE_CHAT_PREVIEW", agentName: "Amadeus", query: "询问", response: "**回答**" });
  expect(chat.querySelectorAll(".observer-message")).toHaveLength(2); expect(chat.querySelector(".observer-message strong")?.textContent).toBe("回答");
});
test("memory and dream bodies render while untrusted scripts stay absent", async () => {
  const memory = await render({ type: "AI_MEMO_RETRIEVAL", diaryCount: 2, mode: "时间", extractedMemories: "**记忆内容**<script>bad()</script>" });
  expect(memory.querySelector("strong")?.textContent).toBe("记忆内容"); expect(memory.querySelector("script")).toBeNull(); expect(memory.querySelector("iframe")).toBeNull();
  const dream = await render({ type: "AGENT_DREAM_NARRATIVE", agentName: "Amadeus", narrative: "## 梦境", fullLength: 2 });
  expect(dream.textContent).toContain("2 字"); expect(dream.querySelector(".event-body h2")?.textContent).toBe("梦境");
});
