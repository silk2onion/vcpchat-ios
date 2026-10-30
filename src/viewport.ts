/** Keep the app frame attached to the visible viewport, including the iOS keyboard. */
export function installAppViewport(target: Window = window): () => void {
  const viewport = target.visualViewport;
  const root = target.document.documentElement;
  const update = () => {
    root.style.setProperty(
      "--app-height",
      `${viewport?.height ?? target.innerHeight}px`,
    );
    root.style.setProperty("--app-top", `${viewport?.offsetTop ?? 0}px`);
    root.dataset.keyboard = String(
      target.innerHeight - (viewport?.height ?? target.innerHeight) > 100,
    );
  };
  update();
  viewport?.addEventListener("resize", update);
  viewport?.addEventListener("scroll", update);
  target.addEventListener("resize", update);
  return () => {
    viewport?.removeEventListener("resize", update);
    viewport?.removeEventListener("scroll", update);
    target.removeEventListener("resize", update);
  };
}
