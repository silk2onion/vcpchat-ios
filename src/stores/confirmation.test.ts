import { createPinia, setActivePinia } from "pinia";
import { expect, test, vi } from "vitest";
import { useConfirmationStore } from "./confirmation";
test("native-safe confirmation does not execute before acceptance and animates dismissal", async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  const c = useConfirmationStore();
  let called = false;
  const answer = c.ask({ title: "操作", body: "测试" }).then((v) => {
    called = v;
  });
  expect(called).toBe(false);
  c.settle(true);
  await answer;
  expect(called).toBe(true);
  expect(c.closing).toBe(true);
  vi.advanceTimersByTime(180);
  expect(c.prompt).toBeNull();
  const canceled = c.ask({ title: "取消", body: "测试" });
  c.settle(false);
  expect(await canceled).toBe(false);
  vi.runAllTimers();
  vi.useRealTimers();
});
