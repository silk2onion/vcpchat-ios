export type ThemeId = "ink" | "paper" | "aurora";
export type EndpointMode = "standard" | "vcp-tools";
export type GroupMode = "rotate" | "mention" | "all";
export type OwnerType = "agent" | "group";
export type MessageStatus =
  | "complete"
  | "streaming"
  | "error"
  | "stopped"
  | "interrupted";

export interface RegexRule {
  id: string;
  title: string;
  findPattern: string;
  replaceWith: string;
  applyToRoles: ("user" | "assistant")[];
  applyToFrontend: boolean;
  applyToContext: boolean;
  minDepth: number;
  maxDepth: number;
  enabled: boolean;
}

export interface Settings {
  serverUrl: string;
  apiKey: string;
  logUrl: string;
  logKey: string;
  adminUsername: string;
  adminPassword: string;
  userName: string;
  theme: ThemeId;
  endpointMode: EndpointMode;
  defaultModel: string;
  temperature: number;
  sendTemperature: boolean;
  richRender: boolean;
  renderCode: boolean;
  renderMath: boolean;
  renderMermaid: boolean;
  renderHtml: boolean;
  renderMotion: boolean;
  renderMedia: boolean;
  mainAgentId: string;
  enterSends: boolean;
  modelCatalog: { endpoint: string; ids: string[]; updatedAt: number; recent: string[] } | null;
  wallpaper: "forest" | "leaves" | "none" | "custom";
  wallpaperCustom: string;
  wallpaperDim: number;
  wallpaperBlur: number;
  ttsMode: "sovits" | "mimo";
  ttsUrl: string;
  ttsKey: string;
  ttsVoice: string;
  ttsModel: string;
  ttsSpeed: number;
  ttsDirector: string;
  regexRules: RegexRule[];
}

export interface Agent {
  id: string;
  name: string;
  systemPrompt: string;
  model: string;
  temperature: number | null;
  createdAt: number;
  avatar?: string;
  avatarUrl?: string;
  description?: string;
  voice?: string;
  speechSpeed?: number;
  speechDirector?: string;
  regexRules?: RegexRule[];
}

export interface Group {
  id: string;
  name: string;
  memberIds: string[];
  mode: GroupMode;
  createdAt: number;
}

export interface Topic {
  id: string;
  ownerType: OwnerType;
  ownerId: string;
  title: string;
  turnIndex: number;
  createdAt: number;
  updatedAt: number;
}

export interface Attachment {
  id: string;
  name: string;
  mime: string;
  kind: "image" | "text";
  dataUrl?: string;
  text?: string;
}

export interface ChatMessage {
  id: string;
  topicId: string;
  role: "user" | "assistant";
  content: string;
  reasoning: string;
  agentId?: string;
  authorName?: string;
  attachments: Attachment[];
  createdAt: number;
  status: MessageStatus;
  error?: string;
  /** Id of the native stream still producing this reply; lets a reloaded page re-attach. */
  streamId?: string;
  /** Length of content and reasoning before the current stream, i.e. where a continuation starts. */
  streamOffset?: { content: number; reasoning: number };
}

export interface LocalNote {
  id: string;
  title: string;
  body: string;
  updatedAt: number;
}

export interface LogEntry {
  id: string;
  channel: "log" | "info";
  title: string;
  detail: string;
  createdAt: number;
  payload?: Record<string, unknown>;
  seen?: boolean;
  decision?: { approved: boolean; reason: string; sentAt: number };
}

export const LIMITS = {
  maxImageBytes: 1_500_000,
  maxTextBytes: 200_000,
  maxAttachments: 4,
  historyMessages: 32,
  maxLogEntries: 200,
} as const;

export function defaultSettings(): Settings {
  return {
    serverUrl: "",
    apiKey: "",
    logUrl: "",
    logKey: "",
    adminUsername: "",
    adminPassword: "",
    userName: "",
    theme: "ink",
    endpointMode: "standard",
    defaultModel: "",
    temperature: 0.8,
    sendTemperature: false,
    richRender: true,
    renderCode: true,
    renderMath: true,
    renderMermaid: true,
    renderHtml: true,
    renderMotion: true,
    renderMedia: true,
    mainAgentId: "",
    enterSends: false,
    modelCatalog: null,
    wallpaper: "forest",
    wallpaperCustom: "",
    wallpaperDim: 58,
    wallpaperBlur: 0,
    ttsMode: "sovits",
    ttsUrl: "",
    ttsKey: "",
    ttsVoice: "",
    ttsModel: "mimo-v2.5-tts",
    ttsSpeed: 1,
    ttsDirector: "",
    regexRules: [],
  };
}

export function secretsOf(settings: Settings): string[] {
  return [settings.apiKey, settings.logKey, settings.adminPassword, settings.ttsKey].filter(
    (value) => value.length >= 4,
  );
}
