// Run with typescript installed in NODE_PATH. No network or paid API calls.
const ts=require('typescript');
const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const assert=require('node:assert/strict');
const source=readFileSync(join(__dirname,'../functions/trip-planner/index.ts'),'utf8').replace(/^import .*;\n/gm,'');
const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
(async()=>{
 let handler, background, resolveClaim, resolveGeneration, complete=0, calls=0, authenticated=false, access=false, claimFailure=false;
 const logs=[];
 const env={SUPABASE_URL:'https://test.invalid',SUPABASE_ANON_KEY:'test-anon',SUPABASE_SERVICE_ROLE_KEY:'test-service',PLANNER_SECRET:'test-scheduler',SERPAPI_API_KEY:'test-provider'};
 const claim=new Promise(resolve=>resolveClaim=resolve);
 const generation=new Promise(resolve=>resolveGeneration=resolve);
 const db={rpc:async name=>{
   calls++;
   if(name==='planner_claim'){ if(claimFailure) throw new Error('must not leak private URL/key'); return claim; }
   if(name==='planner_complete'){complete++;return {data:true,error:null};}
 }};
 const user={auth:{getUser:async()=>({data:{user:authenticated?{id:'leader'}:null},error:null})},rpc:async()=>({error:access?null:{message:'denied'}})};
 new Function('Deno','EdgeRuntime','createClient','generate','console',compiled)(
   {env:{get:key=>env[key]},serve:fn=>handler=fn},
   {waitUntil:promise=>background=promise},
   (_url,key)=>key==='test-service'?db:user,
   async()=>generation,
   {info:(...args)=>logs.push(args.join(' ')),error:(...args)=>logs.push(args.join(' '))},
 );
 const request=(headers={},body='{}')=>new Request('https://test.invalid/trip-planner',{method:'POST',headers,body});
 assert.equal((await handler(new Request('https://test.invalid',{method:'OPTIONS'}))).status,200);
 assert.equal((await handler(request({'x-planner-secret':'wrong'}))).status,401);
 assert.equal(calls,0);assert.equal(background,undefined);
 authenticated=true;
 assert.equal((await handler(request({Authorization:'Bearer test'},'{"trip_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'))).status,403);
 assert.equal(calls,0);
 authenticated=false;
 // Database and generation are both deliberately held: response must still arrive.
 let timeout;
 const response=await Promise.race([handler(request({'x-planner-secret':'test-scheduler'})),
   new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error('Scheduler response waited for the background job')),1000);})]);
 clearTimeout(timeout);
 assert.equal(response.status,200);assert.deepEqual(await response.json(),{status:'accepted'});
 assert(background instanceof Promise);assert.equal(complete,0);
 resolveClaim({data:{trip_id:'trip',lease_id:'lease'},error:null});
 await new Promise(resolve=>setImmediate(resolve));assert.equal(complete,0);
 resolveGeneration({options:[]});await background;assert.equal(complete,1);
 assert(logs.includes('Scheduled planner: ready'));
 claimFailure=true;
 assert.equal((await handler(request({'x-planner-secret':'test-scheduler'}))).status,200);
 await background;
 assert(logs.some(v=>v.includes('Scheduled planner failed')));
 assert(!logs.some(v=>v.includes('private URL/key')));
 console.log('PASS worker: immediate scheduler response, background completion, secret/JWT access checks, sanitized background errors');
})().catch(e=>{console.error(e);process.exitCode=1;});
