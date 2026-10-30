// @vitest-environment jsdom
import { createApp, nextTick } from "vue";
import { createPinia, setActivePinia } from "pinia";
import { beforeEach, expect, test, vi } from "vitest";
import ConnectedFolders from "./ConnectedFolders.vue";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "../stores/settings";
const api = vi.hoisted(() => ({
  folders: vi.fn(),
  list: vi.fn(),
  read: vi.fn(),
  write: vi.fn(),
  connect: vi.fn(),
}));
vi.mock("../files/connected", async (original) => ({
  ...(await original<typeof import("../files/connected")>()),
  connectedFiles: api,
}));
vi.mock("../protocol/http", async (original) => ({
  ...(await original<typeof import("../protocol/http")>()),
  isTauri: () => true,
}));
const flush = async () => {
  await new Promise((r) => setTimeout(r, 0));
  await nextTick();
};
const button = (text: string) =>
  [...document.querySelectorAll("button")].find((b) =>
    b.textContent?.includes(text),
  )!;
beforeEach(() => {
  vi.clearAllMocks();
  installRepository(createMemoryRepository());
  api.folders.mockResolvedValue([
    { id: "root", name: "工作目录", agentAccess: "off" },
  ]);
  api.list.mockResolvedValue({
    items: [{ name: "proof.txt", path: "proof.txt", type: "file", size: 9 }],
    truncated: false,
  });
  api.read.mockResolvedValue({
    name: "proof.txt",
    path: "proof.txt",
    type: "file",
    size: 9,
    text: "original",
    version: "before",
  });
  api.write.mockResolvedValue({
    path: "proof.txt",
    version: "after",
    backupId: "backup",
  });
});
test("connected-folder editor writes the original with its current version and shows the backup result", async () => {
  const pinia = createPinia();
  setActivePinia(pinia);
  await useSettingsStore().load();
  const host = document.createElement("div");
  document.body.append(host);
  const app = createApp(ConnectedFolders).use(pinia);
  app.mount(host);
  await flush();
  button("打开文件夹").click();
  await flush();
  button("proof.txt").click();
  await flush();
  const input = document.querySelector("textarea")!;
  input.value = "changed";
  input.dispatchEvent(new Event("input", { bubbles: true }));
  await nextTick();
  button("保存原文件").click();
  await flush();
  expect(api.write).toHaveBeenCalledWith(
    "root",
    "proof.txt",
    "changed",
    "before",
  );
  expect(host.textContent).toContain("修改前的内容已备份");
  expect(button("已保存").disabled).toBe(true);
  app.unmount();
  host.remove();
});
test("canceling the system picker leaves existing connections unchanged", async () => {
  const pinia = createPinia();
  setActivePinia(pinia);
  await useSettingsStore().load();
  api.connect.mockResolvedValue({ canceled: true });
  const host = document.createElement("div");
  document.body.append(host);
  const app = createApp(ConnectedFolders).use(pinia);
  app.mount(host);
  await flush();
  button("连接文件夹").click();
  await flush();
  expect(api.connect).toHaveBeenCalledOnce();
  expect(api.folders).toHaveBeenCalledOnce();
  expect(host.textContent).toContain("工作目录");
  app.unmount();
  host.remove();
});
