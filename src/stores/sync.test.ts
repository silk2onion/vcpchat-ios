import { beforeEach, expect, test, vi } from "vitest";
import { createPinia, setActivePinia } from "pinia";
import { createMemoryRepository } from "../storage/memory";
import { installRepository, getRepository } from "../storage";
import { useSettingsStore } from "./settings";
import { useLibraryStore } from "./library";
import { useSyncStore } from "./sync";
import type { SyncOptions } from "../sync/client";
import { emptySnapshot } from "../sync/types";
const run = vi.hoisted(() => vi.fn());
vi.mock("../sync/client", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../sync/client")>()),
  runSync: run,
}));
beforeEach(async () => {
  setActivePinia(createPinia());
  installRepository(createMemoryRepository());
  run.mockReset();
  await useSettingsStore().load();
  await useSettingsStore().patch({
    syncHttpUrl: "http://fixture",
    syncWsUrl: "ws://fixture/",
    syncToken: "fixture-token",
  });
  await useLibraryStore().load();
});
test("sync and local restore are atomic, leaving original conversations, notes and settings untouched", async () => {
  const repo = getRepository(),
    before = await repo.readSnapshot(),
    settings = await repo.getSettings();
  run.mockImplementation(async (o: SyncOptions) => {
    const after = emptySnapshot(),
      id = `sync:${o.profile.id}:agent:remote`;
    after.agents = [
      {
        id,
        name: "桌面",
        systemPrompt: "",
        model: "",
        temperature: null,
        createdAt: 0,
      },
    ];
    return { profile: { ...o.profile, lastSync: 123 }, after };
  });
  await useSyncStore().start("pull");
  expect(useSyncStore().error).toBe("");
  expect((await repo.listAgents()).length).toBe(2);
  expect(useLibraryStore().mainAgent!.id).toBe(before.agents[0].id);
  await useSyncStore().restore();
  expect(await repo.readSnapshot()).toEqual(before);
  expect(await repo.getSettings()).toEqual(settings);
  expect(useSyncStore().summary).toContain("桌面未被回滚");
});
test("a transport failure does not install data or a checkpoint", async () => {
  const repo = getRepository(),
    before = await repo.readSnapshot();
  run.mockRejectedValue(new Error("PHASE_ACK 不匹配"));
  await useSyncStore().start("pull");
  expect(await repo.readSnapshot()).toEqual(before);
  expect((await repo.getSyncVault()).profiles).toEqual({});
  expect(useSyncStore().error).toContain("PHASE_ACK");
});
