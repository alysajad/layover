const {createDatabase}=require('./live_map_fixture.cjs');
const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const {randomUUID}=require('node:crypto');
const assert=require('node:assert/strict');

(async()=>{
  const db=await createDatabase();
  await db.exec(readFileSync(join(__dirname,'../migrations/0004_trip_explorer.sql'),'utf8'));
  const [owner,member,outsider]=Array.from({length:3},randomUUID);
  for(const id of [owner,member,outsider]) await db.query('insert into auth.users(id,email) values($1,$2)',[id,`${id}@example.test`]);
  const asUser=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  const command=async(action,data)=>(await db.query('select companion_command($1,$2,$3) as v',[action,data,randomUUID()])).rows[0].v;
  await asUser(owner);
  const {trip_id:trip}=await command('create_trip',{title:'Explorer',destination:'Goa',start_date:'2030-01-01',end_date:'2030-01-02'});
  const {token}=await command('invite',{trip_id:trip});await asUser(member);await command('join_trip',{token});await asUser(owner);
  const snapshot={schema_version:1,settings:{currency:'INR',budget_minor:100000,group_size:3,start_at:'2030-01-01T09:00:00Z',end_at:'2030-01-01T17:00:00Z',
    origin:[73.8,15.4],destination:null,zone:{type:'circle',center:[73.8,15.4],radius_m:5000},caps:{},modes:['walk']},places:[],allowances:[],itineraries:[],selected_candidate:0};
  const save=async(id,data=snapshot,parent=null)=>(await db.query('select explorer_save($1,$2,$3,$4,$5) as v',[id,trip,parent,'Plan',data])).rows[0].v;
  const list=async()=> (await db.query('select * from exploration_plans')).rows;
  const id=randomUUID();await save(id);assert.equal((await save(id)).version,1);
  await assert.rejects(()=>save(id,{...snapshot,settings:{...snapshot.settings,budget_minor:200000}}),/different input/);
  await assert.rejects(()=>db.query('select explorer_share($1)',[id]),/Generate/);
  const manual={id:'admission:p1',description:'Admission',currency:'INR',category:'admission',cost_basis:'per_person',quantity:1,
    estimate_status:'manual',low_minor:100,high_minor:200,author:outsider,checked_at:'2000-01-01',source:'User-entered',confidence:'user_supplied',covers:[]};
  const place={id:'p1',name:'Museum',provider_place_id:'p1',point:[73.81,15.41],selection_type:'must_visit',dwell_minutes:30,priority:1,cost:manual};
  const ready={...snapshot,places:[place],itineraries:[{id:'route1',provider:'fixture',checked_at:'2030-01-01',mode:'walk',duration_seconds:2100,
    geometry:{type:'LineString',coordinates:[[73.8,15.4],[73.81,15.41]]},stops:[place],
    legs:[{leg_order:0,origin:[73.8,15.4],destination:[73.81,15.41],transport_mode:'walk',distance_m:100,duration_seconds:300}],costs:[manual]}]};
  const v2=await save(randomUUID(),ready,id);assert.equal(v2.version,2);
  assert.equal(v2.snapshot.places[0].cost.author,owner);
  assert.notEqual(v2.snapshot.places[0].cost.checked_at,'2000-01-01');
  assert.equal((await save(v2.id,ready,id)).id,v2.id);
  const v3=await save(randomUUID(),v2.snapshot,v2.id);
  assert.equal(v3.snapshot.places[0].cost.checked_at,v2.snapshot.places[0].cost.checked_at);
  assert.equal((await list()).find(v=>v.id===id).status,'draft');
  await asUser(member);assert.equal((await list()).length,0);
  await assert.rejects(()=>save(randomUUID()),/Organizer/);
  await assert.rejects(()=>db.query('select explorer_provider_access($1)',[trip]),/Organizer/);
  await asUser(owner);await db.query('select explorer_share($1)',[v2.id]);await db.query('select explorer_share($1)',[v2.id]);
  assert.equal((await db.query("select * from exploration_plan_events where event_type='shared'")).rows.length,1);
  await asUser(member);assert.equal((await list()).length,1);
  await assert.rejects(()=>db.query('select explorer_share($1)',[v2.id]),/Organizer/);
  await assert.rejects(()=>db.query("update exploration_plans set title='Hack'"),/permission denied/);
  await asUser(outsider);assert.equal((await list()).length,0);
  await asUser(owner);
  await assert.rejects(()=>save(randomUUID(),{...snapshot,settings:{...snapshot.settings,group_size:0}}),/check constraint/);
  await assert.rejects(()=>save(randomUUID(),{...snapshot,settings:{...snapshot.settings,budget_minor:1.5}}),/Invalid budget/);
  await assert.rejects(()=>save(randomUUID(),{...snapshot,settings:{...snapshot.settings,origin:[200,0]}}),/coordinate/);
  await assert.rejects(()=>save(randomUUID(),{...snapshot,allowances:[{...manual,low_minor:-1,high_minor:10}]}),/Invalid money/);
  await assert.rejects(()=>save(randomUUID(),{...ready,itineraries:[{...ready.itineraries[0],legs:[]}]}),/stop\/leg/);
  for(let i=0;i<60;i++) await db.query('select explorer_provider_access($1)',[trip]);
  await assert.rejects(()=>db.query('select explorer_provider_access($1)',[trip]),/rate limit/);
  await command('remove_member',{trip_id:trip,user_id:member});await asUser(member);assert.equal((await list()).length,0);
  await asUser(owner);await command('archive_trip',{trip_id:trip,archived:true});
  await assert.rejects(()=>save(randomUUID()),/archived/);
  const snap=(await db.query('select companion_snapshot() as v')).rows[0].v;
  assert.equal(snap.expenses.length,0);assert.equal(snap.transfers.length,0);assert.equal(snap.pots.length,0);
  await db.close();console.log('PASS: explorer migrations, immutable versions, retry, sharing, RLS, removal, archive, validation, quotas, no money writes');
})().catch(e=>{console.error(e.message,e.where??'',e.position??'',e.internalPosition??'',e.internalQuery??'');process.exit(1);});
