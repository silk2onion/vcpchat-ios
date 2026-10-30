import { expect, test } from "vitest";
import { shouldSendOnEnter } from "./composer";
const enter = { key: "Enter", keyCode: 13, isComposing: false, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false };
test("Enter defaults to newline, and the preference enables plain Enter sending", () => {
  expect(shouldSendOnEnter(enter, false)).toBe(false);
  expect(shouldSendOnEnter(enter, true)).toBe(true);
});
test("Shift+Enter and Option+Enter remain newline in plain Enter send mode", () => {
  expect(shouldSendOnEnter({ ...enter, shiftKey: true }, true)).toBe(false);
  expect(shouldSendOnEnter({ ...enter, altKey: true }, true)).toBe(false);
});
test("Cmd/Ctrl+Enter keeps the existing send shortcut in both modes", () => {
  for (const enabled of [false, true]) {
    expect(shouldSendOnEnter({ ...enter, metaKey: true }, enabled)).toBe(true);
    expect(shouldSendOnEnter({ ...enter, ctrlKey: true }, enabled)).toBe(true);
  }
});
test("IME selection, including WebKit 229, never submits", () => {
  expect(shouldSendOnEnter({ ...enter, isComposing: true }, true)).toBe(false);
  expect(shouldSendOnEnter({ ...enter, keyCode: 229 }, true)).toBe(false);
  expect(shouldSendOnEnter({ ...enter, metaKey: true, isComposing: true }, false)).toBe(false);
  expect(shouldSendOnEnter({ ...enter, key: "a" }, true)).toBe(false);
});
