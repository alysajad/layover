// Run with Node and @electric-sql/pglite installed. No hosted database is touched.
const { PGlite } = require('@electric-sql/pglite');
const { pgcrypto } = require('@electric-sql/pglite/contrib/pgcrypto');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { randomUUID } = require('node:crypto');
const assert = require('node:assert/strict');

(async () => {
  const db = new PGlite({ extensions: { pgcrypto } });
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
    alter table storage.objects enable row level security;
    create function storage.foldername(text) returns text[] language sql as $$ select string_to_array($1,'/') $$;
    grant usage on schema public,auth,storage to authenticated,anon,service_role;
  `);
  for (const file of ['0001_init.sql','0002_companion.sql','0003_live_map.sql']) {
    try { await db.exec(readFileSync(join(__dirname,'../migrations',file),'utf8')); }
    catch (error) { console.error(`Migration failed: ${file}`, error.message, error.position); throw error; }
  }
  const [a,b,c,x]=Array.from({length:4},randomUUID);
  for (const id of [a,b,c,x]) await db.query('insert into auth.users(id,email) values($1,$2)',[id,`${id}@example.test`]);
  const asUser=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  const root=async sql=>{await db.exec('reset role');return db.exec(sql);};
  const command=async(action,data,key=randomUUID())=>(await db.query('select live_map_command($1,$2,$3) r',[action,data,key])).rows[0].r;
  const companion=async(action,data)=>(await db.query('select companion_command($1,$2,$3) r',[action,data,randomUUID()])).rows[0].r;
  const snapshot=async sid=>(await db.query('select live_map_snapshot($1) r',[sid])).rows[0].r;
  const sessions=async()=>(await db.query('select live_map_sessions() r')).rows[0].r;
  let sid,generation,sequence=0;
  const publish=async(overrides={})=>{
    const p={sid,generation,sequence:++sequence,latitude:15.5,longitude:73.8,accuracy:12,time:new Date().toISOString(),heading:null,speed:null,...overrides};
    return db.query('select live_map_publish_location($1,$2,$3,$4,$5,$6,$7,$8,$9)',Object.values(p));
  };
  await asUser('');await assert.rejects(sessions,/Sign in/);
  await db.exec('set role anon');await assert.rejects(sessions,/permission denied/);
  await asUser(a);
  const {trip_id:trip}=await companion('create_trip',{title:'Live map test'});
  const {token}=await companion('invite',{trip_id:trip});
  for(const id of [b,c]){await asUser(id);await companion('join_trip',{token});}
  await asUser(a);
  const request=randomUUID(), input={name:'Find friends',linked_trip_id:trip};
  ({session_id:sid}=await command('create',input,request));
  assert.equal((await command('create',input,request)).session_id,sid);
  await assert.rejects(()=>command('create',{...input,name:'Changed'},request),/different input/);
  await assert.rejects(()=>command('create',{name:'Too long',duration_hours:9}),/Duration/);
  await assert.rejects(()=>db.query('select * from live_locations'),/permission denied/);
  await assert.rejects(()=>db.query('select live_map_cleanup()'),/permission denied/);
  await command('invite',{session_id:sid,target_id:b});
  await command('invite',{session_id:sid,target_id:c});
  await assert.rejects(()=>command('invite',{session_id:sid,target_id:x}),/eligible/);
  await asUser(x);await assert.rejects(()=>snapshot(sid),/access denied/);assert.equal((await sessions()).sessions.length,0);
  await asUser(b);assert.equal((await sessions()).sessions.length,1);
  await assert.rejects(()=>snapshot(sid),/access denied/);
  await command('join',{session_id:sid});
  await assert.rejects(()=>command('start',{session_id:sid}),/Only organizer/);
  await assert.rejects(()=>command('consent',{session_id:sid,consent_version:'live-map-v1'}),/Active session/);
  await asUser(a);await command('start',{session_id:sid});
  await command('revoke',{session_id:sid,target_id:c});
  await asUser(c);await assert.rejects(()=>command('join',{session_id:sid}),/Invitation/);
  await asUser(b);await assert.rejects(()=>publish(),/explicit resume/);
  ({generation}=await command('consent',{session_id:sid,consent_version:'live-map-v1'}));
  for(const overrides of [{latitude:91},{longitude:-181},{latitude:'NaN'},{accuracy:-1},{accuracy:5001},{heading:360},{speed:101},{time:new Date(Date.now()-31000).toISOString()},{time:new Date(Date.now()+11000).toISOString()}])
    await assert.rejects(()=>publish(overrides),/Invalid location|fresh device/);
  await assert.rejects(()=>command('consent',{session_id:sid,consent_version:'live-map-v1',user_id:a}),/identity/);
  await publish();
  let data=await snapshot(sid);assert.equal(data.locations.length,1);assert.equal(data.locations[0].user_id,b);assert.equal(data.locations[0].stale,false);
  await assert.rejects(()=>publish({sequence:0}),/Sequence/);
  await assert.rejects(()=>publish(),/five seconds/);
  await command('destination',{session_id:sid,name:'Meet here',latitude:15.51,longitude:73.81});
  assert.equal((await snapshot(sid)).destination.set_by_user_id,b);
  await root(`update live_locations set received_at=now()-interval '16 seconds',client_timestamp=now()-interval '16 seconds' where session_id='${sid}'`);
  await root(`update location_sharing_consents set last_received_at=now()-interval '16 seconds' where session_id='${sid}'`);
  await asUser(b);assert.equal((await snapshot(sid)).locations[0].stale,true);
  await assert.rejects(()=>publish({latitude:50}),/Implausible/);
  await publish({accuracy:150});assert.equal((await snapshot(sid)).locations[0].poor_accuracy,true);
  // Stop and publication share a session lock: queued old-generation writes fail.
  const old=generation;
  await command('stop',{session_id:sid});await assert.rejects(()=>publish(),/explicit resume/);
  assert.equal((await snapshot(sid)).locations.length,0);
  ({generation}=await command('consent',{session_id:sid,consent_version:'live-map-v1'}));
  await assert.rejects(()=>publish({generation:old}),/explicit resume/);
  await assert.rejects(()=>publish(),/five seconds/);
  await root(`update location_sharing_consents set last_received_at=now()-interval '6 seconds' where session_id='${sid}'`);await asUser(b);await publish();
  await root(`update location_sharing_consents set lease_expires_at=now()-interval '1 second',last_received_at=now()-interval '31 seconds' where session_id='${sid}'`);
  await asUser(b);assert.equal((await snapshot(sid)).locations.length,0);
  await assert.rejects(()=>publish(),/explicit resume/);
  ({generation}=await command('consent',{session_id:sid,consent_version:'live-map-v1'}));await publish();
  await root(`select live_map_cleanup()`);await asUser(b);assert.equal((await snapshot(sid)).locations.length,1);
  await asUser(a);await companion('remove_member',{trip_id:trip,user_id:b});
  await asUser(b);await assert.rejects(()=>snapshot(sid),/access denied/);await assert.rejects(()=>publish(),/access denied/);
  await asUser(a);assert.equal((await snapshot(sid)).locations.length,0);
  await assert.rejects(()=>command('leave',{session_id:sid}),/Organizer/);
  await companion('archive_trip',{trip_id:trip,archived:true});await assert.rejects(()=>snapshot(sid),/access denied/);
  await companion('archive_trip',{trip_id:trip,archived:false});await assert.rejects(()=>snapshot(sid),/access denied/);
  // Standalone invitation rechecks shared-trip eligibility at acceptance, then is independent.
  const standalone=(await command('create',{name:'Standalone'})).session_id;
  await command('invite',{session_id:standalone,target_id:c});
  await companion('remove_member',{trip_id:trip,user_id:c});
  await asUser(c);await assert.rejects(()=>command('join',{session_id:standalone}),/Invitation/);
  await asUser(a);await companion('reinvite_member',{trip_id:trip,user_id:c});
  await asUser(c);await companion('join_trip',{token});await command('join',{session_id:standalone});
  await asUser(a);await companion('remove_member',{trip_id:trip,user_id:c});
  await asUser(c);assert.ok((await snapshot(standalone)).session);
  await command('leave',{session_id:standalone});await assert.rejects(()=>snapshot(standalone),/access denied/);
  await asUser(a);await command('start',{session_id:standalone});
  sid=standalone;({generation}=await command('consent',{session_id:sid,consent_version:'live-map-v1'}));await publish();
  await command('destination',{session_id:sid,name:'Regroup',latitude:1,longitude:2});
  await command('end',{session_id:sid});await assert.rejects(()=>snapshot(sid),/access denied/);
  await root(`select live_map_cleanup()`);
  assert.equal((await db.query('select count(*)::int n from live_locations')).rows[0].n,0);
  assert.equal((await db.query('select count(*)::int n from regroup_destinations')).rows[0].n,0);
  const receipts=(await db.query('select * from live_map_receipts')).rows;
  assert.ok(receipts.every(r=>r.fingerprint.length===64&&!JSON.stringify(r).includes('latitude')));
  await asUser(a);sid=(await command('create',{name:'Expiry'})).session_id;
  await root(`update live_sessions set created_at=now()-interval '3 hours',expires_at=now()-interval '1 second' where id='${sid}'`);
  await asUser(a);await assert.rejects(()=>snapshot(sid),/expired/);await assert.rejects(()=>command('start',{session_id:sid}),/expired/);
  await root(`select live_map_cleanup();update live_sessions set created_at=now()-interval '31 days 1 hour',expires_at=now()-interval '31 days' where id='${sid}';select live_map_cleanup()`);
  assert.equal((await db.query('select count(*)::int n from live_sessions where id=$1',[sid])).rows[0].n,0);
  console.log('PASS: Live Map RPC/RLS, account invitations, consent generations, publication validation, stale/lease expiry, withdrawal, trip invalidation, standalone eligibility, end, cleanup, redacted receipts');
  await db.close();
})().catch(error=>{console.error(error.message,error.detail??'',error.where??'');process.exit(1);});
