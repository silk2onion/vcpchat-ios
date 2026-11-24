// An isolated stand-in for VCP's Express mount + chat route. Uses the shipped plugin.
'use strict';
const http=require('node:http'), fs=require('node:fs'), path=require('node:path'), os=require('node:os');
const plugin=require('../../Companion/VChatReplySync');
const {createService}=plugin;
const prefix='/api/plugins/VChatReplySync';
async function fixture(directory=fs.mkdtempSync(path.join(os.tmpdir(),'vchat-reply-')), mountPlugin=false) {
  let service;
  const runs=new Map(), requests=[], archiveOnly=new Set();
  const server=http.createServer(async(req,res)=>{
    const chunks=[]; for await(const c of req) chunks.push(c);
    if(chunks.length) req.body=JSON.parse(Buffer.concat(chunks));
    if(req.url.startsWith(prefix+'/')) {
      req.url=req.url.slice(prefix.length);
      const jobPath=req.url.split('?')[0];
      if(req.method==='PUT' && req.body?.model?.startsWith('archive-')) archiveOnly.add(jobPath);
      // Simulate a permanently unavailable live reader, not a failed model request.
      if(req.method==='GET' && archiveOnly.has(jobPath)) {res.writeHead(503);return res.end();}
      return service.handle(req,res);
    }
    if(req.url.startsWith('/v1/chat') && req.method==='POST') {
      const model=req.body.model;
      requests.push({model,url:req.url}); runs.set(model,res);
      res.writeHead(200,{'Content-Type':'text/event-stream'});
      res.write('data: '+JSON.stringify({choices:[{delta:{content:'首段',reasoning_content:'思'}}]})+'\n\n');
    } else if(req.url.startsWith('/count/')) { res.end(String(requests.filter(r=>r.model===req.url.slice(7)).length));
    } else if(req.url.startsWith('/release/')) {
      const model=req.url.slice('/release/'.length), stream=runs.get(model);
      if (!stream) { res.writeHead(404); return res.end(); }
      stream.end('data: '+JSON.stringify({choices:[{delta:{content:'后台完成',reasoning_content:'考'}}]})+'\n\ndata: [DONE]\n\n');
      res.end(String(requests.filter(r=>r.model===model).length));
    } else { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve)); const port=server.address().port;
  const open=()=>createService({directory,port,key:'fixture'});
  if(mountPlugin) {
    process.env.PORT=String(port);process.env.Key='fixture';plugin.initialize();
    plugin.registerApiRoutes({use(handle){service={handle,close:()=>plugin.shutdown()}}},{},directory);
  } else { service=open(); }
  return {base:'http://localhost:'+port,prefix,requests,runs,directory, async restart() {await service.close();service=open()},
    async close(){await service.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(directory,{recursive:true,force:true})}};
}
module.exports={fixture};
if(require.main===module) fixture(undefined,true).then(x=>{fs.writeFileSync(process.argv[2],x.base);process.once('SIGTERM',async()=>{await x.close();process.exit()})});
