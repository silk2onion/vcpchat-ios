// A VCPToolBox direct service. No model-facing tools, new listener or external dependencies.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');

const UUID = /^[a-f\d]{8}-[a-f\d]{4}-4[a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i;
const PAGE = 128 * 1024, LIMIT = 16 * 1024 * 1024, TTL = 86400000;
const hash = s => crypto.createHash('sha256').update(s).digest('hex');
const equal = (a,b) => crypto.timingSafeEqual(Buffer.from(hash(a)), Buffer.from(hash(b)));
const json = (res, code, value) => {
  res.writeHead(code, {'Content-Type':'application/json; charset=utf-8'}); res.end(JSON.stringify(value));
};
const reject = (status, message) => Object.assign(new Error(message), { status });

function createService({ directory, port, key, ttl = TTL }) {
  if (!key || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error('VChatReplySync requires VCP Key and PORT');
  fs.mkdirSync(directory,{ recursive:true,mode:0o700 });
  const jobs = new Map(), workers = new Set();
  let stopped = false, stored = 0;
  const dir = id => path.join(directory,id);
  const bodyFile = id => path.join(dir(id),'reply');
  const persist = job => {
    const tmp = path.join(dir(job.id),'state.tmp');
    fs.writeFileSync(tmp,JSON.stringify(job.meta),{mode:0o600});
    fs.renameSync(tmp,path.join(dir(job.id),'state.json'));
  };
  function reserve(id, meta) {
    // Exclusive reservation precedes every model POST, including after a process restart.
    try { fs.mkdirSync(dir(id),{mode:0o700}); } catch (e) { if(e.code==='EEXIST') throw reject(409,'reserved'); throw e; }
    fs.writeFileSync(bodyFile(id),Buffer.alloc(0),{flag:'wx',mode:0o600});
    const job=attach(id,meta,0); persist(job); jobs.set(id,job); return job;
  }
  const attach = (id,meta,size) => ({id,meta,size,events:new EventEmitter(),readers:0,controller:null});
  function finish(job,state,reason) {
    if (job.meta.state !== 'running') return;
    job.meta = {...job.meta,state,reason,ended:Date.now()};
    persist(job); job.events.emit('change');
  }
  // A service restart cannot safely replay a model/tool POST. Retain the prefix.
  for (const id of fs.readdirSync(directory).filter(x => UUID.test(x))) {
    const metaFile = path.join(dir(id),'state.json');
    if (!fs.existsSync(metaFile)) continue; // incomplete reservation; never reuse this ID
    const job = attach(id,JSON.parse(fs.readFileSync(metaFile)),fs.statSync(bodyFile(id)).size);
    jobs.set(id,job); stored += job.size;
    finish(job,'interrupted','server-restart');
  }
  function cleanup() {
    const cutoff = Date.now()-ttl;
    for (const job of jobs.values()) if (job.meta.ended && job.meta.ended < cutoff && !job.readers) {
      fs.rmSync(dir(job.id),{recursive:true,force:true}); jobs.delete(job.id); stored -= job.size;
    }
  }
  cleanup();
  const gc = setInterval(cleanup,60000); gc.unref();
  async function generate(job, route, body, bearer) {
    const controller = new AbortController(); job.controller = controller;
    const timeout = setTimeout(() => controller.abort(),600000); timeout.unref();
    try {
      const response = await fetch('http://127.0.0.1:'+port+'/v1/'+route+'/completions',{
        method:'POST',redirect:'error',signal:controller.signal,body,
        headers:{ Authorization:bearer, 'Content-Type':'application/json', Accept:'text/event-stream' }
      });
      if (!response.ok || !response.body) { finish(job,'interrupted','upstream-http-'+response.status); return; }
      let tail = Buffer.alloc(0), first = '';
      for await (const chunk of response.body) {
        if (job.meta.state !== 'running') break;
        if (job.size+chunk.length > LIMIT || stored+chunk.length > 256*1024*1024) {
          finish(job,'interrupted','storage-limit'); controller.abort(); return;
        }
        if (!first) first = Buffer.from(chunk).toString('utf8').trimStart().slice(0,1);
        tail = Buffer.concat([tail,chunk]).subarray(-4096);
        fs.appendFileSync(bodyFile(job.id),chunk); job.size += chunk.length; stored += chunk.length;
        job.events.emit('change');
      }
      if (job.meta.state !== 'running') return;
      let complete = /(?:^|[\r\n])data:[ \t]*\[DONE\][ \t]*(?:[\r\n]|$)/.test(tail.toString('utf8'));
      if (first === '{') {
        const value = JSON.parse(fs.readFileSync(bodyFile(job.id),'utf8'));
        complete = !!value.choices?.[0]?.message;
      }
      finish(job,complete?'complete':'interrupted',complete?null:'incomplete-response');
    } catch { finish(job,'interrupted',controller.signal.aborted ? 'expired' : 'upstream-disconnected'); }
    finally { clearTimeout(timeout); controller.abort(); job.controller = null; }
  }
  function wait(job,res,ms) {
    return new Promise(resolve => {
      const done = () => { clearTimeout(timer); job.events.off('change',done); res.off('close',done); resolve(); };
      const timer = setTimeout(done,ms); job.events.once('change',done); res.once('close',done);
      if (res.destroyed) done();
    });
  }
  async function handle(req,res) {
    res.setHeader('Cache-Control','no-store'); res.setHeader('X-Content-Type-Options','nosniff');
    try {
      if (stopped) throw reject(503,'service-stopping');
      const auth = req.headers.authorization || '';
      if (!equal(auth,'Bearer '+key)) throw reject(401,'unauthorized');
      const u = new URL(req.url,'http://localhost');
      if (u.pathname === '/capabilities' && req.method === 'GET') return json(res,200,{version:1,retentionSeconds:ttl/1000});
      const m = /^\/jobs\/([^/]+)(\/result)?$/.exec(u.pathname);
      if (!m || !UUID.test(m[1])) throw reject(404,'not-found');
      const id = m[1].toLowerCase(), proof = req.headers['x-vchat-proof'];
      if (typeof proof !== 'string' || !/^[a-f0-9]{64}$/.test(proof)) throw reject(404,'not-found');
      let job = jobs.get(id);
      if (job && !equal(job.meta.owner,hash(proof))) throw reject(404,'not-found');
      if (req.method === 'PUT' && !m[2]) {
        const kind = req.headers['x-vchat-route'];
        if (!['chat','chatvcp'].includes(kind)) throw reject(400,'unknown-chat-endpoint');
        const b = req.body;
        if (!b || typeof b.model !== 'string' || !b.model || !Array.isArray(b.messages) || !b.messages.length || b.stream !== true) throw reject(400,'invalid-chat');
        // Forward only the client's supported completion parameters to a fixed local route.
        const params = {};
        for (const k of ['model','messages','stream','temperature','max_tokens','contextTokenLimit']) if (b[k] !== undefined) params[k]=b[k];
        const body = JSON.stringify(params);
        if (Buffer.byteLength(body)>32*1024*1024) throw reject(413,'request-too-large');
        const fingerprint = hash(kind+'\n'+body);
        if (job) {
          if (job.meta.state !== 'stopped' && job.meta.fingerprint !== fingerprint) throw reject(409,'different-request');
        } else {
          cleanup();
          if (jobs.size >= 256 || workers.size >= 8 || stored >= 256*1024*1024) throw reject(429,'capacity');
          // Reserve synchronously before launching any asynchronous work. No subscriber owns the POST.
          job=reserve(id,{owner:hash(proof),fingerprint,state:'running',created:Date.now()});
          const worker = generate(job,kind,body,auth); workers.add(worker);
          worker.then(()=>workers.delete(worker),()=>workers.delete(worker));
        }
        return json(res,200,{id,state:job.meta.state,version:1});
      }
      if (!job && req.method === 'DELETE' && !m[2]) {
        cleanup(); if (jobs.size >= 256) throw reject(429,'capacity');
        // Stop may overtake an in-flight PUT. Its tombstone prevents a late start.
        job=reserve(id,{owner:hash(proof),state:'stopped',created:Date.now(),ended:Date.now(),reason:'user-stop'});
      }
      if (!job) throw reject(404,'not-found');
      if (req.method === 'DELETE' && !m[2]) {
        finish(job,'stopped','user-stop'); job.controller?.abort();
        return json(res,200,{id,state:job.meta.state});
      }
      if (req.method !== 'GET') throw reject(405,'method-not-allowed');
      if (job.readers >= 6) throw reject(429,'too-many-readers');
      job.readers++;
      try {
        if (m[2]) {
          // One OS-managed download can outlive app suspension. Whitespace keeps
          // proxies alive and is legal before the final JSON document.
          res.writeHead(200,{'Content-Type':'application/json','X-Accel-Buffering':'no'}); res.write('\n');
          const heartbeat = setInterval(()=>{ if(!res.destroyed) res.write('\n'); },10000);
          try {
            while (job.meta.state === 'running' && !res.destroyed) await wait(job,res,10000);
            clearInterval(heartbeat); // no more whitespace once the JSON string begins
            if (!res.destroyed) {
              const packet = {id,state:job.meta.state,reason:job.meta.reason||null,offset:0,next:job.size};
              res.write(JSON.stringify(packet).slice(0,-1)+',"data":"');
              // Align all but the last read to three bytes for concatenated base64.
              let carry=Buffer.alloc(0);
              for await (const part of fs.createReadStream(bodyFile(id),{highWaterMark:96*1024})) {
                if (res.destroyed) return;
                const block=carry.length ? Buffer.concat([carry,part]) : part;
                const end=block.length-block.length%3; carry=block.subarray(end);
                if (!res.write(block.toString('base64',0,end))) {
                  await new Promise(resolve => {
                    const ready = () => { res.off('drain',ready); res.off('close',ready); resolve(); };
                    res.once('drain',ready); res.once('close',ready); if(res.destroyed) ready();
                  });
                }
              }
              res.end(carry.toString('base64')+'"}');
            }
          } finally { clearInterval(heartbeat); }
          return;
        }
        const raw = u.searchParams.get('offset') ?? '0', offset = Number(raw);
        if (!/^\d+$/.test(raw) || !Number.isSafeInteger(offset) || offset > job.size) throw reject(416,'invalid-offset');
        if (offset === job.size && job.meta.state === 'running') await wait(job,res,10000);
        if (res.destroyed) return;
        const bytes = Buffer.alloc(Math.min(PAGE,job.size-offset));
        const fd = fs.openSync(bodyFile(id),'r');
        let size;
        try { size = fs.readSync(fd,bytes,0,bytes.length,offset); } finally { fs.closeSync(fd); }
        const next=offset+size;
        json(res,200,{id,offset,next,state:next<job.size?'running':job.meta.state,reason:job.meta.reason||null,data:bytes.subarray(0,size).toString('base64')});
      } finally { job.readers--; }
    } catch (error) {
      if (!res.destroyed && !res.headersSent) json(res,error.status||500,{error:error.status?error.message:'storage-error'});
      else if (!res.destroyed) res.destroy();
    }
  }
  return {handle, async close() {
    stopped=true; clearInterval(gc);
    for (const job of jobs.values()) if (job.meta.state==='running') { finish(job,'interrupted','server-shutdown'); job.controller?.abort(); }
    await Promise.allSettled([...workers]);
  }};
}

let service;
module.exports = {
  initialize() {},
  registerApiRoutes(router, config, projectBasePath) {
    service=createService({directory:path.join(projectBasePath,'PluginData','VChatReplySync'),port:Number(process.env.PORT),key:process.env.Key});
    router.use((req,res)=>service.handle(req,res));
  },
  shutdown() { return service?.close(); },
  createService
};
