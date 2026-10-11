// NODE_PATH=/tmp/layover-check/node_modules node supabase/tests/trip_planner.cjs
const {PGlite}=require('@electric-sql/pglite');
const {pgcrypto}=require('@electric-sql/pglite/contrib/pgcrypto');
const ts=require('typescript');
const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const {randomUUID}=require('node:crypto');
const assert=require('node:assert/strict');
const api={};
new Function('exports',ts.transpileModule(readFileSync(join(__dirname,'../functions/trip-planner/planner.ts'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText)(api);
const settings={rooms:1,adults_per_room:2,food_daily_minor:50000,transport_daily_minor:50000,activity_daily_minor:10000,journey_minor:100000,origin:'Kochi',food_preferences:'vegetarian',transport_mode:'transit'};
const context={destination:'Munnar',start_date:'2030-01-01',end_date:'2030-01-03',budget_minor:1000000,currency:'INR',members:['a','b']};
const job={settings,context};
const clock=new Date('2029-12-30T00:00:00Z');
const x=api.validateJob(job,clock);
const raw={search_parameters:{currency:'INR',check_in_date:context.start_date,check_out_date:context.end_date,adults:2},properties:[
  {type:'hotel',name:'Hill stay',gps_coordinates:{latitude:10.08,longitude:77.06},total_rate:{extracted_lowest:1200.01},overall_rating:4.6,reviews:400,link:'https://example.com/book'},
  {type:'hotel',name:'Unknown price',gps_coordinates:{latitude:10.08,longitude:77.06},rate_per_night:{extracted_lowest:100}},
  {type:'vacation rental',name:'Entire villa',gps_coordinates:{latitude:10.08,longitude:77.06},total_rate:{extracted_lowest:100}}
]};
const hotels=api.hotels(raw,x);
assert.equal(hotels.length,1);assert.equal(hotels[0].total_minor,120001);
assert.throws(()=>api.hotels({...raw,search_parameters:{...raw.search_parameters,currency:'USD'}},x),/match/);
assert.throws(()=>api.validateJob({...job,settings:{...settings,rooms:0}},clock));
assert.throws(()=>api.validateJob({...job,context:{...context,members:['a','b','c']}},clock),/occupancy/);
assert.equal(api.safeLink('javascript:alert(1)'),null);
assert.equal(api.safeLink('https://serpapi.com/search?api_key=private'),null);
const sights=api.places({local_results:[{title:'Tea museum',rating:4.5,reviews:500,gps_coordinates:{latitude:10.08,longitude:77.065}},
  {title:'Far away',gps_coordinates:{latitude:0,longitude:0}}, {title:'Closed',permanently_closed:true,gps_coordinates:{latitude:10.08,longitude:77.065}}]},'sights');
assert.equal(sights.length,2);
const cafes=api.places({local_results:[{title:'Tea cafe',rating:4.8,reviews:10,type:'Tea house',description:'Tea and local snacks',gps_coordinates:{latitude:10.085,longitude:77.066}}]},'cafes');
const food=api.places({local_results:[{title:'Local food',rating:4.4,reviews:100,type:'Kerala restaurant',gps_coordinates:{latitude:10.085,longitude:77.066}}]},'food');
const weather=api.weatherDays({daily:{time:['2029-12-31','2030-01-01'],temperature_2m_max:[30,29],temperature_2m_min:[12,13],precipitation_probability_max:[90,60]}},x);
assert.equal(weather.length,1);
const inventory={hotels,sights,cafes,food,weather};
const plan=api.buildPlan(job,inventory,clock);
assert.equal(plan.options.length,1);assert.equal(plan.options[0].days.length,3);
assert.equal(plan.options[0].costs.food,300000);
assert.equal(plan.options[0].total_minor,830001);
assert(plan.options[0].entries.some(e=>e.key==='packing/rain'));
assert(plan.options[0].entries.some(e=>e.key==='packing/layers'));
assert(!JSON.stringify(plan.options).includes('Far away'));
assert.equal(plan.options[0].entries.filter(e=>e.title==='Tea museum').length,1);
assert(plan.warnings.some(v=>v.includes('Forecast')));
assert.equal(api.buildPlan({...job,context:{...context,budget_minor:1000}},inventory,clock).options.length,0);
assert.equal(api.buildPlan(job,{...inventory,hotels:[]},clock).options.length,0);
assert.equal(api.searchUrl('hotels',x,'secret').searchParams.get('adults'),'2');
assert.equal(api.searchUrl('food',x,'secret').searchParams.get('q'),'vegetarian local food restaurants in Munnar');
console.log('PASS provider normalization: occupancy/currency/dates, missing prices, integer budgets, geographic bounds, forecast dates and packing');
(async()=>{
 const db=new PGlite({extensions:{pgcrypto}});
 await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
 create schema auth; create schema storage;
 create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
 alter table storage.objects enable row level security;
 create function storage.foldername(text) returns text[] language sql as $$ select string_to_array($1,'/') $$;
 grant usage on schema public,auth,storage to authenticated,anon,service_role;`);
 for(const file of ['0001_init.sql','0002_companion.sql','0003_live_map.sql','0005_payment_expenses.sql','202610110002_trip_planner.sql']) {
   try {await db.exec(readFileSync(join(__dirname,'../migrations',file),'utf8'));}catch(e){console.error(file,e.message);throw e;}
 }
 const [admin,peer,outsider]=Array.from({length:3},randomUUID);
 for(const id of [admin,peer,outsider]) await db.query('insert into auth.users(id,email) values($1,$2)',[id,id+'@test.invalid']);
 const user=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
 const rpc=async(fn,args)=> (await db.query(`select ${fn}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
 const cmd=(a,d)=>rpc('companion_command',[a,d,randomUUID()]);
 const root=()=>db.exec('reset role');
 const claim=async()=>{await root();return rpc('planner_claim',[trip]);};
 await user(admin);
 const {trip_id:trip}=await cmd('create_trip',{title:'Mountain trip',destination:'Munnar',start_date:context.start_date,end_date:context.end_date});
 const {token}=await cmd('invite',{trip_id:trip});await user(peer);await cmd('join_trip',{token});await user(admin);
 await cmd('save_pot',{trip_id:trip,title:'Trip pot',amount_minor:1000000,split_mode:'equal',weights:{[admin]:1,[peer]:1},deadline_at:'2030-01-01T00:00:00Z',terms:'External payment, confirm receipt',organizer_cover_minor:500000});
 let p=await rpc('planner_configure',[trip,settings,0]);assert.equal(p.state,'waiting');
 assert.equal(await claim(),null);
 await user(peer);await assert.rejects(()=>rpc('planner_state',[trip]),/Organizer/);
 await assert.rejects(()=>rpc('planner_configure',[trip,settings,0]),/Organizer/);
 await assert.rejects(()=>rpc('planner_claim',[trip]),/permission denied/);
 await assert.rejects(()=>db.query('select * from trip_planners'),/permission denied/);
 for(const id of [admin,peer]){await user(id);await cmd('accept_terms',{trip_id:trip,version:1});}
 const pot=(await rpc('companion_snapshot',[])).pots[0];
 const transfer=await cmd('report_transfer',{trip_id:trip,pot_id:pot.id,recipient_id:admin,amount_minor:500000});
 assert.equal(await claim(),null); // reported money never funds the planner
 await user(admin);await cmd('transfer_status',{trip_id:trip,id:transfer.id,status:'acknowledged'});
 p=await claim();assert.equal(p.state,'running');
 assert.equal(await claim(),null); // concurrent claim cannot run the same paid search twice
 assert.equal(await rpc('planner_complete',[trip,randomUUID(),plan,null]),false);
 assert.equal(await rpc('planner_complete',[trip,p.lease_id,plan,null]),true);
 await user(outsider);await assert.rejects(()=>rpc('planner_publish',[trip,p.run_id,0]),/Organizer/);
 await user(peer);await assert.rejects(()=>rpc('planner_publish',[trip,p.run_id,0]),/Organizer/);
 await user(admin);let published=await rpc('planner_publish',[trip,p.run_id,0]);assert(published.updated>0);
 const first=await rpc('companion_snapshot',[]);
 assert.equal(first.expenses.length,0);assert.equal(first.pots[0].status,'target_reached');
 assert(first.entries.some(e=>e.kind==='announcement'));assert(first.entries.some(e=>e.kind==='booking'&&e.details.booking_status==='planned'));
 assert.deepEqual(await rpc('planner_publish',[trip,p.run_id,0]),{already_shared:true});
 assert.equal((await rpc('companion_snapshot',[])).entries.length,first.entries.length);
 await user(peer);assert((await rpc('companion_snapshot',[])).entries.some(e=>e.kind==='itinerary'));
 assert((await rpc('companion_snapshot',[])).notifications.some(n=>n.dedupe_key==='plan-shared:'+p.run_id));
 await user(admin);
 const entry=first.entries.find(e=>e.kind==='itinerary');
 await cmd('save_entry',{trip_id:trip,id:entry.id,version:entry.version,kind:'itinerary',title:'My edited day',details:entry.details});
 const task=first.entries.find(e=>e.kind==='task');await cmd('toggle_task',{trip_id:trip,id:task.id,done:true});
 await root();await db.query("update trip_planners set requested_at=now()-interval '2 minutes' where trip_id=$1",[trip]);
 await user(admin);p=await rpc('planner_configure',[trip,settings,1]);
 let job2=await claim();await rpc('planner_complete',[trip,job2.lease_id,plan,null]);
 await user(admin);published=await rpc('planner_publish',[trip,p.run_id,0]);assert.equal(published.preserved,2);
 let snap=await rpc('companion_snapshot',[]);assert(snap.entries.some(e=>e.title==='My edited day'));assert(snap.entries.find(e=>e.id===task.id).details.done);
 // Context changes invalidate an in-flight job and old publish attempts.
 await root();await db.query("update trip_planners set requested_at=now()-interval '2 minutes' where trip_id=$1",[trip]);
 await user(admin);p=await rpc('planner_configure',[trip,settings,2]);job2=await claim();
 await db.query("update trips set destination='Kochi' where id=$1",[trip]);
 assert.equal(await rpc('planner_complete',[trip,job2.lease_id,plan,null]),false);
 await user(admin);assert.equal((await rpc('planner_state',[trip])).stale,true);
 await assert.rejects(()=>rpc('planner_publish',[trip,p.run_id,0]),/Refresh/);
 job2=await claim();assert.equal(job2.context.destination,'Kochi');assert.notEqual(job2.run_id,p.run_id);
 await rpc('planner_complete',[trip,job2.lease_id,plan,null]);
 await db.query("update trip_planners set generated_at=now()-interval '25 hours' where trip_id=$1",[trip]);
 await user(admin);await assert.rejects(()=>rpc('planner_publish',[trip,job2.run_id,0]),/Prices are old/);
 await root();await db.query("update trips set archived_at=now() where id=$1",[trip]);
 await user(admin);await assert.rejects(()=>rpc('planner_publish',[trip,job2.run_id,0]),/archived/);
 console.log('PASS database: confirmed funding, private drafts, leased jobs, atomic/idempotent sharing, no expenses/reservations, peer updates, preserved edits, stale contexts and quote expiry');
 await db.close();
})().catch(e=>{console.error(e.message);process.exitCode=1;});
