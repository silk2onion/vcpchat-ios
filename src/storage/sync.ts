import type { Snapshot, SyncCommit } from "../sync/types";
// A sync transaction may only replace records in its explicit, namespaced checkpoint.
export function validateSyncCommit(commit: SyncCommit, current: Snapshot) {
  const owners = new Set(
    [
      ...commit.after.agents,
      ...commit.after.groups,
      ...commit.before.agents,
      ...commit.before.groups,
    ]
      .filter((r) => r.id.startsWith("sync:"))
      .map((r) => r.id),
  );
  const topics = new Set(
    [...commit.after.topics, ...commit.before.topics]
      .filter((r) => owners.has(r.ownerId))
      .map((r) => r.id),
  );
  const permitted = (
    name: string,
    row: { id: string; ownerId?: string; topicId?: string },
  ) =>
    name === "topics"
      ? owners.has(row.ownerId ?? "")
      : name === "messages"
        ? topics.has(row.topicId ?? "")
        : row.id.startsWith("sync:");
  for (const name of ["agents", "groups", "topics", "messages"] as const) {
    const existing = new Map(current[name].map((row) => [row.id, row]));
    const before = new Map(commit.before[name].map((row) => [row.id, row]));
    for (const row of commit.after[name]) {
      if (!permitted(name, row))
        throw new Error("同步身份无效，未修改本机数据");
      if (existing.has(row.id) && !before.has(row.id))
        throw new Error("同步身份与已有数据冲突，未覆盖");
    }
    for (const row of before.values()) {
      if (
        !permitted(name, row) ||
        JSON.stringify(existing.get(row.id)) !== JSON.stringify(row)
      )
        throw new Error("同步期间本机内容已改变，未覆盖；请重新同步");
    }
  }
}
