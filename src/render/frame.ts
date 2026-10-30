import { onScopeDispose, shallowRef, watch } from "vue";
import type { ChatMessage } from "../domain";

interface ConversationFrame {
  topicId: string;
  streaming: boolean;
  messages: ChatMessage[];
}

interface FrameClock {
  request(callback: FrameRequestCallback): number;
  cancel(id: number): void;
}

/** Batch only the visible projection. Reception and durable storage keep every chunk. */
export function useFrameMessages(
  source: () => ConversationFrame,
  clock: FrameClock = {
    request: (callback) => window.requestAnimationFrame(callback),
    cancel: (id) => window.cancelAnimationFrame(id),
  },
) {
  let latest = source();
  const messages = shallowRef(latest.messages);
  let frame: number | null = null;
  const cancel = () => {
    if (frame !== null) clock.cancel(frame);
    frame = null;
  };
  watch(source, (next) => {
    const switched = next.topicId !== latest.topicId;
    latest = next;
    if (switched || !next.streaming) {
      cancel();
      messages.value = next.messages;
    } else if (frame === null) {
      frame = clock.request(() => {
        frame = null;
        messages.value = latest.messages;
      });
    }
  }, { flush: "sync" });
  onScopeDispose(cancel);
  return messages;
}
