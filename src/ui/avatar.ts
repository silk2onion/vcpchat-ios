export interface AvatarPosition {
  zoom: number;
  x: number;
  y: number;
}
export const centeredAvatar = (): AvatarPosition => ({ zoom: 1, x: 0, y: 0 });
const clamp = (value: number, min: number, max: number) =>
  Math.max(min, Math.min(max, value));
/** The same source rectangle drives both CSS preview and final canvas pixels. */
export function avatarCrop(
  width: number,
  height: number,
  position: AvatarPosition,
) {
  const edge = Math.min(width, height) / clamp(position.zoom, 1, 3);
  return {
    edge,
    x: ((width - edge) * (clamp(position.x, -1, 1) + 1)) / 2,
    y: ((height - edge) * (clamp(position.y, -1, 1) + 1)) / 2,
  };
}
export function dragAvatar(
  width: number,
  height: number,
  position: AvatarPosition,
  dx: number,
  dy: number,
  viewport: number,
): AvatarPosition {
  const { edge } = avatarCrop(width, height, position);
  return {
    ...position,
    x:
      width === edge
        ? 0
        : clamp(
            position.x - (2 * dx * edge) / viewport / (width - edge),
            -1,
            1,
          ),
    y:
      height === edge
        ? 0
        : clamp(
            position.y - (2 * dy * edge) / viewport / (height - edge),
            -1,
            1,
          ),
  };
}
export function avatarData(
  image: HTMLImageElement,
  position: AvatarPosition,
): string {
  const { edge, x, y } = avatarCrop(
    image.naturalWidth,
    image.naturalHeight,
    position,
  );
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = Math.max(1, Math.min(512, Math.round(edge)));
  const context = canvas.getContext("2d");
  if (!context) throw new Error("当前设备无法处理头像");
  context.drawImage(image, x, y, edge, edge, 0, 0, canvas.width, canvas.height);
  const result = canvas.toDataURL("image/webp", 0.88);
  if (!result.startsWith("data:image/"))
    throw new Error("头像没有生成，请重新选择图片");
  return result;
}
