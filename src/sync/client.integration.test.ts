import { expect,test } from "vitest";
import { runSync,freshProfile } from "./client";
import { createSyncHttp } from "./transport";
import { emptySnapshot } from "./types";
import { createMemoryRepository } from "../storage/memory";
import { FileClient } from "../files/client";
import { defaultSettings } from "../domain";
const enabled=Boolean(process.env.VCP_SYNC_FIXTURE);
test.skipIf(!enabled)("real upstream Wire 1.5 plugin imports duplicate raw IDs, round-trips group DTOs and writes replies back",async()=>{
 const http=await createSyncHttp();const opts={httpUrl:"http://127.0.0.1:43129",wsUrl:"ws://127.0.0.1:43131/",token:"sync-fixture-token",mode:"pull" as const,http,signal:new AbortController().signal,progress:()=>{}};
 const first=await runSync({...opts,profile:freshProfile(opts.httpUrl),local:emptySnapshot()});expect(first.after.agents).toHaveLength(2);expect(first.after.groups).toHaveLength(1);expect(first.after.topics).toHaveLength(3);expect(new Set(first.after.messages.map((m)=>m.id)).size).toBe(first.after.messages.length);
 const repo=createMemoryRepository();await repo.saveAgent({id:"agent_default",name:"原助手",systemPrompt:"保留",model:"",temperature:null,createdAt:1});await repo.commitSync({before:emptySnapshot(),after:first.after,vault:{profiles:{fixture:first.profile}}});expect((await repo.listAgents()).find((a)=>a.id==="agent_default")?.systemPrompt).toBe("保留");
 const second=await runSync({...opts,profile:first.profile,local:first.after});expect(second.after.messages).toEqual(first.after.messages);
 const changed=structuredClone(second.after);changed.agents[0].name+=" · Mac已回写";changed.messages[0].content+="\nMac 端修改";
 const written=await runSync({...opts,mode:"both",profile:second.profile,local:changed});expect(written.after.agents[0].name).toContain("Mac已回写");
 const fresh=await runSync({...opts,profile:freshProfile(opts.httpUrl),local:emptySnapshot()});expect(fresh.after.agents.some((a)=>a.name.includes("Mac已回写"))).toBe(true);expect(fresh.after.messages.some((m)=>m.content.includes("Mac 端修改"))).toBe(true);
},30000);
test.skipIf(!enabled)("real ServerFileOperator and ImageFileServer list, upload, preserve same names, preview, rename and download exact bytes",async()=>{
 const root=process.env.VCP_SYNC_FILE_ROOT!;const s={...defaultSettings(),serverUrl:"http://127.0.0.1:43129",apiKey:"file-fixture-key",fileRoot:root,fileShareRoot:root,fileKey:"file-share-fixture-key"};const client=new FileClient(s);
 const bytes=new TextEncoder().encode("文件往返字节\n");const name=`integration-${Date.now()}.txt`;const target=root+"/"+name;
 const first=await client.upload(target,bytes);const second=await client.upload(target,bytes);expect(first.details.path).not.toBe(second.details.path);
 const listing=await client.list(root);const file=listing.items.find((f)=>f.path===first.details.path)!;expect(file).toBeDefined();expect((await client.read(file)).text).toContain("文件往返字节");expect(await client.download(file)).toEqual(bytes);
 const renamed=target+"-renamed.txt";await client.rename(target,renamed);expect((await client.list(root)).items.some((f)=>f.path===renamed)).toBe(true);
},30000);
