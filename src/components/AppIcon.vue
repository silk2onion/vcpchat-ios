<script setup lang="ts">
withDefaults(defineProps<{ name: string; size?: number }>(), { size: 22 });
const paths: Record<string, string> = {
  folder: "M3 7V4h6l3 3h9v14H3V7Z",
  sync: "M3 11a9 9 0 0 1 15-7l3 3M21 3v4h-4M21 13a9 9 0 0 1-15 7l-3-3M3 21v-4h4",
  person: "M20 21v-2a8 8 0 0 0-16 0v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z",
  chat: "M21 11.5a8.4 8.4 0 0 1-9 8.5 9.5 9.5 0 0 1-4-.8L3 21l1.8-5A9.5 9.5 0 0 1 4 12a8.4 8.4 0 0 1 8.5-9H13a8.4 8.4 0 0 1 8 8.5Z",
  agents:
    "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75",
  notes: "M5 3h12l3 3v15H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2ZM8 8h8M8 12h8M8 16h5",
  settings:
    "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8ZM9 3l-1 3-3 1-3 3 2 3v3l3 2 2 3h5l2-3 3-1 2-3-2-3V8l-3-2-2-3H9Z",
  back: "m14 5-7 7 7 7",
  chevron: "m9 5 7 7-7 7",
  down: "m6 9 6 6 6-6",
  plus: "M12 5v14M5 12h14",
  close: "m6 6 12 12M6 18 18 6",
  search: "M21 21l-5-5M10.5 18a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15Z",
  more: "M5 12h.01M12 12h.01M19 12h.01",
  star: "m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3l-5.6 2.9 1.1-6.2L3 9.6l6.2-.9L12 3Z",
  edit: "m16 3 5 5-12 12-6 1 1-6L16 3Zm-3 3 5 5",
  trash: "M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7",
  send: "M12 20V4m-7 7 7-7 7 7",
  stop: "M6 6h12v12H6Z",
  attach:
    "m21 11-8.5 8.5a5 5 0 0 1-7-7L15 3a3.5 3.5 0 0 1 5 5L10.5 17.5a2 2 0 0 1-3-3L16 6",
  history: "M3 11a9 9 0 1 1 2.6 7M3 3v8h8M12 7v5l3 2",
  logs: "M8 3H5v18h14V3h-3M9 3h6v4H9ZM8 12h8M8 16h5",
  check: "m5 12 4 4L19 6",
  server: "M3 3h18v7H3ZM3 14h18v7H3ZM7 6.5h.01M7 17.5h.01",
  render: "m12 3 3 6 6 3-6 3-3 6-3-6-6-3 6-3 3-6Z",
  palette:
    "M12 3a9 9 0 1 0 0 18h1a2 2 0 0 0 1-3.7 1.5 1.5 0 0 1 1-2.8h2a4 4 0 0 0 4-4A8 8 0 0 0 12 3ZM7 10h.01M9 6h.01M14 6h.01M17 10h.01",
  shield: "m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6l8-3Z",
  bell: "M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4",
  image: "M3 3h18v18H3ZM3 16l6-6 5 5 3-3 4 4M16 7h.01",
  upload: "M12 16V3m-5 5 5-5 5 5M3 15v6h18v-6",
  download: "M12 3v13m-5-5 5 5 5-5M3 15v6h18v-6",
  keyboard: "M2 5h20v14H2ZM6 9h.01M10 9h.01M14 9h.01M18 9h.01M6 12h.01M10 12h.01M14 12h.01M18 12h.01M7 16h10",
  up: "m6 15 6-6 6 6",
  camera: "M8 4h8l2 3h4v14H2V7h4l2-3ZM16 13a4 4 0 1 0-8 0 4 4 0 0 0 8 0Z",
  speaker: "m11 5-6 4H2v6h3l6 4V5ZM15 8a6 6 0 0 1 0 8M18 4a11 11 0 0 1 0 16",
  play: "m8 4 13 8-13 8V4Z",
  pause: "M7 4v16M17 4v16",
  regex: "M4 17h.01M8 8l10 10M18 8 8 18M13 3v7M9 5l8 4M17 5l-8 4",
  brain: "M12 3v18M12 5C9 0 4 4 5 8 1 10 2 16 6 16c0 5 6 7 6 2M12 5c3-5 8-1 7 3 4 2 3 8-1 8 0 5-6 7-6 2M6 10l3 2M18 10l-3 2",
  database: "M21 5c0 2-4 3-9 3S3 7 3 5s4-3 9-3 9 1 9 3ZM3 5v14c0 2 4 3 9 3s9-1 9-3V5M3 12c0 2 4 3 9 3s9-1 9-3",
  activity: "M2 12h4l3-8 6 16 3-8h4",
  clock: "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0ZM12 7v5l3 2",
  copy: "M8 8h13v13H8ZM16 8V3H3v13h5",
  tune: "M4 3v6M4 15v6M12 3v12M12 19v2M20 3v2M20 11v10M1 9h6M9 15h6M17 5h6",
  moon: "M20 15A9 9 0 0 1 9 4a9 9 0 1 0 11 11Z",
  info: "M12 11v6M12 7h.01M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
};
</script>
<template>
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.8"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <path :d="paths[name] || paths.chat" />
  </svg>
</template>
