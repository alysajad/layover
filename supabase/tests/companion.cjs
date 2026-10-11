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
    -- Hosted Supabase installs pgcrypto outside public.
    create schema extensions;
    create extension pgcrypto with schema extensions;
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
  for (const file of ['0001_init.sql','0002_companion.sql','0003_live_map.sql','0005_payment_expenses.sql','0006_invite_random_bytes.sql']) {
    try { await db.exec(readFileSync(join(__dirname,'../migrations',file),'utf8')); }
    catch (error) { console.error(`Migration failed: ${file}`, error.message); throw error; }
  }
  const [a,b,c,outsider] = Array.from({length:4},randomUUID);
  for (const [id,name] of [[a,'Asha'],[b,'Rahul'],[c,'Meera'],[outsider,'Outsider']]) {
    await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,`${name}@example.test`,{display_name:name}]);
  }
  await db.exec('grant select,insert,update,delete on all tables in schema public,storage to authenticated,anon');
  const asUser = async id => { await db.exec('reset role'); await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]); await db.exec('set role authenticated'); };
  const cmd = async (action,data,key=randomUUID()) => (await db.query('select public.companion_command($1,$2,$3) as result',[action,data,key])).rows[0].result;
  const snapshot = async () => (await db.query('select public.companion_snapshot() as result')).rows[0].result;
  const rejected = async (action,data,pattern) => assert.rejects(()=>cmd(action,data),pattern);

  await asUser(a);
  const request=randomUUID();
  const creation={title:'Goa test',destination:'Goa',start_date:'2030-01-01',end_date:'2030-01-04'};
  const {trip_id:trip}=await cmd('create_trip',creation,request);
  assert.deepEqual(await cmd('create_trip',creation,request),{trip_id:trip});
  await assert.rejects(()=>cmd('create_trip',{...creation,title:'Changed'},request),/different input/);
  const beforeEdit=(await snapshot()).trips[0].updated_at;
  await cmd('update_trip',{trip_id:trip,...creation,start_date:'2030-01-02',expected_updated_at:beforeEdit});
  assert.equal((await snapshot()).trips[0].start_date,'2030-01-02');
  await rejected('update_trip',{trip_id:trip,...creation,expected_updated_at:beforeEdit},/Trip changed/);
  const inviteRequest=randomUUID();
  const {token}=await cmd('invite',{trip_id:trip},inviteRequest);
  assert.match(token,/^[0-9a-f]{48}$/);
  assert.deepEqual(await cmd('invite',{trip_id:trip},inviteRequest),{token});
  assert.equal((await snapshot()).invites.length,1);
  await assert.rejects(()=>db.query('select public.companion_command_base($1,$2,$3)',['invite',{trip_id:trip},randomUUID()]),/permission denied/);
  // The same migration also supports local installs with pgcrypto in public.
  await db.exec('reset role; alter extension pgcrypto set schema public;');
  await asUser(a);
  const {token:otherToken}=await cmd('invite',{trip_id:trip});
  assert.match(otherToken,/^[0-9a-f]{48}$/);
  assert.notEqual(otherToken,token);
  await db.exec('reset role; alter extension pgcrypto set schema extensions;');
  for(const id of [b,c]) {await asUser(id);await cmd('join_trip',{token});}
  await rejected('invite',{trip_id:trip},/Only organizer/);
  await asUser(a);
  const personalRequest=randomUUID();
  const personalData={trip_id:trip,title:'Private coffee',amount_minor:125050,category:'Food',expense_date:'2026-10-11',capture_id:personalRequest};
  const personal=await cmd('add_personal_expense',personalData,personalRequest);
  assert.deepEqual(await cmd('add_personal_expense',personalData,personalRequest),personal);
  const mine=await snapshot();
  assert.equal(mine.personal_expenses.length,1);
  assert.equal(mine.personal_expenses[0].expense_date,'2026-10-11');
  assert.ok(!mine.expenses.some(e=>e.id===personal.id));
  assert.ok(!JSON.stringify(mine.activity).includes('Private coffee'));
  await rejected('add_personal_expense',{...personalData,amount_minor:0,capture_id:null},/check constraint/);
  await rejected('add_personal_expense',{...personalData,category:'Invalid',capture_id:null},/check constraint/);
  await rejected('add_personal_expense',personalData,/Capture ID/);
  await assert.rejects(()=>cmd('add_personal_expense',{...personalData,title:'Changed'},personalRequest),/different input/);
  await assert.rejects(()=>db.query('select public.companion_snapshot_base()'),/permission denied/);
  await asUser(b);
  const theirs=await snapshot();
  assert.deepEqual(theirs.personal_expenses,[]);
  assert.ok(!JSON.stringify(theirs.notifications).includes('Private coffee'));
  assert.equal((await db.query('select * from personal_expenses')).rows.length,0);
  await rejected('void_personal_expense',{trip_id:trip,id:personal.id},/access denied/);
  await asUser(outsider);
  await rejected('add_personal_expense',{...personalData,capture_id:null},/access denied/);
  await asUser(a);
  await cmd('void_personal_expense',{trip_id:trip,id:personal.id});
  assert.ok((await snapshot()).personal_expenses[0].voided_at);
  const capturedRequest=randomUUID();
  const capturedData={trip_id:trip,title:'Captured cab',payer_id:a,amount_minor:30000,split_mode:'equal',weights:{[a]:1,[b]:1,[c]:1},category:'Transport',expense_date:'2026-10-10',capture_id:capturedRequest};
  const captured=await cmd('add_expense',capturedData,capturedRequest);
  assert.deepEqual(await cmd('add_expense',capturedData,capturedRequest),captured);
  assert.equal((await snapshot()).expenses.filter(e=>e.capture_id===capturedRequest).length,1);
  assert.equal((await snapshot()).expenses[0].expense_date,'2026-10-10');
  await assert.rejects(()=>cmd('add_personal_expense',{...personalData,capture_id:capturedRequest},capturedRequest),/different input/);
  await cmd('void_expense',{trip_id:trip,id:captured.id});
  // Keep legacy accounting assertions focused on their original fixtures.
  await db.exec('reset role');
  await db.query('delete from trip_expenses where id=$1',[captured.id]);
  await asUser(a);
  await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',['trip-files',`${trip}/${a}/receipt.pdf`]);
  await asUser(b);
  await rejected('update_trip',{trip_id:trip,...creation,expected_updated_at:beforeEdit},/Only organizer/);
  assert.equal((await db.query('select * from storage.objects')).rows.length,1);
  await assert.rejects(()=>db.query('insert into storage.objects(bucket_id,name) values($1,$2)',['trip-files',`${trip}/${a}/not-mine.pdf`]),/row-level security/);
  await asUser(a);
  const potData={trip_id:trip,title:'Villa',amount_minor:600000,split_mode:'equal',weights:{[a]:1,[b]:1,[c]:1},organizer_cover_minor:200000,deadline_at:'2030-01-01T00:00:00Z',terms:'Refund terms agreed by group'};
  await cmd('save_pot',potData);
  let data=await snapshot();let pot=data.pots[0];
  assert.equal(data.obligations.reduce((sum,o)=>sum+o.amount_minor_units,0),600000);
  await rejected('save_pot',{...potData,version:999},/Pot changed/);
  await asUser(b);
  await rejected('report_transfer',{trip_id:trip,pot_id:pot.id,recipient_id:a,amount_minor:200000},/Accept current terms/);
  for(const id of [a,b,c]) {await asUser(id);await cmd('accept_terms',{trip_id:trip,version:1});}
  let transferId;
  for(const id of [b,c]) {
    await asUser(id);
    const payload={trip_id:trip,pot_id:pot.id,recipient_id:a,amount_minor:200000};
    const retry=randomUUID();const result=await cmd('report_transfer',payload,retry);transferId=result.id;
    assert.deepEqual(await cmd('report_transfer',payload,retry),result);
    await rejected('transfer_status',{trip_id:trip,id:result.id,status:'acknowledged'},/Only recipient/);
    await asUser(a);await cmd('transfer_status',{trip_id:trip,id:result.id,status:'acknowledged'});
  }
  data=await snapshot();assert.equal(data.transfers.length,2);assert.equal(data.pots[0].status,'target_reached');
  const expense=await cmd('add_expense',{trip_id:trip,title:'Villa paid',payer_id:a,amount_minor:600000,split_mode:'equal',weights:{[a]:1,[b]:1,[c]:1}});
  data=await snapshot();const balance={[a]:0,[b]:0,[c]:0};
  for(const e of data.expenses){balance[e.payer_id]+=e.amount_minor;for(const [id,share] of Object.entries(e.splits))balance[id]-=share;}
  for(const t of data.transfers){balance[t.sender_id]+=t.amount_minor;balance[t.recipient_id]-=t.amount_minor;}
  assert.deepEqual(Object.values(balance),[0,0,0]);
  await cmd('save_pot',{...potData,version:data.pots[0].version});
  data=await snapshot();assert.notEqual(data.pots[0].status,'target_reached');
  assert.ok(data.obligations.every(o=>o.accepted_terms_version===null));
  await rejected('accept_terms',{trip_id:trip,version:1},/Terms changed/);
  const poll=await cmd('save_entry',{trip_id:trip,kind:'poll',title:'Dates',details:{options:['Friday','Saturday']}});
  const availability=await cmd('save_entry',{trip_id:trip,kind:'poll',title:'Available dates',details:{poll_type:'Dates',options:['Friday','Saturday']}});
  await cmd('respond',{trip_id:trip,id:availability.id,choices:['Friday','Saturday']});
  assert.equal((await snapshot()).responses.find(r=>r.entry_id===availability.id).response.choices.length,2);
  await rejected('respond',{trip_id:trip,id:availability.id,choices:['Sunday']},/Unknown poll option/);
  await asUser(b);await cmd('respond',{trip_id:trip,id:poll.id,choice:'Friday'});await cmd('respond',{trip_id:trip,id:poll.id,choice:'Saturday'});
  assert.equal((await snapshot()).responses.filter(r=>r.entry_id===poll.id).length,1);
  await rejected('choose_entry',{trip_id:trip,id:poll.id,choice:'Saturday'},/Only organizer/);
  await asUser(a);
  await rejected('save_entry',{trip_id:trip,id:poll.id,kind:'poll',title:'Dates',version:1,details:{options:['Sunday','Monday']}},/new poll/);
  await cmd('choose_entry',{trip_id:trip,id:poll.id,choice:'Saturday'});
  await rejected('respond',{trip_id:trip,id:poll.id,choice:'Friday'},/Decision is closed/);
  await rejected('save_entry',{trip_id:trip,id:poll.id,kind:'poll',title:'Dates',version:1,details:{options:['Friday','Saturday']}},/Entry changed/);
  const booking=await cmd('save_entry',{trip_id:trip,kind:'booking',title:'Stay',details:{remind_at:new Date().toISOString()}});
  await cmd('save_entry',{trip_id:trip,kind:'task',title:'Pack',details:{done:true,assigned_to:b}});
  const duplicate=await cmd('duplicate_trip',{source_id:trip,title:'Next trip'});
  data=await snapshot();assert.equal(data.entries.filter(e=>e.trip_id===duplicate.trip_id).length,1);
  assert.equal(data.expenses.filter(e=>e.trip_id===duplicate.trip_id).length,0);
  assert.equal(data.entries.find(e=>e.trip_id===duplicate.trip_id).details.done,false);
  await asUser(outsider);assert.equal((await snapshot()).trips.length,0);
  assert.equal((await db.query('select * from storage.objects')).rows.length,0);
  await assert.rejects(()=>db.query('select public.claim_trip_notifications()'),/permission denied/);
  await rejected('add_expense',{trip_id:trip,title:'Attack',payer_id:a,amount_minor:1,split_mode:'equal',weights:{[a]:1}},/access denied/);
  await assert.rejects(()=>db.query('update public.manual_transfers set status=$1 where id=$2 returning id',['acknowledged',transferId]).then(r=>{if(!r.rows.length)throw Error('RLS denied');}),/RLS denied/);
  await asUser(a);await cmd('remove_member',{trip_id:trip,user_id:c});
  await asUser(c);assert.equal((await snapshot()).trips.length,0);await rejected('join_trip',{token},/removed/);
  await asUser(a);await cmd('archive_trip',{trip_id:trip,archived:true});await rejected('comment',{trip_id:trip,id:booking.id,body:'No'},/archived/);
  await cmd('archive_trip',{trip_id:trip,archived:false});
  await rejected('void_expense',{trip_id:trip,id:expense.id},/former members must rejoin/);
  await cmd('reinvite_member',{trip_id:trip,user_id:c});
  await asUser(c);assert.equal((await snapshot()).trips.length,0);await cmd('join_trip',{token});
  await asUser(a);await cmd('void_expense',{trip_id:trip,id:expense.id});assert.ok((await snapshot()).expenses[0].voided_at);
  await rejected('remove_member',{trip_id:trip,user_id:b},/Settle this member/);
  const refund=await cmd('report_transfer',{trip_id:trip,pot_id:pot.id,recipient_id:b,amount_minor:200000});
  await rejected('transfer_status',{trip_id:trip,id:refund.id,status:'acknowledged'},/Only recipient/);
  await asUser(b);await cmd('transfer_status',{trip_id:trip,id:refund.id,status:'acknowledged'});
  await asUser(a);
  const correction=await cmd('report_transfer',{trip_id:trip,pot_id:pot.id,recipient_id:b,amount_minor:200000,replaces_id:refund.id});
  data=await snapshot();assert.equal(data.transfers.find(t=>t.id===refund.id).status,'withdrawn');assert.equal(data.transfers.find(t=>t.id===correction.id).status,'reported');
  await asUser(b);await cmd('transfer_status',{trip_id:trip,id:correction.id,status:'acknowledged'});
  await db.exec('reset role');await db.exec('select public.enqueue_trip_reminders(); select public.enqueue_trip_reminders();');
  const count=(await db.query("select count(*)::int as n from public.trip_notifications where dedupe_key like 'entry:%'")).rows[0].n;
  assert.equal(count,3);
  const firstBatch=await db.query('select id from public.claim_trip_notifications()');
  assert.ok(firstBatch.rows.length>0);assert.equal((await db.query('select id from public.claim_trip_notifications()')).rows.length,0);
  console.log('PASS: migrations, auth/RLS, invites, idempotency, pot revisions, acknowledgments, accounting, polls, templates, archive, reminders');
  await db.close();
})().catch(error=>{console.error(error.message,error.detail??'',error.where??'');process.exit(1);});
