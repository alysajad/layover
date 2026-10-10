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
  for (const file of ['0001_init.sql','0002_companion.sql','0003_live_map.sql','0005_payment_expenses.sql','202610110001_trip_memories.sql']) {
    try { await db.exec(readFileSync(join(__dirname,'../migrations',file),'utf8')); }
    catch (error) { console.error(`Migration failed: ${file}`, error.message); throw error; }
  }
  const [admin,owner,peer,outsider]=Array.from({length:4},randomUUID);
  for (const id of [admin,owner,peer,outsider]) await db.query('insert into auth.users(id,email) values($1,$2)',[id,`${id}@test.invalid`]);
  await db.exec('grant select,insert,update,delete on all tables in schema public,storage to authenticated,anon');
  const asUser=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  const tripCmd=async(action,data)=>(await db.query('select companion_command($1,$2,$3) result',[action,data,randomUUID()])).rows[0].result;
  const cmd=async(action,data,key=randomUUID())=>(await db.query('select memory_command($1,$2,$3) result',[action,data,key])).rows[0].result;
  const snapshot=async()=>(await db.query('select memory_snapshot() result')).rows[0].result;
  const readable=async path=>(await db.query('select name from storage.objects where bucket_id=$1 and name=$2',['trip-memories',path])).rows.length;
  await asUser(admin);
  const {trip_id:trip}=await tripCmd('create_trip',{title:'Coastal trip',destination:'Kochi',start_date:'2030-01-01',end_date:'2030-01-04'});
  const {token}=await tripCmd('invite',{trip_id:trip});
  for(const id of [owner,peer]) {await asUser(id);await tripCmd('join_trip',{token});}
  await asUser(owner);
  const id=randomUUID(), request=randomUUID();
  const data={id,trip_id:trip,person_name:'Nila',note:'Met at the tea stall',place:'Fort Kochi',captured_at:'2030-01-02T12:00:00Z'};
  let memory=await cmd('save',data,request);
  assert.deepEqual(await cmd('save',data,request),memory);
  assert.equal(memory.shared,false);
  assert.equal(memory.destination,'Kochi');
  assert.equal((await snapshot()).length,1);
  const path=memory.photo_path;
  await assert.rejects(()=>cmd('ready',{id}),/incomplete/);
  await assert.rejects(()=>cmd('visibility',{id,shared:true,version:1}),/Back up/);
  await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',['trip-memories',path]);
  memory=await cmd('ready',{id});
  assert.equal(await readable(path),1);
  // No direct table policy accidentally exposes private metadata, even with table grants.
  assert.equal((await db.query('select * from trip_memories')).rows.length,0);
  for(const user of [admin,peer,outsider]) {
    await asUser(user);
    assert.deepEqual(await snapshot(),[]);
    assert.equal(await readable(path),0);
    await assert.rejects(()=>cmd('save',{...data,person_name:'Changed'}),/Only the owner/);
    await assert.rejects(()=>cmd('visibility',{id,shared:true,version:1}),/Only the owner/);
    await assert.rejects(()=>cmd('delete',{id}),/Only the owner/);
    await assert.rejects(()=>db.query('insert into storage.objects(bucket_id,name) values($1,$2)',['trip-memories',`${user}/${id}.jpg`]),/row-level security/);
  }
  await asUser(owner);
  memory=await cmd('visibility',{id,shared:true,version:memory.version});
  for(const user of [admin,peer]) {await asUser(user);assert.equal((await snapshot()).length,1);assert.equal(await readable(path),1);}
  await asUser(outsider);assert.equal(await readable(path),0);
  await assert.rejects(()=>cmd('save',{...data,id:randomUUID()}),/Trip access denied/);
  await asUser(owner);
  memory=await cmd('visibility',{id,shared:false,version:memory.version});
  await asUser(peer);assert.equal(await readable(path),0);
  await asUser(owner);
  memory=await cmd('visibility',{id,shared:true,version:memory.version});
  await asUser(admin);
  await tripCmd('remove_member',{trip_id:trip,user_id:owner});
  assert.deepEqual(await snapshot(),[]);
  assert.equal(await readable(path),0);
  await asUser(owner);
  memory=(await snapshot())[0];
  assert.equal(memory.shared,false);
  assert.equal(memory.can_share,false);
  assert.equal(await readable(path),1);
  memory=await cmd('save',{...data,person_name:'Nila from Kochi'});
  await assert.rejects(()=>cmd('visibility',{id,shared:true,version:memory.version}),/Trip access denied/);
  await asUser(admin);
  await tripCmd('reinvite_member',{trip_id:trip,user_id:owner});
  await asUser(owner);await tripCmd('join_trip',{token});
  memory=(await snapshot())[0];assert.equal(memory.shared,false);
  memory=await cmd('visibility',{id,shared:true,version:memory.version});
  await asUser(admin);await tripCmd('archive_trip',{trip_id:trip,archived:'true'});
  await asUser(owner);
  await assert.rejects(()=>cmd('save',{...data,id:randomUUID()}),/archived/);
  await assert.rejects(()=>cmd('visibility',{id,shared:true,version:memory.version}),/archived/);
  memory=await cmd('visibility',{id,shared:false,version:memory.version});
  memory=await cmd('delete',{id});
  assert.ok(memory.deleted_at);
  await db.query('delete from storage.objects where bucket_id=$1 and name=$2',['trip-memories',path]);
  assert.equal(await readable(path),0);
  await assert.rejects(()=>cmd('save',data),/deleted/);
  await asUser(peer);assert.deepEqual(await snapshot(),[]);
  await db.exec('reset role; set role anon');
  await assert.rejects(()=>snapshot(),/permission denied/);
  await db.close();
  console.log('PASS memories: private metadata/photos, organizer isolation, retries, share/unshare, owner-only edits, departure/rejoin, archives and deletion');
})().catch(error=>{console.error(error);process.exit(1);});
