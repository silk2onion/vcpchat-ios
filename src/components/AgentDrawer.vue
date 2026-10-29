<script setup lang="ts">
import { computed, ref } from "vue";
import type { GroupMode } from "../domain";
import { useLibraryStore } from "../stores/library";

defineEmits<{ close: [] }>();

const library = useLibraryStore();
const agentName = ref("");
const groupName = ref("");
const groupMode = ref<GroupMode>("mention");
const memberIds = ref<string[]>([]);
const editingPrompt = ref(false);
const promptDraft = ref("");

const title = computed(() => (library.ownerType === "group" ? library.currentGroup?.name : library.currentAgent?.name) || "对话");

async function addAgent() {
  if (!agentName.value.trim()) return;
  await library.createAgent(agentName.value);
  agentName.value = "";
}

async function addGroup() {
  if (!memberIds.value.length) return;
  await library.createGroup(groupName.value, memberIds.value, groupMode.value);
  groupName.value = "";
  memberIds.value = [];
}

function toggleMember(id: string) {
  memberIds.value = memberIds.value.includes(id) ? memberIds.value.filter((item) => item !== id) : [...memberIds.value, id];
}

function beginPrompt() {
  promptDraft.value = library.currentAgent?.systemPrompt ?? "";
  editingPrompt.value = true;
}

async function savePrompt() {
  const agent = library.currentAgent;
  if (!agent) return;
  await library.saveAgent({ ...agent, systemPrompt: promptDraft.value });
  editingPrompt.value = false;
}

async function removeCurrent() {
  if (library.ownerType === "agent" && library.currentAgent) {
    if (confirm(`删除助手「${library.currentAgent.name}」和它的本地话题？`)) await library.removeAgent(library.currentAgent.id);
  }
  if (library.ownerType === "group" && library.currentGroup) {
    if (confirm(`删除群组「${library.currentGroup.name}」？`)) await library.removeGroup(library.currentGroup.id);
  }
}
</script>

<template>
  <aside class="drawer">
    <div class="spread">
      <h2>书架</h2>
      <button class="ghost" type="button" @click="$emit('close')">关闭</button>
    </div>
    <section class="stack">
      <p class="eyebrow">助手</p>
      <button
        v-for="agent in library.agents"
        :key="agent.id"
        class="list-button"
        :class="{ active: library.ownerType === 'agent' && library.ownerId === agent.id }"
        type="button"
        @click="library.selectOwner('agent', agent.id)"
      >
        {{ agent.name }}
      </button>
      <form class="row" @submit.prevent="addAgent">
        <input v-model="agentName" type="text" placeholder="新助手的名字" aria-label="新助手的名字" />
        <button class="primary" type="submit">添加</button>
      </form>
    </section>
    <section class="stack">
      <p class="eyebrow">群组</p>
      <button
        v-for="group in library.groups"
        :key="group.id"
        class="list-button"
        :class="{ active: library.ownerType === 'group' && library.ownerId === group.id }"
        type="button"
        @click="library.selectOwner('group', group.id)"
      >
        {{ group.name }}
      </button>
      <form class="stack" @submit.prevent="addGroup">
        <input v-model="groupName" type="text" placeholder="群组名称" aria-label="群组名称" />
        <label v-for="agent in library.agents" :key="agent.id" class="check">
          <input :checked="memberIds.includes(agent.id)" type="checkbox" @change="toggleMember(agent.id)" />
          {{ agent.name }}
        </label>
        <select v-model="groupMode" aria-label="发言方式">
          <option value="mention">@点名，否则轮流</option>
          <option value="rotate">轮流一位</option>
          <option value="all">每位依次回复</option>
        </select>
        <button class="primary" type="submit">建立群组</button>
      </form>
    </section>
    <section class="stack">
      <div class="spread">
        <p class="eyebrow">{{ title }}的话题</p>
        <button class="ghost" type="button" @click="library.createTopic()">新话题</button>
      </div>
      <button
        v-for="topic in library.ownerTopics"
        :key="topic.id"
        class="list-button"
        :class="{ active: topic.id === library.topicId }"
        type="button"
        @click="library.selectTopic(topic.id)"
      >
        {{ topic.title }}
      </button>
      <button v-if="library.currentAgent && library.ownerType === 'agent'" class="ghost" type="button" @click="beginPrompt">编辑系统提示</button>
      <textarea v-if="editingPrompt" v-model="promptDraft" aria-label="系统提示" placeholder="这个助手平时怎么说话" />
      <button v-if="editingPrompt" class="primary" type="button" @click="savePrompt">保存提示</button>
      <button class="danger" type="button" @click="removeCurrent">删除当前{{ library.ownerType === "group" ? "群组" : "助手" }}</button>
    </section>
  </aside>
</template>
