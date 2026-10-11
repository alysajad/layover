const {randomUUID}=require('node:crypto');
const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const assert=require('node:assert/strict');
const {createDatabase}=require('./live_map_fixture.cjs');
(async()=>{
 const db=await createDatabase();
 await db.exec(readFileSync(join(__dirname,'../migrations/0007_live_trails.sql'),'utf8'));
 const a=randomUUID(), outsider=randomUUID();
 for(const id of [a,outsider]) await db.query('insert into auth.users(id,email) values($1,$2)',[id,`${id}@example.test`]);
 const asUser=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
 const cmd=async(action,data,key=randomUUID())=>(await db.query('select live_map_command($1,$2,$3) r',[action,data,key])).rows[0].r;
 const snap=async()=>(await db.query('select live_map_snapshot($1) r',[sid])).rows[0].r;
 await asUser(a);
 const {session_id:sid}=await cmd('create',{name:'Trail test'});
 await cmd('start',{session_id:sid});
 let generation,seq=0;
 const publish=()=>db.query('select live_map_publish_location($1,$2,$3,$4,$5,$6,$7,$8,$9)',[sid,generation,++seq,15.5,73.8,12,new Date().toISOString(),null,null]);
 const consent=async(version='live-map-v2')=>{({generation}=await cmd('consent',{session_id:sid,consent_version:version}));seq=0;await db.exec('reset role');await db.query("update location_sharing_consents set last_received_at=now()-interval '6 seconds' where session_id=$1",[sid]);await asUser(a);};
 await consent();await publish();
 assert.equal((await snap()).trails.length,1);
 await assert.rejects(()=>db.query('select * from live_location_trail'),/permission denied/);
 await assert.rejects(()=>db.query('select live_map_snapshot_without_trails($1)',[sid]),/permission denied/);
 await asUser(outsider);await assert.rejects(snap,/access denied/);await asUser(a);
 for(const action of ['pause','stop']) {
   await cmd(action,{session_id:sid});assert.equal((await snap()).trails.length,0);
   await db.exec('reset role');assert.equal((await db.query('select count(*)::int n from live_location_trail')).rows[0].n,0);
   await asUser(a);await consent();await publish();
 }
 // An older client's consent must never inherit its prior opt-in to history.
 await consent('live-map-v1');await publish();assert.equal((await snap()).trails.length,0);
 await consent();await publish();
 await db.exec('reset role');
 await db.query("update live_location_trail set received_at=now()-interval '16 minutes'");
 await asUser(a);assert.equal((await snap()).trails.length,0);
 await consent();await publish();
 await db.exec('reset role');await db.query("update live_locations set received_at=now()-interval '31 seconds'");
 await asUser(a);assert.equal((await snap()).trails.length,0);
 await db.exec('reset role');await db.query('select live_map_cleanup()');
 assert.equal((await db.query('select count(*)::int n from live_location_trail')).rows[0].n,0);
 await asUser(a);await consent();await publish();await cmd('end',{session_id:sid});
 await assert.rejects(snap,/access denied/);
 await db.exec('reset role');assert.equal((await db.query('select count(*)::int n from live_location_trail')).rows[0].n,0);
 await db.exec('set role anon');await assert.rejects(snap,/permission denied/);
 await db.close();console.log('PASS: shared trails, access isolation, expiry, stop/pause/end cascades and old-client consent');
})().catch(e=>{console.error(e);process.exit(1);});
