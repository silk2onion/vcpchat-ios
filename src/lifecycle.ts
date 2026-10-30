export interface LifecycleHandlers {
  hidden: () => void;
  visible: (hiddenForMs: number) => void;
}

/** Reports the app leaving and returning to the foreground, once per transition. */
export function watchAppLifecycle(handlers: LifecycleHandlers, target: Window = window): () => void {
  const doc = target.document;
  let hiddenAt: number | null = null;
  const onHidden = () => {
    if (hiddenAt !== null) return;
    hiddenAt = Date.now();
    handlers.hidden();
  };
  const onVisible = () => {
    if (hiddenAt === null) return;
    const away = Date.now() - hiddenAt;
    hiddenAt = null;
    handlers.visible(away);
  };
  const onChange = () => (doc.visibilityState === "hidden" ? onHidden() : onVisible());
  doc.addEventListener("visibilitychange", onChange);
  target.addEventListener("pagehide", onHidden);
  target.addEventListener("pageshow", onVisible);
  return () => {
    doc.removeEventListener("visibilitychange", onChange);
    target.removeEventListener("pagehide", onHidden);
    target.removeEventListener("pageshow", onVisible);
  };
}
