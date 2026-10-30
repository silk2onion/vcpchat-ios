import { identityKey, topicKey, emptySnapshot, type Identity, type Json, type Shadow, type SyncProfile, type Snapshot } from "./types";
import { object, string, time, fields, overlayLocal, refreshRoots, toLocal, entityId } from "./projection";
import { SyncSocket, SyncHttp, socketUrl, syncEndpoint, canceled, syncError, type createSyncHttp } from "./transport";
import { computeBinaryHash, computeDtoHash, computeMessageFingerprint } from "./upstream/hash.js";
import { canonicalizeTopicFrame } from "./upstream/canonical.js";
import { bytesFromDataUrl, dataUrlFromBytes } from "../files/bytes";
export type SyncMode = "pull" | "both";
export interface SyncOptions { httpUrl:string; wsUrl:string; token:string; mode:SyncMode; signal:AbortSignal; http:Awaited<ReturnType<typeof createSyncHttp>>; profile:SyncProfile; local:Snapshot; progress:(text:string)=>void; versions?:Record<string,number>; event?:(v:Json)=>void }
function rows(v:unknown): Json[] { if(!Array.isArray(v))throw new Error("同步响应缺少列表");return v.map(object); }
function identity(v:Json, entityType:Identity["entityType"]):Identity { if(!["agent","group"].includes(string(v.ownerType))||!string(v.ownerId)||(entityType==="topic"&&!string(v.topicId)))throw new Error("同步返回身份不完整");return {entityType,ownerType:v.ownerType as Identity["ownerType"],ownerId:string(v.ownerId),...(entityType==="topic"?{topicId:string(v.topicId)}:{})}; }
function manifestItem(e: Shadow): Json { const id={ownerType:e.ownerType,ownerId:e.ownerId,...(e.entityType==="topic"?{topicId:e.topicId}:{})};return e.deletedAt!==undefined ? {...id,deletedAt:e.deletedAt} : {...id,configHash:e.configHash,updatedAt:e.updatedAt,...(e.entityType==="owner"?{contentHash:e.contentHash}:{})}; }
function changed(left:SyncProfile,right:SyncProfile){return JSON.stringify(Object.values(left.entities).map((e)=>[identityKey(e),e.configHash,e.deletedAt]))!==JSON.stringify(Object.values(right.entities).map((e)=>[identityKey(e),e.configHash,e.deletedAt])) || JSON.stringify(left.messages)!==JSON.stringify(right.messages)||JSON.stringify(left.avatars)!==JSON.stringify(right.avatars);}
function stripIdentity(e:Identity):Identity{return {entityType:e.entityType,ownerType:e.ownerType,ownerId:e.ownerId,...(e.entityType==="topic"?{topicId:e.topicId}:{})};}
export async function runSync(o:SyncOptions):Promise<{profile:SyncProfile;after:Snapshot}> {
  const p=structuredClone(o.profile);p.messageDeletes??={};
  const newlyDeleted=overlayLocal(p,o.local,Date.now(),o.versions);
  for(const [key,list] of Object.entries(newlyDeleted)){p.messageDeletes[key]??={};for(const d of list)p.messageDeletes[key][d.msgId]=d.deletedAt;}
  for(const e of Object.values(p.entities).filter((e)=>e.entityType==="owner"&&e.ownerType==="agent"&&e.deletedAt===undefined)){
    const row=o.local.agents.find((a)=>a.id===entityId(p,e));const key=`${e.ownerType}\0${e.ownerId}`, previous=p.avatars[key];
    if(row?.avatarUrl?.startsWith("data:")&&row.avatarUrl!==previous?.image){const bytes=bytesFromDataUrl(row.avatarUrl);p.avatars[key]={ownerType:e.ownerType,ownerId:e.ownerId,binaryHash:computeBinaryHash(bytes),updatedAt:Date.now(),image:row.avatarUrl};}
    else if(previous?.image && !row?.avatarUrl)p.avatars[key]={...previous,deletedAt:Date.now(),image:undefined};
  }
  if(o.mode==="pull" && changed(o.profile,p))throw new Error("此同步来源在本机有改动。请选择“双向同步”写回；本次没有覆盖内容");
  const ws=new SyncSocket(socketUrl(o.wsUrl,o.token),o.signal,o.event);const http=new SyncHttp(o.http,syncEndpoint(o.httpUrl),o.token,o.signal);
  try {
    o.progress("正在核对同步协议…");
    const version=await ws.request({type:"VERSION_CHECK",versions:[{component:"mobile_app",version:"0.2.1"},{component:"wire",version:"1.5"}]},"VERSION_ACK");
    const versions=rows(version.versions);if(versions.length!==2||versions.find((v)=>v.component==="wire")?.version!=="1.5"||!versions.some((v)=>v.component==="desktop_plugin")||!["cds","legacy"].includes(string(version.backendMode)))throw new Error("桌面同步协议不兼容，需要 Wire 1.5");
    async function metadata(entityType:Identity["entityType"]) {
      const phase=entityType==="owner"?"owner_metadata":"topic_metadata";
      o.progress(entityType==="owner"?"正在同步联系人与群组…":"正在同步会话列表…");await ws.send({type:"PHASE_START",phase});
      const items=Object.values(p.entities).filter((e)=>e.entityType===entityType && (e.entityType==="owner" || p.entities[identityKey({entityType:"owner",ownerType:e.ownerType,ownerId:e.ownerId})]?.deletedAt===undefined));
      const owners=Object.values(p.entities).filter((e)=>e.entityType==="owner"&&e.deletedAt===undefined).map((e)=>({ownerType:e.ownerType,ownerId:e.ownerId}));
      const result=await ws.request({type:"SYNC_MANIFEST_REQUEST",manifestType:entityType,items:items.map(manifestItem),...(entityType==="topic"?{targetedOwners:owners}:{})},"SYNC_MANIFEST_RESULT");
      if(result.manifestType!==entityType)throw new Error("同步清单类型不符");const actions=rows(result.results);const seen=new Set<string>();
      const pulls:Identity[]=[],pushes:Shadow[]=[];
      for(const action of actions){
        const id=identity(action,entityType),key=identityKey(id);if(seen.has(key))throw new Error("同步清单有重复身份");seen.add(key);
        if(entityType==="topic"&&!owners.some((owner)=>owner.ownerType===id.ownerType&&owner.ownerId===id.ownerId))throw new Error("会话来源与本轮同步范围不符");
        const e=p.entities[key];
        if(action.action==="PULL")pulls.push(id);
        else if(action.action==="PUSH"){if(o.mode!=="both")throw new Error("桌面缺少本机同步项，请使用双向同步；本机内容已保留");if(!e)throw new Error("写回项在本机不存在");pushes.push(e);}
        else if(action.action==="PULL_DELETE"){const deletedAt=time(action.deletedAt,-1);if(deletedAt<0)throw new Error("删除记录时间无效");if(e)e.deletedAt=deletedAt;}
        else if(action.action==="PUSH_DELETE"){
          if(o.mode!=="both")throw new Error("本机有待同步删除，请使用双向同步");if(!e||e.deletedAt===undefined)throw new Error("本机删除记录缺失");
          await ws.send({type:"SYNC_ENTITY_DELETE",targetType:entityType,ownerType:id.ownerType,ownerId:id.ownerId,...(entityType==="topic"?{topicId:id.topicId}:{}),deletedAt:e.deletedAt});
        }else if(action.action!=="SKIP")throw new Error("桌面返回未知同步动作");
      }
      // Original fields, including group extensions, survive round trips in the shadow DTO.
      for(let offset=0;offset<pulls.length;offset+=40){
        const requested=pulls.slice(offset,offset+40);const response=rows((await http.json("/entities/pull",{items:requested})).results);if(response.length!==requested.length)throw new Error("实体拉取不完整");
        const remaining=new Set(requested.map(identityKey));
        for(const result of response){const id=identity(result,entityType),key=identityKey(id);if(!remaining.delete(key))throw new Error("实体返回身份重复或越界");if(result.ok!==true)throw new Error(syncError(result.error));
          const data=object(result.data),previous=p.entities[key];const entry:Shadow={...id,...(previous?.localId?{localId:previous.localId}:{}),data,configHash:"",contentHash:previous?.contentHash??"",updatedAt:time(data.updatedAt,0)};
          entry.configHash=computeDtoHash(data,fields(entry));if(entityType==="topic"&&(data.configHash!==entry.configHash||typeof data.updatedAt!=="number"))throw new Error("会话版本校验失败，未写入");p.entities[key]=entry;
        }
      }
      for(const e of pushes){const result=rows((await http.json("/entities/push",{items:[{...stripIdentity(e),data:{...e.data,...(e.entityType==="topic"?{configHash:e.configHash,updatedAt:e.updatedAt}:{})}}]})).results);if(result.length!==1||identityKey(identity(result[0],entityType))!==identityKey(e)||result[0].ok!==true)throw new Error(syncError(result[0]?.error));}
      if(entityType==="topic") await ws.send({type:"PHASE_COMPLETED",phase});
    }
    await metadata("owner");
    o.progress("正在同步头像…");
    const avatarItems=Object.values(p.avatars).map((a)=>a.deletedAt!==undefined?{ownerType:a.ownerType,ownerId:a.ownerId,deletedAt:a.deletedAt}:{ownerType:a.ownerType,ownerId:a.ownerId,binaryHash:a.binaryHash,updatedAt:a.updatedAt});
    const avatarResult=await ws.request({type:"SYNC_MANIFEST_REQUEST",manifestType:"avatar",items:avatarItems},"SYNC_MANIFEST_RESULT");
    if(avatarResult.manifestType!=="avatar")throw new Error("头像清单类型不符");
    for(const action of rows(avatarResult.results)){
      const ownerType=string(action.ownerType),ownerId=string(action.ownerId);if(!["agent","group","user"].includes(ownerType)||!ownerId||(ownerType==="user"&&ownerId!=="user_avatar"))throw new Error("头像身份无效");
      const key=`${ownerType}\0${ownerId}`,path=`/avatars/${action.action==="PUSH"?"push":"pull"}?${new URLSearchParams({ownerType,ownerId})}`;
      if(action.action==="PULL"){const bytes=await http.binary(path);const image=dataUrlFromBytes(bytes);p.avatars[key]={ownerType:ownerType as "agent"|"group"|"user",ownerId,binaryHash:computeBinaryHash(bytes),updatedAt:0,image};}
      else if(action.action==="PUSH"){if(o.mode!=="both"||!p.avatars[key]?.image)throw new Error("头像需要双向同步写回");const ack=object(JSON.parse(new TextDecoder().decode(await http.binary(path,bytesFromDataUrl(p.avatars[key].image!),p.avatars[key].image!.split(";")[0].slice(5)))));if(ack.ok!==true||ack.ownerId!==ownerId||ack.ownerType!==ownerType)throw new Error("头像写回未确认");}
      else if(action.action==="PULL_DELETE"){if(p.avatars[key])p.avatars[key]={...p.avatars[key],deletedAt:time(action.deletedAt),image:undefined};}
      else if(action.action==="PUSH_DELETE"){if(o.mode!=="both")throw new Error("头像删除需要双向同步");await ws.send({type:"SYNC_ENTITY_DELETE",targetType:"avatar",ownerType,ownerId,deletedAt:p.avatars[key].deletedAt});}
      else if(action.action!=="SKIP")throw new Error("头像同步动作无效");
    }
    await ws.send({type:"PHASE_COMPLETED",phase:"owner_metadata"});await metadata("topic");
    o.progress("正在核对消息差分…");await ws.send({type:"PHASE_START",phase:"messages"});
    const topics=Object.values(p.entities).filter((e)=>e.entityType==="topic"&&e.deletedAt===undefined&&p.entities[identityKey({entityType:"owner",ownerType:e.ownerType,ownerId:e.ownerId})]?.deletedAt===undefined);
    for(let i=0;i<topics.length;i++){
      canceled(o.signal);const e=topics[i],key=topicKey(e);o.progress(`正在同步消息 ${i+1}/${topics.length}…`);
      const messages=Object.fromEntries((p.messages[key]??[]).map((m)=>[m.id,{messageHash:m.contentHash,updatedAt:m.updatedAt}]));for(const [id,deletedAt] of Object.entries(p.messageDeletes[key]??{}))messages[id]={deletedAt} as unknown as {messageHash:string;updatedAt:number};
      const response=await ws.request({type:"SYNC_MESSAGE_DIFF_REQUEST",topics:[{ownerType:e.ownerType,ownerId:e.ownerId,topicId:e.topicId,contentHash:e.contentHash,messages}]},"SYNC_MESSAGE_DIFF_RESULT");
      const result=rows(response.results);if(result.length!==1||topicKey(identity(result[0],"topic"))!==key||result[0].ok!==true)throw new Error(syncError(result[0]?.error));const diff=result[0];
      const wanted=Array.isArray(diff.pullMessageIds)?diff.pullMessageIds.map((v)=>string(v)):null;if(!wanted||new Set(wanted).size!==wanted.length||wanted.some((v)=>!v))throw new Error("消息差分格式无效");
      if(wanted.length){
        const frames=await http.ndjson("/messages/pull",{topics:[{ownerType:e.ownerType,ownerId:e.ownerId,topicId:e.topicId,messageIds:wanted}]});if(frames.length!==1||frames[0].kind!=="topic"||topicKey(identity(frames[0],"topic"))!==key)throw new Error("消息返回身份不符");
        const raw=frames[0];const canonical=canonicalizeTopicFrame(raw);const received=canonical.frame.messages;
        if(received.length!==wanted.length||received.some((m)=>!wanted.includes(m.id)))throw new Error("消息返回不完整");
        const rawMessages=rows(raw.messages);for(const m of received){const original=rawMessages.find((v)=>v.id===m.id)!;if(original.contentHash!==computeMessageFingerprint(m)||time(original.updatedAt,-1)<0)throw new Error("消息指纹或版本校验失败");m.updatedAt=time(original.updatedAt);m.contentHash=string(original.contentHash);const old=p.messages[key]?.find((v)=>v.id===m.id);if(old?.localId)m.localId=old.localId;}
        p.messages[key]=[...(p.messages[key]??[]).filter((m)=>!wanted.includes(m.id)),...received].sort((a,b)=>a.timestamp-b.timestamp||a.id.localeCompare(b.id));
      }
      for(const deletion of rows(diff.deleteMessages)){const id=string(deletion.msgId),at=time(deletion.deletedAt,-1);if(!id||at<0)throw new Error("消息删除记录无效");p.messageDeletes[key]??={};p.messageDeletes[key][id]=at;p.messages[key]=(p.messages[key]??[]).filter((m)=>m.id!==id);}
      if(diff.pushTopic===true){
        if(o.mode!=="both")throw new Error("此会话有需要写回的消息，请使用双向同步；未覆盖本机内容");
        const frame={kind:"topic",topicId:e.topicId,ownerType:e.ownerType,ownerId:e.ownerId,messages:(p.messages[key]??[]).map(({localId:_localId,...m})=>m),deletedMessages:Object.entries(p.messageDeletes[key]??{}).map(([msgId,deletedAt])=>({msgId,deletedAt}))};
        const acks=await http.ndjson("/messages/push",JSON.stringify(frame)+"\n");if(acks.length!==1||acks[0].kind!=="topic"||topicKey(identity(acks[0],"topic"))!==key)throw new Error("消息写回未得到确认");
      }else if(diff.pushTopic!==false)throw new Error("消息写回状态无效");
    }
    const sessionId=Date.now(),attemptId=1,nonce=crypto.randomUUID();const ack=await ws.request({type:"PHASE_COMPLETED",phase:"messages",sessionId,attemptId,nonce},"PHASE_ACK");if(ack.phase!=="messages"||ack.sessionId!==sessionId||ack.attemptId!==attemptId||ack.nonce!==nonce)throw new Error("同步最终确认不匹配，未写入本机");
    canceled(o.signal);refreshRoots(p);p.lastSync=Date.now();return {profile:p,after:toLocal(p,o.local)};
  }finally{ws.close();}
}
export function freshProfile(endpoint:string):SyncProfile{return {id:crypto.randomUUID(),endpoint,entities:{},messages:{},avatars:{},messageDeletes:{},lastSync:0};}
export const initialSyncSnapshot=emptySnapshot;
