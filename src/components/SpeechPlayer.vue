<script setup lang="ts">
import { useSpeechStore } from "../stores/speech";
import AppIcon from "./AppIcon.vue";
const speech = useSpeechStore();
const time = (value: number) => `${Math.floor(value / 60)}:${String(Math.floor(value % 60)).padStart(2, '0')}`;
</script>
<template>
  <Transition name="player"><aside v-if="speech.active" class="speech-player" aria-label="语音播放器"><div class="speech-player-icon"><AppIcon name="speaker" :size="20" /></div><div class="speech-player-copy"><strong>{{ speech.speaker }}</strong><span v-if="speech.error" role="status">{{ speech.error }}</span><span v-else>{{ speech.phase === 'loading' ? '正在合成语音…' : speech.phase === 'paused' ? '已暂停' : '正在朗读' }} <small v-if="speech.duration">{{ time(speech.elapsed) }} / {{ time(speech.duration) }}</small></span><progress v-if="speech.duration" :value="speech.elapsed" :max="speech.duration" aria-label="朗读进度" /></div><button class="icon-button" type="button" :disabled="speech.phase === 'loading' || speech.phase === 'error'" :aria-label="speech.phase === 'playing' ? '暂停朗读' : '播放朗读'" @click="speech.toggle"><AppIcon :name="speech.phase === 'playing' ? 'pause' : 'play'" :size="20" /></button><button class="icon-button subtle" type="button" aria-label="停止朗读" @click="speech.stop"><AppIcon name="close" :size="19" /></button></aside></Transition>
</template>
