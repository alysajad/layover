const ts=require('typescript');
const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const {webcrypto,generateKeyPairSync}=require('node:crypto');
const source=readFileSync(join(__dirname,'../functions/trip-reminders/index.ts'),'utf8');
const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},reportDiagnostics:true});
assert.equal(compiled.diagnostics.length,0);

function worker({firebase=false,member=true,enabled=true,tokenStatus=200,queueError=false}={}){
  let handler;let queued=0;let deliveries=0;let marked=0;let removed=0;
  const env={REMINDER_SECRET:'scheduler-secret',SUPABASE_URL:'https://example.test',SUPABASE_SERVICE_ROLE_KEY:'test-only'};
  if(firebase){
    const key=generateKeyPairSync('rsa',{modulusLength:2048}).privateKey.export({type:'pkcs8',format:'pem'});
    env.FIREBASE_SERVICE_ACCOUNT=JSON.stringify({private_key:key,client_email:'test@example.test',project_id:'test'});
  }
  const db={
    rpc:async(name)=>name==='enqueue_trip_reminders'?(queued++,{error:queueError?new Error('queue failed'):null}):{data:[{id:'n',trip_id:'t',user_id:'u'}]},
    from(table){
      let operation='select';
      const builder={select(){return builder;},eq(){return builder;},update(){operation='update';return builder;},delete(){operation='delete';return builder;},
        maybeSingle(){return Promise.resolve({data:member?{user_id:'u'}:null});},single(){return Promise.resolve({data:{reminders_enabled:enabled}});},
        then(resolve,reject){
          if(operation==='update')marked++;if(operation==='delete')removed++;
          return Promise.resolve({data:table==='device_tokens'&&operation==='select'?[{token:'test-device'}]:null,error:null}).then(resolve,reject);
        }};
      return builder;
    },
  };
  const sandbox={exports:{},require:()=>({createClient:()=>db}),Deno:{env:{get:key=>env[key]},serve:fn=>handler=fn},
    TextEncoder,Uint8Array,atob,btoa,crypto:webcrypto,URLSearchParams,Response,AbortSignal,
    console:{error(){}},fetch:async(url,options)=>{
      if(url.includes('oauth2')){const assertion=new URLSearchParams(options.body).get('assertion');assert.equal(assertion.split('.').length,3);return Response.json({access_token:'access'});}
      deliveries++;const message=JSON.parse(options.body).message;assert.equal(message.android.notification.tag,'n');
      assert.equal(message.notification.body,'Your trip has an update.');
      return tokenStatus===200?Response.json({name:'sent'}):Response.json({error:{details:[{errorCode:tokenStatus===404?'UNREGISTERED':'UNAVAILABLE'}]}},{status:tokenStatus});
    }};
  vm.runInNewContext(compiled.outputText,sandbox);
  return {call:(secret='scheduler-secret',method='POST')=>handler(new Request('https://example.test',{method,headers:{'x-reminder-secret':secret}})),counts:()=>({queued,deliveries,marked,removed})};
}
(async()=>{
  let w=worker();assert.equal((await w.call('bad')).status,401);assert.equal(w.counts().queued,0);
  assert.equal((await w.call('scheduler-secret','GET')).status,405);
  assert.equal((await (await w.call()).json()).push,'not_configured');
  w=worker({queueError:true});assert.equal((await w.call()).status,500);
  w=worker({firebase:true});assert.equal((await w.call()).status,200);assert.deepEqual(w.counts(),{queued:1,deliveries:1,marked:1,removed:0});
  w=worker({firebase:true,member:false});await w.call();assert.equal(w.counts().deliveries,0);
  w=worker({firebase:true,enabled:false});await w.call();assert.equal(w.counts().deliveries,0);
  w=worker({firebase:true,tokenStatus:404});await w.call();assert.equal(w.counts().removed,1);
  w=worker({firebase:true,tokenStatus:503});await w.call();assert.equal(w.counts().marked,0);
  console.log('PASS: worker syntax, scheduler auth, queue errors, JWT signing, delivery, opt-out, removed membership, invalid token, retries');
})().catch(error=>{console.error(error);process.exit(1);});
