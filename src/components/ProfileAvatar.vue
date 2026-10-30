<script setup lang="ts">
import { computed, onBeforeUnmount, ref, shallowRef } from "vue";
import AgentAvatar from "./AgentAvatar.vue";
import AppIcon from "./AppIcon.vue";
import AppSheet from "./AppSheet.vue";
import { useSettingsStore } from "../stores/settings";
import { validateImage } from "../ui/images";
import {
  avatarCrop,
  avatarData,
  centeredAvatar,
  dragAvatar,
} from "../ui/avatar";
const props = defineProps<{ compact?: boolean }>();
const settings = useSettingsStore();
const editing = ref(false),
  closing = ref(false),
  busy = ref(false),
  error = ref("");
const source = ref(""),
  image = shallowRef<HTMLImageElement | null>(null);
const animated = ref(false);
const position = ref(centeredAvatar());
const crop = computed(() =>
  image.value
    ? avatarCrop(
        image.value.naturalWidth,
        image.value.naturalHeight,
        position.value,
      )
    : null,
);
const preview = computed(() =>
  image.value && crop.value
    ? {
        width: `${(image.value.naturalWidth / crop.value.edge) * 100}%`,
        height: `${(image.value.naturalHeight / crop.value.edge) * 100}%`,
        left: `${(-crop.value.x / crop.value.edge) * 100}%`,
        top: `${(-crop.value.y / crop.value.edge) * 100}%`,
      }
    : {},
);
let drag: { id: number; x: number; y: number } | null = null;
let closeTimer: ReturnType<typeof setTimeout> | undefined;
function release() {
  if (source.value) URL.revokeObjectURL(source.value);
  source.value = "";
  image.value = null;
  animated.value = false;
  drag = null;
}
function close() {
  if (!busy.value && !closing.value) dismiss();
}
function dismiss() {
  closing.value = true;
  closeTimer = setTimeout(() => {
    editing.value = false;
    closing.value = false;
    error.value = "";
    release();
  }, 180);
}
function open() {
  if (closing.value) return;
  error.value = "";
  editing.value = true;
}
async function choose(event: Event) {
  const input = event.target as HTMLInputElement,
    file = input.files?.[0];
  input.value = "";
  if (!file || busy.value) return;
  busy.value = true;
  error.value = "";
  let url = "";
  try {
    validateImage(file, 5_000_000);
    url = URL.createObjectURL(file);
    const decoded = new Image();
    decoded.src = url;
    await decoded.decode();
    if (!decoded.naturalWidth || !decoded.naturalHeight)
      throw new Error("图片尺寸无效，请换一张图片");
    release();
    source.value = url;
    image.value = decoded;
    animated.value = file.type === "image/gif";
    position.value = centeredAvatar();
    url = "";
  } catch (caught) {
    error.value =
      caught instanceof Error ? caught.message : "图片没有读出来，请重新选择";
  } finally {
    if (url) URL.revokeObjectURL(url);
    busy.value = false;
  }
}
async function save(reset = false) {
  if (busy.value || (!reset && !image.value)) return;
  busy.value = true;
  error.value = "";
  const previous = settings.settings.userAvatarUrl;
  try {
    await settings.patch({
      userAvatarUrl: reset ? "" : avatarData(image.value!, position.value),
    });
    dismiss();
  } catch (caught) {
    settings.settings.userAvatarUrl = previous;
    error.value =
      caught instanceof Error ? caught.message : "头像没有保存，请重试";
  } finally {
    busy.value = false;
  }
}
function pointerDown(event: PointerEvent) {
  if (
    busy.value ||
    (event.pointerType === "mouse" && event.button !== 0) ||
    drag
  )
    return;
  (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
}
function pointerMove(event: PointerEvent) {
  if (busy.value || !image.value || drag?.id !== event.pointerId) return;
  position.value = dragAvatar(
    image.value.naturalWidth,
    image.value.naturalHeight,
    position.value,
    event.clientX - drag.x,
    event.clientY - drag.y,
    (event.currentTarget as HTMLElement).getBoundingClientRect().width,
  );
  drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
}
function pointerUp(event: PointerEvent) {
  if (drag?.id === event.pointerId) drag = null;
}
function keyMove(event: KeyboardEvent) {
  const arrows: Record<string, [number, number]> = {
    ArrowLeft: [0.05, 0],
    ArrowRight: [-0.05, 0],
    ArrowUp: [0, 0.05],
    ArrowDown: [0, -0.05],
  };
  if (!arrows[event.key] || busy.value) return;
  event.preventDefault();
  const [x, y] = arrows[event.key];
  position.value = {
    ...position.value,
    x: Math.max(-1, Math.min(1, position.value.x + x)),
    y: Math.max(-1, Math.min(1, position.value.y + y)),
  };
}
onBeforeUnmount(() => {
  clearTimeout(closeTimer);
  release();
});
</script>
<template>
  <div class="profile-avatar-control" :class="{ compact }">
    <button
      class="profile-photo"
      type="button"
      aria-label="编辑我的头像"
      @click="open"
    >
      <AgentAvatar
        :name="settings.settings.userName || '我'"
        :image="settings.settings.userAvatarUrl"
        :size="props.compact ? 64 : 88"
        personal
      />
      <span class="avatar-camera"><AppIcon name="camera" :size="15" /></span>
    </button>
    <div v-if="!compact" class="profile-photo-copy">
      <strong>我的头像</strong><button class="text-button" type="button" @click="open">
        更换头像<AppIcon name="chevron" :size="15" />
      </button>
    </div>
    <AppSheet v-if="editing" title="我的头像" :closing="closing" @close="close">
      <div class="profile-photo-editor" :aria-busy="busy">
        <template v-if="image">
          <div
            class="avatar-crop"
            role="group"
            aria-label="拖动图片调整头像；也可使用方向键"
            tabindex="0"
            @pointerdown="pointerDown"
            @pointermove="pointerMove"
            @pointerup="pointerUp"
            @pointercancel="pointerUp"
            @lostpointercapture="pointerUp"
            @keydown="keyMove"
          >
            <img
              :src="source"
              :style="preview"
              alt="头像裁剪预览"
              draggable="false"
            />
            <span class="avatar-crop-guide" aria-hidden="true" />
          </div>
          <p class="hint crop-hint">拖动调整位置，滑动缩放</p>
          <label class="range-field"><span>缩放<strong>{{ position.zoom.toFixed(1) }}×</strong></span><input
            v-model.number="position.zoom"
            type="range"
            min="1"
            max="3"
            step="0.05"
            aria-label="头像缩放"
            :disabled="busy"
          /></label>
          <p v-if="animated" class="hint avatar-format">
            GIF 裁剪后会保存为静态头像
          </p>
        </template>
        <AgentAvatar
          v-else
          :name="settings.settings.userName || '我'"
          :image="settings.settings.userAvatarUrl"
          :size="128"
          personal
        />
        <label class="ghost photo-picker"><AppIcon name="image" :size="19" />{{
          image ? "重新选图" : "选择照片或图片"
        }}<input
          class="sr-only"
          type="file"
          accept="image/jpeg,image/png,image/webp,image/gif"
          aria-label="选择我的头像图片"
          :disabled="busy"
          @change="choose"
        /></label>
        <button
          v-if="image"
          class="text-button"
          type="button"
          :disabled="busy"
          @click="position = centeredAvatar()"
        >
          重新居中
        </button>
        <button
          v-else-if="settings.settings.userAvatarUrl"
          class="text-button"
          type="button"
          :disabled="busy"
          @click="save(true)"
        >
          恢复默认头像
        </button>
        <p v-if="error" class="error-line" role="alert">{{ error }}</p>
      </div>
      <template #footer>
        <button class="ghost" type="button" :disabled="busy" @click="close">
          取消
        </button><button
          v-if="image"
          class="primary"
          type="button"
          :disabled="busy"
          @click="save()"
        >
          {{ busy ? "正在保存…" : "使用此头像" }}
        </button>
      </template>
    </AppSheet>
  </div>
</template>
<style scoped>
.profile-avatar-control {
  display: flex;
  align-items: center;
  gap: 22px;
  min-width: 0;
}
.profile-avatar-control.compact {
  flex-shrink: 0;
}
.profile-photo {
  position: relative;
  padding: 0;
  border: 0;
  background: none;
  display: block;
  flex-shrink: 0;
  border-radius: 24px;
  cursor: pointer;
}
.profile-photo:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 5px;
}
.profile-photo-copy {
  display: grid;
  gap: 6px;
}
.profile-photo-copy > strong {
  font-size: 17px;
}
.profile-photo-copy > .text-button {
  padding: 0;
  min-height: 36px;
  justify-content: flex-start;
}
.profile-photo-editor {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 16px;
}
.profile-photo-editor > .range-field {
  width: 100%;
  max-width: 300px;
}
.avatar-crop {
  position: relative;
  width: min(100%, 300px);
  aspect-ratio: 1;
  overflow: hidden;
  border-radius: 22px;
  background: #16191d;
  touch-action: none;
  cursor: grab;
  outline: 1px solid var(--glass-line);
  user-select: none;
}
.avatar-crop:active {
  cursor: grabbing;
}
.avatar-crop:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 4px;
}
.avatar-crop > img {
  position: absolute;
  max-width: none;
  object-fit: fill;
  pointer-events: none;
}
.avatar-crop-guide {
  position: absolute;
  inset: 0;
  border-radius: 22px;
  box-shadow: inset 0 0 0 1px #ffffff50;
  pointer-events: none;
  background:
    linear-gradient(
      90deg,
      transparent 33.1%,
      #ffffff30 33.3%,
      transparent 33.5%,
      transparent 66.4%,
      #ffffff30 66.6%,
      transparent 66.8%
    ),
    linear-gradient(
      transparent 33.1%,
      #ffffff30 33.3%,
      transparent 33.5%,
      transparent 66.4%,
      #ffffff30 66.6%,
      transparent 66.8%
    );
}
.crop-hint {
  text-align: center;
  margin: 0;
}
.avatar-format {
  font-size: 12px;
  margin: 0;
}
.photo-picker {
  position: relative;
  display: flex;
  cursor: pointer;
  min-height: 46px;
  width: 100%;
  max-width: 300px;
}
.profile-photo-editor > .error-line {
  width: 100%;
}
.profile-avatar-control:not(.compact) {
  padding: 4px 0 24px;
}
</style>
