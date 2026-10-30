/** IME confirmation is never a send action, including WebKit's legacy 229 event. */
export function shouldSendOnEnter(
  event: Pick<KeyboardEvent, "key" | "keyCode" | "isComposing" | "metaKey" | "ctrlKey" | "shiftKey" | "altKey">,
  enterSends: boolean,
): boolean {
  if (event.key !== "Enter" || event.isComposing || event.keyCode === 229) return false;
  return event.metaKey || event.ctrlKey || (enterSends && !event.shiftKey && !event.altKey);
}
