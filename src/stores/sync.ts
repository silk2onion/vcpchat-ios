import { defineStore } from "pinia";
import { ref } from "vue";
import { getRepository } from "../storage";
import { useSettingsStore } from "./settings";
import { useLibraryStore } from "./library";
import { secretsOf } from "../domain";
import { redactSecrets } from "../protocol/redact";
import { managed } from "../sync/projection";
import { runSync, freshProfile, type SyncMode } from "../sync/client";
import { createSyncHttp, syncEndpoint, canceled } from "../sync/transport";
import type { SyncProfile } from "../sync/types";
export const useSyncStore=defineStore("sync",()=>{
  const busy=ref(false),phase=ref(""),error=ref(""),lastSync=ref(0),summary=ref(""),warnings=ref<string[]>([]),canRestore=ref(false);
  let controller:AbortController|null=null;
  async function load(){const repo=getRepository(),s=useSettingsStore().settings;if(!s.syncHttpUrl.trim())return;try{const p=(await repo.getSyncVault()).profiles[syncEndpoint(s.syncHttpUrl)];lastSync.value=p?.lastSync??0;canRestore.value=Boolean(p?.checkpoint);}catch{lastSync.value=0;canRestore.value=false;}}
  async function start(mode:SyncMode){
    if(busy.value)return;const settings=useSettingsStore().settings;if(!settings.syncToken.trim()||!settings.syncWsUrl.trim()||!settings.syncHttpUrl.trim()){error.value="先填写桌面同步地址和 Token";return;}
    if(useLibraryStore().runningTopics.length){error.value="请等正在生成的回复结束后同步";return;}
    const s={...settings},repo=getRepository();busy.value=true;error.value="";summary.value="";warnings.value=[];controller=new AbortController();const signal=controller.signal;
    try{
      const endpoint=syncEndpoint(s.syncHttpUrl),vault=await repo.getSyncVault(),old=vault.profiles[endpoint]??freshProfile(endpoint);
      const before=managed(await repo.readSnapshot(),old);const http=await createSyncHttp();
      const result=await runSync({httpUrl:s.syncHttpUrl,wsUrl:s.syncWsUrl,token:s.syncToken,mode,http,profile:old,local:before,versions:vault.localVersions,signal,progress:(text)=>phase.value=text,event:(v)=>{if(v.level==="warn"||v.level==="error")warnings.value.push(redactSecrets(String(v.message??"桌面同步提示"),secretsOf(s)));}});
      canceled(signal);if(syncEndpoint(useSettingsStore().settings.syncHttpUrl)!==endpoint||useSettingsStore().settings.syncToken!==s.syncToken)throw new Error("同步设置已改变，未写入本机");
      const {checkpoint:_checkpoint,...previous}=old;
      const profile:SyncProfile={...result.profile,checkpoint:{at:Date.now(),before,after:result.after,profile:previous}};
      vault.profiles[endpoint]=profile;phase.value="正在保存本机恢复点与会话…";
      await repo.commitSync({before,after:result.after,vault});lastSync.value=profile.lastSync;canRestore.value=true;
      await useLibraryStore().load();summary.value=`已同步 ${result.after.agents.length} 位 Agent、${result.after.groups.length} 个群组、${result.after.topics.length} 个会话、${result.after.messages.length} 条消息`;
      phase.value=warnings.value.length?"已完成，有桌面提示":"同步完成";
    }catch(caught){error.value=redactSecrets(caught instanceof Error?caught.message:String(caught),secretsOf(s));phase.value=signal.aborted?"已取消；尚未应用的内容没有写入本机":"同步未完成";}
    finally{busy.value=false;controller=null;}
  }
  function cancel(){controller?.abort();}
  async function restore(){
    if(busy.value||useLibraryStore().runningTopics.length)return;const s=useSettingsStore().settings,repo=getRepository(),endpoint=syncEndpoint(s.syncHttpUrl),vault=await repo.getSyncVault(),current=vault.profiles[endpoint],point=current?.checkpoint;if(!point)return;
    const before=managed(await repo.readSnapshot(),current);vault.profiles[endpoint]=point.profile;
    await repo.commitSync({before,after:point.before,vault});await useLibraryStore().load();await load();summary.value="已恢复本机到上次同步前；桌面未被回滚";
  }
  return {busy,phase,error,lastSync,summary,warnings,canRestore,load,start,cancel,restore};
});
