import { expect, test } from "vitest";
import { validateImage } from "./images";
test("wallpaper and avatar uploads enforce raster formats and their own limits", () => {
  expect(() => validateImage({ type: "image/gif", size: 7_999_999 })).not.toThrow();
  expect(() => validateImage({ type: "image/svg+xml", size: 1 })).toThrow("JPG");
  expect(() => validateImage({ type: "image/png", size: 8_000_001 })).toThrow("8MB");
  expect(() => validateImage({ type: "image/jpeg", size: 5_000_001 }, 5_000_000)).toThrow("5MB");
});
