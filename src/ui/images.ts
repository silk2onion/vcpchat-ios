export function validateImage(file: Pick<File, "type" | "size">, maxBytes = 8_000_000) {
  if (!["image/jpeg", "image/png", "image/webp", "image/gif"].includes(file.type)) throw new Error("请选择 JPG、PNG、WebP 或 GIF 图片");
  if (file.size > maxBytes) throw new Error(`图片不能超过 ${Math.round(maxBytes / 1_000_000)}MB`);
}

/** Decode uploads once and store a bounded local image, never an external URL. */
export async function imageData(file: File, size: number, square = false): Promise<string> {
  validateImage(file, square ? 5_000_000 : 8_000_000);
  const objectUrl = URL.createObjectURL(file);
  try {
    const image = new Image(); image.src = objectUrl; await image.decode();
    if (file.type === "image/gif") {
      return await new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(String(reader.result)); reader.onerror = reject; reader.readAsDataURL(file); });
    }
    const canvas = document.createElement("canvas");
    const factor = Math.min(1, size / (square ? Math.min(image.width, image.height) : Math.max(image.width, image.height)));
    canvas.width = square ? Math.round(Math.min(size, image.width, image.height)) : Math.round(image.width * factor);
    canvas.height = square ? canvas.width : Math.round(image.height * factor);
    const context = canvas.getContext("2d");
    if (!context) throw new Error("当前设备无法处理图片");
    if (square) {
      const edge = Math.min(image.width, image.height);
      context.drawImage(image, (image.width - edge) / 2, (image.height - edge) / 2, edge, edge, 0, 0, canvas.width, canvas.height);
    } else context.drawImage(image, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/webp", 0.88);
  } finally { URL.revokeObjectURL(objectUrl); }
}
