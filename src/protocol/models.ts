import type { Settings } from "../domain";
import { resolveModelsEndpoint } from "./endpoint";
import { formatHttpError, type HttpClient } from "./http";

export async function listModels(settings: Settings, http: HttpClient): Promise<string[]> {
  if (!settings.apiKey.trim()) throw new Error("先填写 API Key");
  const response = await http.request({
    method: "GET",
    url: resolveModelsEndpoint(settings.serverUrl),
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${settings.apiKey}`,
    },
  });
  if (response.status < 200 || response.status >= 300) {
    throw new Error(formatHttpError(response.status, response.body, [settings.apiKey, settings.logKey, settings.adminPassword]));
  }
  const json = JSON.parse(response.body) as { data?: { id?: string }[] };
  const ids = (json.data ?? []).map((item) => item.id).filter((id): id is string => Boolean(id));
  if (!ids.length) throw new Error("服务器没有返回模型");
  return ids;
}
