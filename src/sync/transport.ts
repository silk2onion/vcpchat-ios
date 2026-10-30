import { isTauri, type HttpClient } from "../protocol/http";
import { parseHttpUrl } from "../protocol/endpoint";
import { object, string } from "./projection";
import { parseJsonWithoutDuplicateKeys as parse } from "./upstream/json.js";
import type { Json } from "./types";
export function syncEndpoint(raw: string): string {
  const url=parseHttpUrl(raw); if(url.search || url.hash)throw new Error("同步 HTTP 地址不能带查询参数");
  url.pathname=url.pathname.replace(/\/+$/,"").replace(/\/api\/mobile-sync$/,"")+"/api/mobile-sync";return url.toString().replace(/\/$/,"");
}
export function socketUrl(raw: string, token: string): string {
  const u=new URL(raw); if(!["ws:","wss:"].includes(u.protocol)||u.username||u.password||u.hash||!["/","/ws-sync"].includes(u.pathname))throw new Error("WebSocket 请填写 ws(s)://桌面地址:5975/ 或 /ws-sync");
  u.searchParams.set("token",token);return u.toString();
}
export function canceled(signal: AbortSignal) { if(signal.aborted)throw new DOMException("已取消同步","AbortError"); }
export function abortable<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  canceled(signal);return new Promise((resolve,reject)=>{const abort=()=>reject(new DOMException("已取消同步","AbortError"));signal.addEventListener("abort",abort,{once:true});promise.then(resolve,reject).finally(()=>signal.removeEventListener("abort",abort));});
}
export class SyncSocket {
  private pending: { expected:string; resolve:(v:Json)=>void; reject:(e:Error)=>void; timer:ReturnType<typeof setTimeout> } | null = null;
  private socket: WebSocket;
  readonly ready: Promise<void>;
  constructor(url: string, private readonly signal: AbortSignal, onEvent: (v:Json)=>void = ()=>{}) {
    this.socket=new WebSocket(url);
    this.ready=new Promise((resolve,reject)=>{
      const timeout=setTimeout(()=>{reject(new Error("同步连接超时"));this.close();},30000);
      this.socket.onopen=()=>{clearTimeout(timeout);resolve();};
      this.socket.onerror=()=>{clearTimeout(timeout);reject(new Error("无法连接桌面同步通道"));this.fail(new Error("同步通道连接失败"));};
      this.socket.onclose=()=>{clearTimeout(timeout);reject(new Error("同步通道已关闭"));this.fail(new Error("同步通道已断开"));};
    });
    this.socket.onmessage=(event)=>{
      try {const value=object(parse(String(event.data)));if(value.type==="SYNC_ERROR")throw new Error(syncError(value.error));
        if(this.pending && this.pending.expected===value.type){const p=this.pending;this.pending=null;clearTimeout(p.timer);p.resolve(value);}else onEvent(value);
      } catch(error){this.fail(error instanceof Error?error:new Error(String(error)));this.close();}
    };
    this.signal.addEventListener("abort",this.abort,{once:true});
  }
  private abort=()=>{this.fail(new DOMException("已取消同步","AbortError"));this.close();};
  private fail(error:Error){if(this.pending){clearTimeout(this.pending.timer);this.pending.reject(error);this.pending=null;}}
  async request(value: Json, expected: string): Promise<Json> {
    await abortable(this.ready,this.signal);canceled(this.signal);if(this.pending)throw new Error("同步请求尚未完成");
    return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.fail(new Error("桌面响应超时，请检查同步服务状态"));this.close();},60000);this.pending={expected,resolve,reject,timer};this.socket.send(JSON.stringify(value));});
  }
  async send(value:Json){await abortable(this.ready,this.signal);canceled(this.signal);this.socket.send(JSON.stringify(value));}
  close(){this.signal.removeEventListener("abort",this.abort);this.socket.close();}
}
export function syncError(value: unknown): string { if(typeof value==="string")return value; if(value&&typeof value==="object"){const v=value as Json;return [string(v.code),string(v.message)].filter(Boolean).join("：")||"同步服务返回错误";}return "同步响应无效"; }
export async function createSyncHttp(): Promise<HttpClient> {
  if(!isTauri())return {async request(input){const r=await fetch(input.url,{method:input.method,headers:input.headers,body:input.body,redirect:"error"});return {status:r.status,body:await r.text()};}};
  const {invoke}=await import("@tauri-apps/api/core");return {request: (v)=>invoke("sync_http_request",{...v,body:v.body??null})};
}
export async function binaryRequest(url: string, headers: Record<string,string>, body?: Uint8Array): Promise<Uint8Array> {
  if(!isTauri()){const r=await fetch(url,{method:body?"POST":"GET",headers,body:body?new Blob([body as Uint8Array<ArrayBuffer>]):undefined,redirect:"error"});if(!r.ok)throw new Error(`文件 HTTP ${r.status}`);const data=new Uint8Array(await r.arrayBuffer());if(data.length>20_000_000)throw new Error("文件超过20MB");return data;}
  const {invoke}=await import("@tauri-apps/api/core");const result=await invoke<ArrayBuffer|number[]>("binary_request",{url,headers,body:body?Array.from(body):null});return new Uint8Array(result);
}
export class SyncHttp {
  constructor(private readonly http: HttpClient, readonly endpoint: string, private readonly token: string, private readonly signal: AbortSignal){}
  async json(path:string, body:unknown): Promise<Json> {
    const r=await abortable(this.http.request({method:"POST",url:this.endpoint+path,headers:{Authorization:`Bearer ${this.token}`,"Content-Type":"application/json","X-Idempotency-Key":crypto.randomUUID()},body:JSON.stringify(body)}),this.signal);
    const parsed=object(parse(r.body));if(r.status<200||r.status>=300)throw new Error(syncError(parsed.error??parsed));return parsed;
  }
  async ndjson(path:string, body:unknown): Promise<Json[]> {
    const r=await abortable(this.http.request({method:"POST",url:this.endpoint+path,headers:{Authorization:`Bearer ${this.token}`,"Content-Type":typeof body==="string"?"application/x-ndjson":"application/json"},body:typeof body==="string"?body:JSON.stringify(body)}),this.signal);
    if(r.status<200||r.status>=300)throw new Error(`同步 HTTP ${r.status}：${syncError(object(parse(r.body)).error)}`);
    if(r.body.length && !r.body.endsWith("\n"))throw new Error("消息流未完整结束，未写入本机");
    const rows=r.body.split("\n").filter((v)=>v.trim()).map((v)=>object(parse(v)));
    for(const row of rows)if(row.ok!==true)throw new Error(syncError(row.error));return rows;
  }
  async binary(path:string, body?:Uint8Array, mime="application/octet-stream"):Promise<Uint8Array>{return abortable(binaryRequest(this.endpoint+path,{Authorization:`Bearer ${this.token}`,...(body?{"Content-Type":mime}:{})},body),this.signal);}
}
