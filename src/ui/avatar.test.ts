import { expect, test, vi } from "vitest";
import { avatarCrop, avatarData, centeredAvatar, dragAvatar } from "./avatar";
test("crop defaults to a centered square and zoom/pan never expose blank edges", () => {
  expect(avatarCrop(1200, 800, centeredAvatar())).toEqual({
    edge: 800,
    x: 200,
    y: 0,
  });
  expect(avatarCrop(800, 1200, { zoom: 2, x: -1, y: 1 })).toEqual({
    edge: 400,
    x: 0,
    y: 800,
  });
  expect(avatarCrop(1200, 800, { zoom: 99, x: -99, y: 99 })).toEqual({
    edge: 800 / 3,
    x: 0,
    y: 800 - 800 / 3,
  });
});
test("dragging follows the finger and stops at the image edges", () => {
  expect(dragAvatar(1200, 800, centeredAvatar(), 75, 50, 300)).toEqual({
    zoom: 1,
    x: -1,
    y: 0,
  });
  expect(
    dragAvatar(800, 800, { zoom: 2, x: 0, y: 0 }, -1000, 1000, 300),
  ).toEqual({ zoom: 2, x: 1, y: -1 });
});
test("saved canvas uses exactly the preview crop, capped at 512 pixels", () => {
  const drawImage = vi.fn(),
    toDataURL = vi.fn(() => "data:image/webp;base64,cropped");
  const canvas = {
    width: 0,
    height: 0,
    getContext: () => ({ drawImage }),
    toDataURL,
  };
  vi.stubGlobal("document", { createElement: () => canvas });
  const image = { naturalWidth: 1200, naturalHeight: 800 } as HTMLImageElement;
  try {
    expect(avatarData(image, { zoom: 1, x: 1, y: 0 })).toBe(
      "data:image/webp;base64,cropped",
    );
    expect([canvas.width, canvas.height]).toEqual([512, 512]);
    expect(drawImage).toHaveBeenCalledWith(
      image,
      400,
      0,
      800,
      800,
      0,
      0,
      512,
      512,
    );
  } finally {
    vi.unstubAllGlobals();
  }
});
