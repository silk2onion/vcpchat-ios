import { defineStore } from "pinia";
import { ref, watch } from "vue";
import { MobileFileNode } from "../files/node";
import { isTauri } from "../protocol/http";
import { useSettingsStore } from "./settings";
export const useFileNodeStore = defineStore("file-node", () => {
  const status = ref("未启用");
  let node: MobileFileNode | null = null,
    active = true,
    installed = false;
  function refresh() {
    node?.stop();
    node = null;
    const s = useSettingsStore().settings;
    if (!s.fileNodeEnabled) {
      status.value = "未启用";
      return;
    }
    if (!active) {
      status.value = "后台暂停";
      return;
    }
    if (!isTauri()) {
      status.value = "请在 Mac 或 iOS App 中启用";
      return;
    }
    try {
      node = new MobileFileNode(
        {
          url: s.fileNodeUrl,
          key: s.fileNodeKey,
          name: s.fileNodeName,
          deviceId: s.fileNodeId,
        },
        (v) => (status.value = v),
      );
      node.start();
    } catch {
      status.value = "请检查分布式连接设置";
    }
  }
  function install() {
    if (installed) return;
    installed = true;
    watch(
      () => {
        const s = useSettingsStore().settings;
        return [
          s.fileNodeEnabled,
          s.fileNodeUrl,
          s.fileNodeKey,
          s.fileNodeName,
          s.fileNodeId,
        ];
      },
      refresh,
      { immediate: true },
    );
  }
  function pause() {
    active = false;
    refresh();
  }
  function resume() {
    active = true;
    refresh();
  }
  return { status, install, pause, resume, refresh };
});
