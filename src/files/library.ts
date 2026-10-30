import { getRepository } from "../storage";
import { computeBinaryHash } from "../sync/upstream/hash.js";
import type { LocalFile } from "../sync/types";
import { base64,bytesFromDataUrl } from "./bytes";
import { isTauri } from "../protocol/http";
export function mimeFor(name:string):string {const ext=name.split(".").pop()?.toLowerCase();return ({png:"image/png",jpg:"image/jpeg",jpeg:"image/jpeg",webp:"image/webp",gif:"image/gif",pdf:"application/pdf",txt:"text/plain",md:"text/markdown",json:"application/json",csv:"text/csv",html:"text/html"} as Record<string,string>)[ext??""]??"application/octet-stream";}
export async function addFile(name:string,bytes:Uint8Array,mime=mimeFor(name),source="本机导入"):Promise<LocalFile>{
  if(bytes.length>20_000_000)throw new Error("本机文件库单个文件上限20MB");const repo=getRepository(),id=computeBinaryHash(bytes),existing=await repo.getFile(id);
  const file:LocalFile=existing??{id,name,mime,size:bytes.length,addedAt:Date.now(),bytes,source};if(!existing)await repo.saveFile(file);
  // Only mark imported sync attachments available; original local histories remain unchanged.
  const snapshot=await repo.readSnapshot();const topics=new Set(snapshot.topics.filter((t)=>t.ownerId.startsWith("sync:")).map((t)=>t.id));
  for(const message of snapshot.messages.filter((m)=>topics.has(m.topicId)&&m.attachments.some((a)=>a.hash===id&&a.desktopOnly))){
    message.attachments=message.attachments.map((a)=>a.hash===id?{...a,desktopOnly:false,...(mime.startsWith("image/")?{dataUrl:`data:${mime};base64,${base64(bytes)}`}:{}),...(mime.startsWith("text/")&&bytes.length<=200_000?{text:new TextDecoder().decode(bytes)}:{})}:a);await repo.saveMessage(message);
  }
  return file;
}
export async function collectHistoryFiles():Promise<number>{const repo=getRepository(),snapshot=await repo.readSnapshot();let count=0;for(const message of snapshot.messages)for(const a of message.attachments){if(a.desktopOnly)continue;const bytes=a.dataUrl?bytesFromDataUrl(a.dataUrl):a.text!==undefined?new TextEncoder().encode(a.text):null;if(bytes){await addFile(a.name,bytes,a.mime,"聊天附件副本");count++;}}return count;}
export async function exportFile(file:LocalFile):Promise<string>{
  if(isTauri()){const {invoke}=await import("@tauri-apps/api/core");return invoke("export_file",{name:file.name,bytes:Array.from(file.bytes)});}
  const a=document.createElement("a"),url=URL.createObjectURL(new Blob([file.bytes as Uint8Array<ArrayBuffer>],{type:file.mime}));a.href=url;a.download=file.name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);return "已交给浏览器保存";
}
