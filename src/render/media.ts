import { ref } from "vue";

const VIDEO_EXTENSION = /\.(?:mp4|m4v|mov|webm|ogv)(?:[?#].*)?$/i;

export function isVideoUrl(raw: string): boolean {
  let url: URL;
  try {
    url = new URL(raw, "https://placeholder.invalid/");
  } catch {
    return false;
  }
  if (raw.startsWith("data:video/")) return true;
  if (url.protocol !== "https:" && url.protocol !== "http:") return false;
  return VIDEO_EXTENSION.test(url.pathname);
}

export function isSafeMediaUrl(raw: string): boolean {
  if (/^data:(?:image\/(?!svg)|video\/)/i.test(raw)) return true;
  if (raw.startsWith("blob:")) return true;
  try {
    const url = new URL(raw);
    return url.protocol === "https:" || url.protocol === "http:";
  } catch {
    return false;
  }
}

export interface ViewerItem {
  kind: "image" | "video";
  src: string;
  alt: string;
}

export const viewerItem = ref<ViewerItem | null>(null);

export function openViewer(item: ViewerItem) {
  if (!isSafeMediaUrl(item.src)) return;
  viewerItem.value = item;
}

export function closeViewer() {
  viewerItem.value = null;
}
