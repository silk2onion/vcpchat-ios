import { effectScope, shallowReactive, watch } from "vue";
import { describe, expect, test, vi } from "vitest";
import type { ChatMessage } from "../domain";
import { useFrameMessages } from "./frame";

function message(content: string, status: ChatMessage["status"] = "streaming"): ChatMessage {
  return { id: "reply", topicId: "a", role: "assistant", content, reasoning: "", attachments: [], createdAt: 1, status };
}
function setup() {
  const callbacks = new Map<number, FrameRequestCallback>();
  let id = 0;
  const clock = {
    request: vi.fn((callback: FrameRequestCallback) => { callbacks.set(++id, callback); return id; }),
    cancel: vi.fn((key: number) => { callbacks.delete(key); }),
  };
  const state = shallowReactive({ topicId: "a", streaming: true, messages: [message("")] });
  const scope = effectScope();
  const displayed = scope.run(() => useFrameMessages(() => ({ ...state }), clock))!;
  const paint = () => {
    const pending = [...callbacks.values()];
    callbacks.clear();
    for (const callback of pending) callback(0);
  };
  return { callbacks, clock, state, scope, displayed, paint };
}
describe("frame-aligned conversation projection", () => {
  test("1000 token updates publish once per frame without losing text", () => {
    const qa = setup();
    const renders = vi.fn();
    const stop = watch(qa.displayed, renders, { flush: "sync" });
    let text = "";
    for (let i = 0; i < 1000; i++) {
      text += i % 2 ? "中文" : "🙂";
      qa.state.messages = [message(text)];
    }
    expect(qa.clock.request).toHaveBeenCalledTimes(1);
    expect(renders).not.toHaveBeenCalled();
    expect(qa.state.messages[0].content).toBe(text);
    qa.paint();
    expect(renders).toHaveBeenCalledTimes(1);
    expect(qa.displayed.value[0].content).toBe(text);
    stop(); qa.scope.stop();
  });
  test("completion or interruption immediately flushes the last characters", () => {
    const qa = setup();
    qa.state.messages = [message("保留部分")];
    qa.state.messages = [message("保留部分与最后一字", "interrupted")];
    qa.state.streaming = false;
    expect(qa.displayed.value[0].content).toBe("保留部分与最后一字");
    expect(qa.displayed.value[0].status).toBe("interrupted");
    expect(qa.callbacks.size).toBe(0);
    qa.scope.stop();
  });
  test("a paused frame never blocks reception and resumes with the latest complete prefix", () => {
    const qa = setup();
    qa.state.messages = [message("前半段")];
    qa.state.messages = [message("前半段与后台收到的后半段")];
    expect(qa.displayed.value[0].content).toBe("");
    expect(qa.state.messages[0].content).toBe("前半段与后台收到的后半段");
    qa.paint();
    expect(qa.displayed.value[0].content).toBe(qa.state.messages[0].content);
    qa.scope.stop();
  });
  test("switching topics flushes immediately and cancels the old pending frame", () => {
    const qa = setup();
    qa.state.messages = [message("A 正在写")];
    qa.state.messages = [{ ...message("B 的消息"), topicId: "b" }];
    qa.state.topicId = "b";
    expect(qa.displayed.value[0].topicId).toBe("b");
    expect(qa.callbacks.size).toBe(0);
    qa.paint();
    expect(qa.displayed.value[0].content).toBe("B 的消息");
    qa.scope.stop();
  });
  test("leaving the chat disposes its pending frame", () => {
    const qa = setup();
    qa.state.messages = [message("尚未显示")];
    qa.scope.stop();
    expect(qa.callbacks.size).toBe(0);
    qa.state.messages = [message("已离开")];
    expect(qa.callbacks.size).toBe(0);
  });
});
