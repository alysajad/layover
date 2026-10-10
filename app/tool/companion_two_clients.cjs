// Isolated checked-RPC simulation. No hosted data or real payments are touched.
const {createDatabase}=require('../../supabase/tests/live_map_fixture.cjs');
const {randomUUID}=require('node:crypto');
const assert=require('node:assert/strict');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
(async()=>{
 const db=await createDatabase();
 const ids=Array.from({length:3},randomUUID);
 for(const [i,id] of ids.entries()) await db.query('insert into auth.users(id,email) values($1,$2)',[id,`nav-${i}@example.test`]);
 let queue=Promise.resolve();
 function rpc(user,fn,args=[]){
  const task=queue.then(async()=>{
   await db.exec('reset role');
   await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);
   await db.exec('set role authenticated');
   return (await db.query(`select public.${fn}(${args.map((_,i)=>`$${i+1}`).join(',')}) as result`,args)).rows[0].result;
  });
  queue=task.catch(()=>{});return task;
 }
 const clients=ids.map(id=>({id,state:null,timer:null,error:null,busy:false,
  command(action,data,key=randomUUID()){return rpc(id,'companion_command',[action,data,key]);},
  async poll(){if(this.busy)return;this.busy=true;try{this.state=await rpc(id,'companion_snapshot');}catch(e){this.error=e;}finally{this.busy=false;}},
  start(){this.timer=setInterval(()=>this.poll(),5000);},
  stop(){clearInterval(this.timer);}
 }));
 const [a,b,outside]=clients;
 async function synced(predicate){
  const deadline=Date.now()+6500;
  while(!predicate()) {if(Date.now()>deadline)throw Error('Update did not arrive by next poll');await sleep(25);}
  assert.equal(a.error,null);assert.equal(b.error,null);
 }
 try {
  const {trip_id:trip}=await a.command('create_trip',{title:'Navigation sync QA'});
  const {token}=await a.command('invite',{trip_id:trip});
  await b.command('join_trip',{token});
  await Promise.all([a.poll(),b.poll(),outside.poll()]);
  a.start();b.start();
  const entries={};
  for(const kind of ['poll','shortlist','itinerary','booking','task','meeting','contact','announcement']) {
   entries[kind]=(await a.command('save_entry',{trip_id:trip,kind,title:`QA ${kind}`,details:
    kind==='poll'?{poll_type:'Dates',options:['Friday','Saturday']}:
    kind==='task'?{assigned_to:b.id,done:false}:
    kind==='booking'?{reference:'QA-123'}:{}})).id;
  }
  await synced(()=>b.state.entries.length===8);
  console.log('PASS automatic Overview/Plan/Bookings/Group updates by the next five-second poll');
  await b.command('respond',{trip_id:trip,id:entries.poll,choices:['Friday','Saturday']});
  await b.command('respond',{trip_id:trip,id:entries.shortlist,choice:'yes'});
  await b.command('respond',{trip_id:trip,id:entries.meeting,choice:'arrived'});
  await b.command('toggle_task',{trip_id:trip,id:entries.task,done:true});
  await b.command('comment',{trip_id:trip,id:entries.booking,body:'Confirmation checked'});
  await synced(()=>a.state.comments.length===1 && a.state.responses.length===3 && a.state.entries.find(e=>e.id===entries.task).details.done);
  const booked=a.state.entries.find(e=>e.id===entries.booking);
  await a.command('save_entry',{trip_id:trip,id:booked.id,kind:'booking',title:'Updated booking',version:booked.version,details:{reference:'QA-456'}});
  await assert.rejects(()=>a.command('save_entry',{trip_id:trip,id:booked.id,kind:'booking',title:'Stale edit',version:booked.version,details:{}}),/Entry changed/);
  await a.command('choose_entry',{trip_id:trip,id:entries.poll,choice:'Friday'});
  await a.command('choose_entry',{trip_id:trip,id:entries.shortlist});
  await assert.rejects(()=>b.command('save_entry',{trip_id:trip,kind:'announcement',title:'Forbidden',details:{}}),/Only organizer/);
  await assert.rejects(()=>outside.command('comment',{trip_id:trip,id:entries.booking,body:'Forbidden'}),/access denied/);
  console.log('PASS votes, decisions, booking edit/conflict, comments, tasks, check-ins and access restrictions');
  await a.command('add_expense',{trip_id:trip,title:'Shared hotel',payer_id:a.id,amount_minor:20000,split_mode:'equal',weights:{[a.id]:1,[b.id]:1}});
  const key=randomUUID();const payload={trip_id:trip,recipient_id:a.id,amount_minor:10000};
  const payment=await b.command('report_transfer',payload,key);
  assert.deepEqual(await b.command('report_transfer',payload,key),payment);
  await synced(()=>a.state.expenses.length===1 && a.state.transfers.length===1);
  await a.command('transfer_status',{trip_id:trip,id:payment.id,status:'acknowledged'});
  await synced(()=>b.state.transfers[0]?.status==='acknowledged');
  const balance={[a.id]:0,[b.id]:0};
  for(const e of b.state.expenses){balance[e.payer_id]+=e.amount_minor;for(const [id,n]of Object.entries(e.splits))balance[id]-=n;}
  for(const t of b.state.transfers.filter(t=>t.status==='acknowledged')){balance[t.sender_id]+=t.amount_minor;balance[t.recipient_id]-=t.amount_minor;}
  assert.deepEqual(Object.values(balance),[0,0]);
  console.log('PASS Money expense/payment/recipient acknowledgement/settlement sync and retry idempotency');
  await a.command('delete_entry',{trip_id:trip,id:entries.contact});
  await a.command('archive_trip',{trip_id:trip,archived:true});
  await assert.rejects(()=>b.command('comment',{trip_id:trip,id:entries.booking,body:'After archive'}),/archived/);
  await a.command('archive_trip',{trip_id:trip,archived:false});
  await a.command('remove_member',{trip_id:trip,user_id:b.id});
  await synced(()=>b.state.trips.length===0);
  console.log('PASS deletion, archive/restore and removed-member data disappears by next poll');
 } finally {
  clients.forEach(c=>c.stop());await queue;await db.close();
 }
})().catch(e=>{console.error(e.message);process.exitCode=1});
