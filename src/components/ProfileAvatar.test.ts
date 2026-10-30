// @vitest-environment jsdom
import { createApp, nextTick } from "vue";
import { createPinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import ProfileAvatar from "./ProfileAvatar.vue";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "../stores/settings";
import * as avatar from "../ui/avatar";
const previous = "data:image/png;base64,previous",
  cropped = "data:image/webp;base64,cropped";
const flush = async () => {
  await new Promise((r) => setTimeout(r, 0));
  await nextTick();
};
const button = (label: string) =>
  [...document.querySelectorAll("button")].find((b) =>
    b.textContent?.includes(label),
  )!;
let unmount: () => void;
let repository: ReturnType<typeof createMemoryRepository>;
beforeEach(async () => {
  const pinia = createPinia();
  setActivePinia(pinia);
  repository = createMemoryRepository();
  installRepository(repository);
  await useSettingsStore().load();
  await useSettingsStore().patch({ userName: "丝巾", userAvatarUrl: previous });
  vi.stubGlobal(
    "Image",
    class {
      src = "";
      naturalWidth = 1200;
      naturalHeight = 800;
      decode = async () => {};
    },
  );
  vi.stubGlobal(
    "URL",
    Object.assign(URL, {
      createObjectURL: vi.fn(() => "blob:avatar-fixture"),
      revokeObjectURL: vi.fn(),
    }),
  );
  vi.spyOn(avatar, "avatarData").mockReturnValue(cropped);
  const host = document.createElement("div");
  document.body.append(host);
  const app = createApp(ProfileAvatar, { compact: true }).use(pinia);
  app.mount(host);
  unmount = () => {
    app.unmount();
    host.remove();
  };
  document
    .querySelector<HTMLButtonElement>('[aria-label="编辑我的头像"]')!
    .click();
  await flush();
});
afterEach(() => {
  unmount();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
async function choose(
  file = new File(["fixture"], "头像.png", { type: "image/png" }),
) {
  const input = document.querySelector<HTMLInputElement>('input[type="file"]')!;
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await flush();
}
test("canceling a crop preserves the saved avatar and releases the temporary picture", async () => {
  await choose();
  expect(document.querySelector('[aria-label="头像缩放"]')).not.toBeNull();
  button("取消").click();
  await flush();
  expect(useSettingsStore().settings.userAvatarUrl).toBe(previous);
  expect((await repository.getSettings()).userAvatarUrl).toBe(previous);
  await vi.waitFor(() =>
    expect(document.querySelector('[role="dialog"]')).toBeNull(),
  );
  expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:avatar-fixture");
});
test("save updates the visible personal avatar, survives a new store, and leaves Agent pictures alone", async () => {
  await repository.saveAgent({
    id: "a",
    name: "助手",
    model: "",
    systemPrompt: "",
    temperature: null,
    createdAt: 1,
    avatarUrl: "agent-picture",
  });
  await choose();
  button("使用此头像").click();
  await flush();
  expect(
    document.querySelector(".profile-photo img")?.getAttribute("src"),
  ).toBe(cropped);
  await vi.waitFor(() =>
    expect(document.querySelector('[role="dialog"]')).toBeNull(),
  );
  setActivePinia(createPinia());
  await useSettingsStore().load();
  expect(useSettingsStore().settings).toMatchObject({
    userName: "丝巾",
    userAvatarUrl: cropped,
  });
  expect((await repository.listAgents())[0].avatarUrl).toBe("agent-picture");
});
test("reset uses the default person icon and keeps other profile settings", async () => {
  button("恢复默认头像").click();
  await flush();
  expect(document.querySelector(".profile-photo img")).toBeNull();
  expect(await repository.getSettings()).toMatchObject({
    userAvatarUrl: "",
    userName: "丝巾",
  });
});
test("an invalid upload or failed persistence cannot replace the previous picture", async () => {
  await choose(
    new File(["not a picture"], "bad.svg", { type: "image/svg+xml" }),
  );
  expect(document.querySelector('[role="alert"]')?.textContent).toContain(
    "JPG",
  );
  expect(useSettingsStore().settings.userAvatarUrl).toBe(previous);
  await choose();
  vi.spyOn(repository, "saveSettings").mockRejectedValueOnce(
    new Error("本机存储空间不足"),
  );
  button("使用此头像").click();
  await flush();
  expect(document.querySelector('[role="alert"]')?.textContent).toContain(
    "空间不足",
  );
  expect(useSettingsStore().settings.userAvatarUrl).toBe(previous);
  expect((await repository.getSettings()).userAvatarUrl).toBe(previous);
  expect(document.querySelector('[role="dialog"]')).not.toBeNull();
});
