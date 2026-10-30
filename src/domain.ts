export type ThemeId = "ink" | "paper" | "aurora";
export type EndpointMode = "standard" | "vcp-tools";
export type GroupMode = "rotate" | "mention" | "all";
export type OwnerType = "agent" | "group";
export type MessageStatus = "complete" | "streaming" | "error" | "stopped";

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
}

export interface Agent {
  id: string;
  name: string;
  systemPrompt: string;
  model: string;
  temperature: number | null;
  createdAt: number;
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
  };
}

export function secretsOf(settings: Settings): string[] {
  return [settings.apiKey, settings.logKey, settings.adminPassword].filter((value) => value.length >= 4);
}
