export function stableStringify(value: unknown, key?: string): string;
export function computeBinaryHash(value: Uint8Array): string;
export function computeDtoHash(value: Record<string, unknown>, fields: string[]): string;
export function computeMessageFingerprint(value: Record<string, unknown>): string;
export function computeMessageLeafHash(id: string, hash: string): string;
export function computeTopicLeafHash(id: string, configHash: string, contentHash: string): string;
export function computeAggregatedHash(hashes: string[]): string;
