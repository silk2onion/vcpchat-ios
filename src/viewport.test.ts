// @vitest-environment jsdom
import { afterEach, expect, test } from "vitest";
import { installAppViewport } from "./viewport";
const original = Object.getOwnPropertyDescriptor(window, "visualViewport");
afterEach(() => {
  if (original) Object.defineProperty(window, "visualViewport", original);
  else Reflect.deleteProperty(window, "visualViewport");
  document.documentElement.removeAttribute("style");
  delete document.documentElement.dataset.keyboard;
});
test("the app frame follows keyboard height and removes its listeners on disposal", () => {
  const viewport = Object.assign(new EventTarget(), {
    height: window.innerHeight,
    offsetTop: 0,
  });
  Object.defineProperty(window, "visualViewport", {
    configurable: true,
    value: viewport,
  });
  const stop = installAppViewport(window);
  expect(document.documentElement.dataset.keyboard).toBe("false");
  viewport.height = 350;
  viewport.dispatchEvent(new Event("resize"));
  expect(document.documentElement.style.getPropertyValue("--app-height")).toBe(
    "350px",
  );
  expect(document.documentElement.dataset.keyboard).toBe("true");
  viewport.offsetTop = 7;
  viewport.dispatchEvent(new Event("scroll"));
  expect(document.documentElement.style.getPropertyValue("--app-top")).toBe(
    "7px",
  );
  stop();
  viewport.height = 600;
  viewport.dispatchEvent(new Event("resize"));
  expect(document.documentElement.style.getPropertyValue("--app-height")).toBe(
    "350px",
  );
});
