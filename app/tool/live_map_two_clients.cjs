// Synthetic positions only. Default: isolated PGlite; --hosted: explicit dev account tokens.
const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function main(){
  let db, sid, clients;
  const hosted=process.argv.includes('--hosted');
  if(hosted){
    const {SUPABASE_URL:url,SUPABASE_PUBLISHABLE_KEY:key,LIVE_MAP_TOKEN_A:a,LIVE_MAP_TOKEN_B:b,LIVE_MAP_TOKEN_OUTSIDER:x}=process.env;
    if(!url||!key||!a||!b||!x)throw Error('Supply SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY and three LIVE_MAP_TOKEN_* user access tokens.');
    clients=await Promise.all([a,b,x].map(async token=>{
      const headers={apikey:key,Authorization:`Bearer ${token}`,'Content-Type':'application/json'};
      const user=await fetch(`${url}/auth/v1/user`,{headers});
      if(!user.ok)throw Error('Test account authentication failed');
      return {id:(await user.json()).id,rpc:async(name,params={})=>{
        const response=await fetch(`${url}/rest/v1/rpc/${name}`,{method:'POST',headers,body:JSON.stringify(params),signal:AbortSignal.timeout(10000)});
        if(!response.ok)throw Error(`RPC ${name} rejected (${response.status})`);
        return response.json();
      }};
    }));
  }else{
    db=await require('../../supabase/tests/live_map_fixture.cjs').createDatabase();
    const ids=Array.from({length:3},randomUUID);
    for(const id of ids)await db.query('insert into auth.users(id,email) values($1,$2)',[id,`${id}@example.test`]);
    // PGlite has one SQL connection. Serialize transport calls so each authenticated
    // request owns its role/claim, as separate hosted HTTP requests do.
    let queue=Promise.resolve();
    clients=ids.map(id=>({id,rpc:(name,params={})=>{
      const next=queue.then(async()=>{
        await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');
        const entries=Object.entries(params);
        if(!['companion_command','live_map_command','live_map_snapshot','live_map_publish_location'].includes(name))throw Error('Unexpected RPC');
        return (await db.query(`select public.${name}(${entries.map(([key],i)=>`${key} => $${i+1}`).join(',')}) result`,entries.map(([,value])=>value))).rows[0].result;
      });queue=next.catch(()=>{});return next;
    }}));
    const trip=await clients[0].rpc('companion_command',{p_action:'create_trip',p_data:{title:'Two-client simulation'},p_request_id:randomUUID()});
    const invite=await clients[0].rpc('companion_command',{p_action:'invite',p_data:trip,p_request_id:randomUUID()});
    await clients[1].rpc('companion_command',{p_action:'join_trip',p_data:invite,p_request_id:randomUUID()});
  }
  const [a,b,x]=clients;
  const command=(client,action,data={})=>client.rpc('live_map_command',{p_action:action,p_data:{...(sid?{session_id:sid}:{}),...data},p_request_id:randomUUID()});
  const snapshot=client=>client.rpc('live_map_snapshot',{p_session_id:sid});
  let sequence=0,generation,latest,pollFailure,polling=true;
  const publish=()=>a.rpc('live_map_publish_location',{p_session_id:sid,p_generation:generation,p_sequence:++sequence,p_latitude:15.498,p_longitude:73.828,p_accuracy_m:12,p_client_timestamp:new Date().toISOString()});
  let pollLoop;
  try{
    sid=(await command(a,'create',{name:'Synthetic two-client verification'})).session_id;
    await command(a,'invite',{target_id:b.id});
    await assert.rejects(()=>snapshot(b));await assert.rejects(()=>snapshot(x));
    await command(b,'join');await command(a,'start');
    ({generation}=await command(a,'consent',{consent_version:'live-map-v1'}));
    pollLoop=(async()=>{while(polling){try{latest=await snapshot(b);}catch(_){pollFailure=true;}await sleep(3000);}})();
    async function waitFor(predicate,timeout=6500){
      const deadline=Date.now()+timeout;
      while(Date.now()<deadline){if(pollFailure)throw Error('Viewer polling failed');if(latest&&predicate(latest))return;await sleep(100);}
      throw Error('Automatic poll did not observe the expected state');
    }
    const concurrent=await Promise.allSettled([publish(),publish()]);
    assert.equal(concurrent.filter(r=>r.status==='fulfilled').length,1);
    await waitFor(s=>s.locations.length===1);
    await sleep(5100);await publish();const afterSequence=sequence;
    await waitFor(s=>s.locations[0]?.sequence_number===afterSequence);
    await command(a,'destination',{name:'Synthetic meeting point',latitude:15.499,longitude:73.829});
    await waitFor(s=>s.destination?.name==='Synthetic meeting point');
    await command(b,'destination',{name:'Member update',latitude:15.499,longitude:73.829});
    assert.equal((await snapshot(a)).destination.name,'Member update');
    await command(a,'stop');await waitFor(s=>s.locations.length===0);
    console.log('PASS: automatic location/destination polling, joined-member editing, invited/outsider denial, online stop by next poll');
    await sleep(5100);({generation}=await command(a,'consent',{consent_version:'live-map-v1'}));await publish();
    await waitFor(s=>s.locations.length===1);
    const lastReceive=Date.parse(latest.locations[0].received_at);
    // Sender goes offline: deliberately send neither fixes nor a pause/stop command.
    await waitFor(s=>s.locations.length===0,34000);
    assert.ok(Date.now()-lastReceive<33500,'Offline visibility exceeded lease plus one polling interval');
    await assert.rejects(publish);
    console.log('PASS: offline sender disappears within 30-second lease plus poll interval; expired generation cannot restart sharing');
  }finally{
    polling=false;if(pollLoop)await pollLoop;
    if(sid)await command(a,'end').catch(()=>{});
    if(db)await db.close();
  }
  console.log(`PASS: two authenticated clients (${hosted?'hosted development project':'isolated PGlite transport'})`);
}
main().catch(error=>{console.error(error.message);process.exitCode=1;});
