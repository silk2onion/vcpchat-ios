import type { WireMessage } from "../types";
export class BoundedWarnings { count: number; samples: string[]; constructor(limit?: number); push(message: string): void }
export function canonicalizeMessage(value: unknown, topicId: string, warnings?: BoundedWarnings): WireMessage;
export function canonicalizeTopicFrame(value: unknown): { frame: { topicId: string; ownerType?: "agent"|"group"; ownerId?: string; messages: WireMessage[] }; warningCount: number; warningSamples: string[] };
