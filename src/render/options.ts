import type { Settings } from "../domain";

export interface RenderOptions {
  /** Off means plain sanitized Markdown with no DOM enhancement and no heavy libraries. */
  rich: boolean;
  code: boolean;
  math: boolean;
  mermaid: boolean;
  html: boolean;
  motion: boolean;
  media: boolean;
}

export function fullRenderOptions(): RenderOptions {
  return { rich: true, code: true, math: true, mermaid: true, html: true, motion: true, media: true };
}

export function lightRenderOptions(): RenderOptions {
  return { rich: false, code: false, math: false, mermaid: false, html: false, motion: false, media: false };
}

export function renderOptionsFrom(settings: Settings): RenderOptions {
  return effectiveOptions({
    rich: settings.richRender,
    code: settings.renderCode,
    math: settings.renderMath,
    mermaid: settings.renderMermaid,
    html: settings.renderHtml,
    motion: settings.renderMotion,
    media: settings.renderMedia,
  });
}

/** Effective switches: every sub-switch is off when the master switch is off. */
export function effectiveOptions(options: RenderOptions): RenderOptions {
  return options.rich ? options : lightRenderOptions();
}

export function optionsKey(options: RenderOptions): string {
  const effective = effectiveOptions(options);
  return (["rich", "code", "math", "mermaid", "html", "motion", "media"] as const).map((key) => (effective[key] ? "1" : "0")).join("");
}
