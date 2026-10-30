<script setup lang="ts">
withDefaults(defineProps<{ name: string; size?: number }>(), { size: 22 });
const paths: Record<string, string> = {
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
