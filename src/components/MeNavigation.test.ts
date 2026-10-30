// @vitest-environment jsdom
import { createApp, nextTick, h } from "vue";
import { createPinia, setActivePinia, disposePinia } from "pinia";
import { createMemoryHistory, createRouter, RouterView } from "vue-router";
import { expect, test, vi } from "vitest";
import MeView from "../views/MeView.vue";
import NotesView from "../views/NotesView.vue";
import SettingsView from "../views/SettingsView.vue";
import { useSettingsStore } from "../stores/settings";
import { useWorkspaceStore } from "../stores/workspace";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
test("Me opens existing notes, settings, profile and the live activity drawer", async () => {
  const pinia = createPinia(); setActivePinia(pinia); installRepository(createMemoryRepository()); await useSettingsStore().load();
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/me", component: MeView }, { path: "/sync", component: {render:()=>null} }, { path: "/files", component: {render:()=>null} }, { path: "/notes", component: NotesView }, { path: "/settings/:section?", component: SettingsView }, { path: "/logs", component: { render: () => null } }] });
  await router.push("/me"); await router.isReady();
  const host = document.createElement("div"); document.body.append(host); const app = createApp({ render: () => h(RouterView) }); app.use(pinia); app.use(router); app.mount(host);
  try {
    expect([...host.querySelectorAll('a')].map((a) => a.getAttribute('href'))).toEqual(["/settings/profile?from=me", "/sync", "/files", "/notes", "/settings"]);
    host.querySelector<HTMLButtonElement>('button[aria-label="编辑我的头像"]')!.click(); await nextTick();
    expect(document.querySelector('[role="dialog"]')?.getAttribute('aria-label')).toBe("我的头像");
    expect(useWorkspaceStore().activityOpen).toBe(false);
    document.querySelector<HTMLButtonElement>('button[aria-label="关闭面板"]')!.click();
    await vi.waitFor(() => expect(document.querySelector('[role="dialog"]')).toBeNull());
    [...host.querySelectorAll<HTMLButtonElement>('button')].find((b) => b.textContent?.includes('通知中心'))!.click(); expect(useWorkspaceStore().activityOpen).toBe(true);
    host.querySelector<HTMLAnchorElement>('a[href="/settings"]')!.click(); await new Promise((resolve) => setTimeout(resolve, 0)); await nextTick(); expect(router.currentRoute.value.path).toBe("/settings");
    expect(host.querySelector('a[aria-label="返回我"]')?.getAttribute('href')).toBe("/me");
    await router.push("/me"); await nextTick();
    host.querySelector<HTMLAnchorElement>('a[href="/settings/profile?from=me"]')!.click();
    await new Promise((resolve) => setTimeout(resolve, 0)); await nextTick();
    expect(router.currentRoute.value.path).toBe("/settings/profile");
    expect(host.querySelector('a[aria-label="返回我"]')?.getAttribute('href')).toBe("/me");
    await router.push("/settings/profile"); await nextTick();
    expect(host.querySelector('a[aria-label="返回设置"]')?.getAttribute('href')).toBe("/settings");
  } finally { app.unmount(); host.remove(); disposePinia(pinia); }
});
