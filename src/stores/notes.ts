import { defineStore } from "pinia";
import { ref } from "vue";
import type { LocalNote } from "../domain";
import { createAppHttp } from "../protocol/http";
import { createId } from "../protocol/ids";
import { listNoteFolders, listRemoteNotes, normalizeNoteFileName, readRemoteNote, saveRemoteNote, searchRemoteNotes, type RemoteNote } from "../protocol/notes";
import { getRepository } from "../storage";
import { useSettingsStore } from "./settings";

export const useNotesStore = defineStore("notes", () => {
  const notes = ref<LocalNote[]>([]);
  const activeId = ref("");
  const folders = ref<string[]>([]);
  const remote = ref<RemoteNote[]>([]);
  const remoteFolder = ref("");
  const remoteFile = ref("");
  const remoteBody = ref("");
  const loading = ref(false);
  const error = ref("");

  async function load() {
    notes.value = await getRepository().listNotes();
    activeId.value = notes.value[0]?.id ?? "";
  }

  async function createLocal() {
    const note: LocalNote = { id: createId("note"), title: "未命名笔记", body: "", updatedAt: Date.now() };
    notes.value = [note, ...notes.value];
    activeId.value = note.id;
    await getRepository().saveNote(note);
  }

  async function saveLocal(note: LocalNote) {
    const next = { ...note, updatedAt: Date.now() };
    notes.value = notes.value.map((item) => (item.id === next.id ? next : item));
    await getRepository().saveNote(next);
  }

  async function removeLocal(id: string) {
    notes.value = notes.value.filter((note) => note.id !== id);
    if (activeId.value === id) activeId.value = notes.value[0]?.id ?? "";
    await getRepository().deleteNote(id);
  }

  async function refreshFolders() {
    loading.value = true;
    error.value = "";
    try {
      const http = await createAppHttp();
      folders.value = await listNoteFolders(useSettingsStore().settings, http);
      if (!remoteFolder.value && folders.value[0]) remoteFolder.value = folders.value[0];
      if (remoteFolder.value) await refreshRemote();
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : "无法读取日记文件夹";
    } finally {
      loading.value = false;
    }
  }

  async function refreshRemote() {
    if (!remoteFolder.value) return;
    loading.value = true;
    error.value = "";
    try {
      const http = await createAppHttp();
      remote.value = await listRemoteNotes(useSettingsStore().settings, http, remoteFolder.value);
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : "无法读取日记";
    } finally {
      loading.value = false;
    }
  }

  async function openRemote(note: RemoteNote) {
    loading.value = true;
    error.value = "";
    remoteFolder.value = note.folder || remoteFolder.value;
    remoteFile.value = note.file;
    try {
      const http = await createAppHttp();
      remoteBody.value = await readRemoteNote(useSettingsStore().settings, http, remoteFolder.value, note.file);
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : "无法打开日记";
    } finally {
      loading.value = false;
    }
  }

  async function saveRemote() {
    loading.value = true;
    error.value = "";
    try {
      const file = normalizeNoteFileName(remoteFile.value);
      remoteFile.value = file;
      const http = await createAppHttp();
      await saveRemoteNote(useSettingsStore().settings, http, remoteFolder.value, file, remoteBody.value);
      await refreshRemote();
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : "保存失败";
    } finally {
      loading.value = false;
    }
  }

  async function search(term: string) {
    loading.value = true;
    error.value = "";
    try {
      const http = await createAppHttp();
      remote.value = await searchRemoteNotes(useSettingsStore().settings, http, term, remoteFolder.value);
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : "搜索失败";
    } finally {
      loading.value = false;
    }
  }

  return {
    notes,
    activeId,
    folders,
    remote,
    remoteFolder,
    remoteFile,
    remoteBody,
    loading,
    error,
    load,
    createLocal,
    saveLocal,
    removeLocal,
    refreshFolders,
    refreshRemote,
    openRemote,
    saveRemote,
    search,
  };
});
