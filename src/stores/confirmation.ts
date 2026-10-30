import { defineStore } from "pinia";
import { onScopeDispose, ref } from "vue";
export interface Confirmation {
  title: string;
  body: string;
  label?: string;
  danger?: boolean;
}
// WKWebView does not provide browser confirm dialogs. Use the existing app sheet.
export const useConfirmationStore = defineStore("confirmation", () => {
  const prompt = ref<Confirmation | null>(null),
    closing = ref(false);
  let resolve: ((value: boolean) => void) | undefined,
    timer: ReturnType<typeof setTimeout> | undefined;
  function ask(options: Confirmation): Promise<boolean> {
    resolve?.(false);
    clearTimeout(timer);
    closing.value = false;
    prompt.value = options;
    return new Promise((done) => {
      resolve = done;
    });
  }
  function settle(value: boolean) {
    if (!prompt.value || closing.value) return;
    closing.value = true;
    resolve?.(value);
    resolve = undefined;
    timer = setTimeout(() => {
      prompt.value = null;
      closing.value = false;
    }, 180);
  }
  onScopeDispose(() => {
    clearTimeout(timer);
    resolve?.(false);
  });
  return { prompt, closing, ask, settle };
});
