import { expect,test } from "vitest";
import { createHash } from "node:crypto";
import { computeDtoHash, computeMessageFingerprint, stableStringify } from "./upstream/hash.js";
import { canonicalizeTopicFrame } from "./upstream/canonical.js";
import { parseJsonWithoutDuplicateKeys } from "./upstream/json.js";
import { freshProfile } from "./client";
import { GROUP_FIELDS, fields, overlayLocal, refreshRoots, toLocal } from "./projection";
import { identityKey, type Shadow } from "./types";
test("browser hashing matches the upstream Node byte contract, integer temperatures and unicode keys",()=>{
 const dto={name:"Amadeus",temperature:1,systemPrompt:"你好",model:"case/ID"};const stable=stableStringify(dto);expect(stable).toContain('"temperature":1.0');expect(computeDtoHash(dto,Object.keys(dto))).toBe(createHash("sha256").update(stable).digest("hex"));
 const message={id:"m1",role:"assistant",content:"正文",timestamp:1793000000000,attachments:[{hash:"a".repeat(64)}]};
 const expected={id:"m1",role:"assistant",content:"正文",timestamp:1793000000000,attachmentHashes:["a".repeat(64)]};expect(computeMessageFingerprint(message)).toBe(createHash("sha256").update(stableStringify(expected)).digest("hex"));
 expect(()=>parseJsonWithoutDuplicateKeys('{"x":1,"x":2}')).toThrow("duplicate");
});
test("latest group fields and unknown extensions survive local round trips without false edits",()=>{
 const p=freshProfile("fixture");const owner:Shadow={entityType:"owner",ownerType:"group",ownerId:"group",data:{name:"协作",members:[],mode:"sequential",memberTags:{},groupPrompt:"群提示",invitePrompt:"请发言",useUnifiedModel:false,unifiedModel:"",enableContextMessageWindow:true,contextMessageWindowSize:88,tagMatchMode:"strict",createdAt:1,futureField:"保留"},configHash:"",contentHash:"",updatedAt:1};owner.configHash=computeDtoHash(owner.data,GROUP_FIELDS);p.entities[identityKey(owner)]=owner;refreshRoots(p);
 const local=toLocal(p);expect(local.groups[0].mode).toBe("all");expect(local.groups[0].systemPrompt).toBe("群提示");overlayLocal(p,local,123);expect(p.entities[identityKey(owner)].data.futureField).toBe("保留");expect(p.entities[identityKey(owner)].configHash).toBe(owner.configHash);
 local.groups[0].name="新名称";overlayLocal(p,local,456,{[`groups\0${local.groups[0].id}`]:321});expect(p.entities[identityKey(owner)].updatedAt).toBe(321);expect(p.entities[identityKey(owner)].data.contextMessageWindowSize).toBe(88);
 expect(computeDtoHash(p.entities[identityKey(owner)].data,fields(owner))).toBe(p.entities[identityKey(owner)].configHash);
});
test("canonical metadata is retained and malformed or tombstoned live messages fail closed",()=>{
 const frame=canonicalizeTopicFrame({topicId:"t",ownerType:"agent",ownerId:"a",messages:[{id:"m",role:"assistant",timestamp:1,updatedAt:2,content:"x",attachments:[{hash:"a".repeat(64),name:"report.pdf",type:"application/pdf",size:12}]}]});expect(frame.frame.messages[0].attachments?.[0].hash).toBe("a".repeat(64));expect(()=>canonicalizeTopicFrame({topicId:"t",messages:[{id:"m",role:"assistant",timestamp:1,status:"removed"}]})).toThrow();
});
