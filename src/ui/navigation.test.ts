import { expect, test } from "vitest";
import { pageTransition, primaryTabs, tabIsActive } from "./navigation";
test("three primary destinations keep notes, settings and their children under Me", () => {
  expect(primaryTabs.map((tab) => tab.label)).toEqual(["会话", "通讯录", "我"]);
  for (const path of ["/me", "/notes", "/settings", "/settings/profile", "/settings/connection", "/logs"]) expect(tabIsActive("/me", path)).toBe(true);
  expect(tabIsActive("/", "/chat/topic-1")).toBe(true); expect(tabIsActive("/agents", "/agents")).toBe(true);
  expect(tabIsActive("/me", "/agents")).toBe(false);
});
test("nested destinations slide forward and explicit back links slide back", () => {
  expect(pageTransition("/settings", "/me")).toBe("page-forward");
  expect(pageTransition("/notes", "/me")).toBe("page-forward");
  expect(pageTransition("/settings/connection", "/settings")).toBe("page-forward");
  expect(pageTransition("/me", "/settings")).toBe("page-back");
  expect(pageTransition("/me", "/notes")).toBe("page-back");
  expect(pageTransition("/settings", "/settings/profile")).toBe("page-back");
  expect(pageTransition("/agents", "/me")).toBe("page-tab");
});
