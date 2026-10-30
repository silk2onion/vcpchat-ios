import type { Agent, Group, Topic, ChatMessage } from "../domain";
export type OwnerType = "agent" | "group";
export type Json = Record<string, unknown>;
export interface Identity { entityType: "owner" | "topic"; ownerType: OwnerType; ownerId: string; topicId?: string }
export interface Shadow extends Identity { localId?: string; data: Json; configHash: string; contentHash: string; updatedAt: number; deletedAt?: number }
export interface WireMessage extends Json { id: string; localId?: string; role: string; content: string; timestamp: number; updatedAt: number; contentHash: string; attachments?: Json[] }
export interface AvatarShadow { ownerType: OwnerType | "user"; ownerId: string; binaryHash: string; updatedAt: number; deletedAt?: number; image?: string }
export interface Snapshot { agents: Agent[]; groups: Group[]; topics: Topic[]; messages: ChatMessage[] }
export interface SyncProfile { id: string; endpoint: string; entities: Record<string, Shadow>; messages: Record<string, WireMessage[]>; avatars: Record<string, AvatarShadow>; messageDeletes: Record<string, Record<string,number>>; lastSync: number; checkpoint?: { at: number; before: Snapshot; after: Snapshot; profile: Omit<SyncProfile,"checkpoint"> } }
export interface SyncVault { localVersions?: Record<string,number>; profiles: Record<string, SyncProfile> }
export interface SyncCommit { before: Snapshot; after: Snapshot; vault: SyncVault }
export interface LocalFile { id: string; name: string; mime: string; size: number; addedAt: number; bytes: Uint8Array; source?: string }
export function identityKey(v: Identity): string { return [v.entityType,v.ownerType,v.ownerId,...(v.entityType === "topic" ? [v.topicId] : [])].join("\0"); }
export function topicKey(v: Pick<Identity,"ownerType"|"ownerId"|"topicId">): string { return [v.ownerType,v.ownerId,v.topicId].join("\0"); }
export function localId(profile: SyncProfile, kind: string, id: string, owner = ""): string { return `sync:${profile.id}:${kind}:${encodeURIComponent(owner)}:${encodeURIComponent(id)}`; }
export const emptyVault = (): SyncVault => ({ profiles: {} });
export const emptySnapshot = (): Snapshot => ({ agents: [], groups: [], topics: [], messages: [] });
