<script setup lang="ts">
import { ref } from "vue";
import { imageData } from "../ui/images";
import defaultAvatar from "../assets/avatars/vchat-default.png";
import AgentAvatar from "./AgentAvatar.vue";
import AppIcon from "./AppIcon.vue";
defineProps<{ name: string }>();
const picture = defineModel<string>("picture", { required: true });
const symbol = defineModel<string>("symbol", { required: true });
const busy = ref(false); const error = ref("");
async function selectDefault() {
  busy.value = true; error.value = "";
  try {
    const response = await fetch(defaultAvatar);
    if (!response.ok) throw new Error("内置头像没有读出来");
    // Persist the actual picture, not a build-specific asset URL that expires on update.
    picture.value = await imageData(new File([await response.blob()], "vchat-avatar.png", { type: "image/png" }), 512, true);
  } catch (caught) { error.value = caught instanceof Error ? caught.message : "头像没有读出来"; }
  finally { busy.value = false; }
}
async function change(event: Event) {
  const input = event.target as HTMLInputElement; const file = input.files?.[0]; input.value = "";
  if (!file) return;
  busy.value = true; error.value = "";
  try { picture.value = await imageData(file, 512, true); }
  catch (caught) { error.value = caught instanceof Error ? caught.message : "头像没有读出来"; }
  finally { busy.value = false; }
}
</script>
<template>
  <div class="avatar-editor">
    <label class="avatar-photo-button"><AgentAvatar :name="name" :symbol="symbol" :image="picture" :size="88" /><span class="avatar-camera"><AppIcon name="camera" :size="17" /></span><input class="sr-only" type="file" accept="image/jpeg,image/png,image/webp,image/gif" aria-label="更换 Agent 图片头像" :disabled="busy" @change="change" /></label>
    <div class="avatar-editor-copy"><strong>{{ busy ? '正在导入…' : '让它有自己的样子' }}</strong><p>点头像，选择照片或图片。</p><div class="row"><button class="text-button" type="button" :disabled="busy" @click="selectDefault">VChat 头像</button><button class="text-button" type="button" :disabled="busy" @click="picture = ''">文字头像</button></div></div>
    <label v-if="!picture" class="field avatar-symbol">头像文字<input v-model="symbol" type="text" maxlength="8" placeholder="✦" /></label>
    <p v-if="error" class="error-line" role="alert">{{ error }}</p>
  </div>
</template>
