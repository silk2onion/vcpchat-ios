import "fake-indexeddb/auto";
import { beforeEach,expect,test } from "vitest";
import { createIndexedDbRepository } from "./indexeddb";
import { freshProfile } from "../sync/client";
import { emptySnapshot, type Snapshot } from "../sync/types";
beforeEach(async()=>{await new Promise<void>((resolve,reject)=>{const r=indexedDB.deleteDatabase("vcpchat-ios");r.onsuccess=()=>resolve();r.onerror=()=>reject(r.error);});});
const imported=():Snapshot=>({agents:[{id:"sync:source:agent:a",name:"桌面助手",systemPrompt:"",model:"remote",temperature:1,createdAt:1}],groups:[],topics:[{id:"sync:source:topic:t",ownerType:"agent",ownerId:"sync:source:agent:a",title:"桌面会话",createdAt:1,updatedAt:1,turnIndex:0}],messages:[{id:"sync:source:message:m",topicId:"sync:source:topic:t",role:"assistant",content:"历史",reasoning:"",attachments:[],createdAt:1,status:"complete"}]});
test("upgrading a real version-1 database adds sync/files without replacing old settings, history or avatars",async()=>{
 await new Promise<void>((resolve,reject)=>{const r=indexedDB.open("vcpchat-ios",1);r.onupgradeneeded=()=>{const db=r.result;db.createObjectStore("meta");for(const n of ["agents","groups","topics","messages","notes"])db.createObjectStore(n,{keyPath:"id"});};r.onsuccess=()=>{const db=r.result,tx=db.transaction(["meta","agents","messages"],"readwrite");tx.objectStore("meta").put({apiKey:"kept-fixture",userName:"丝巾"},"settings");tx.objectStore("agents").put({id:"agent_default",name:"原助手",avatarUrl:"data:image/png;base64,kept",systemPrompt:"不改",createdAt:1});tx.objectStore("messages").put({id:"message_default",topicId:"old",role:"assistant",content:"原历史",attachments:[]});tx.oncomplete=()=>{db.close();resolve();};};r.onerror=()=>reject(r.error);});
 const repo=createIndexedDbRepository();await repo.commitSync({before:emptySnapshot(),after:imported(),vault:{profiles:{fixture:freshProfile("fixture")}}});expect((await repo.getSettings()).apiKey).toBe("kept-fixture");expect((await repo.listAgents()).find((r)=>r.id==="agent_default")).toMatchObject({name:"原助手",systemPrompt:"不改",avatarUrl:"data:image/png;base64,kept"});expect((await repo.listMessages("old"))[0].content).toBe("原历史");
 await repo.saveFile({id:"file",name:"a.bin",mime:"application/octet-stream",size:3,addedAt:1,bytes:new Uint8Array([0,128,255])});expect((await repo.getFile("file"))?.bytes).toEqual(new Uint8Array([0,128,255]));
});
test("a concurrent edit aborts the entire sync transaction and never commits a partial checkpoint",async()=>{
 const repo=createIndexedDbRepository(),before=imported();await repo.commitSync({before:emptySnapshot(),after:before,vault:{profiles:{}}});await repo.saveMessage({...before.messages[0],content:"同步期间改动"});const after=imported();after.agents[0].name="不应保存";
 await expect(repo.commitSync({before,after,vault:{profiles:{x:freshProfile("x")}}})).rejects.toThrow("内容已改变");expect((await repo.listAgents())[0].name).toBe("桌面助手");expect((await repo.listMessages(before.topics[0].id))[0].content).toBe("同步期间改动");expect((await repo.getSyncVault()).profiles.x).toBeUndefined();
});
test("only owned sync records can be removed or replaced",async()=>{
 const repo=createIndexedDbRepository();await repo.saveAgent({id:"old",name:"保留",systemPrompt:"",model:"",temperature:null,createdAt:1});const original=(await repo.readSnapshot());await expect(repo.commitSync({before:original,after:emptySnapshot(),vault:{profiles:{}}})).rejects.toThrow();expect((await repo.listAgents())[0].id).toBe("old");
});
