// @vitest-environment jsdom
import { createApp, nextTick } from "vue";
import { createPinia, setActivePinia, disposePinia } from "pinia";
import { createMemoryHistory, createRouter } from "vue-router";
import { expect, test, vi } from "vitest";
import SettingsView from "../views/SettingsView.vue";
import { useSettingsStore } from "../stores/settings";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
test("mobile input preference describes touch actions in both modes and saves the existing preference", async () => {
  const pinia = createPinia(); setActivePinia(pinia);
  const repository = createMemoryRepository(); installRepository(repository);
  const settings = useSettingsStore(); await settings.load();
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/settings/:section?", component: SettingsView }, { path: "/:other", component: { render: () => null } }] });
  await router.push("/settings"); await router.isReady();
  const host = document.createElement("div"); document.body.append(host);
  const app = createApp(SettingsView).use(pinia).use(router); app.mount(host); await nextTick();
  try {
    const toggle = host.querySelector<HTMLInputElement>('[aria-label="回车键发送消息"]')!;
    const row = toggle.closest("label")!;
    expect(row.textContent).toContain("回车换行，点箭头发送");
    expect(row.textContent).not.toMatch(/Ctrl|Shift|⌘|Enter/);
    toggle.click(); await vi.waitFor(() => expect(settings.settings.enterSends).toBe(true)); await nextTick();
    expect(row.textContent).toContain("回车发送，点“换行”插入新行");
    expect(row.textContent).not.toMatch(/Ctrl|Shift|⌘|Enter/);
    expect((await repository.getSettings()).enterSends).toBe(true);
  } finally { app.unmount(); host.remove(); disposePinia(pinia); }
});
