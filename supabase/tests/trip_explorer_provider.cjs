const ts=require('typescript');
const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const assert=require('node:assert/strict');
const source=readFileSync(join(__dirname,'../functions/trip-explorer/provider.ts'),'utf8');
const output=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const exportsObject={};new Function('exports',output)(exportsObject);
const {providerUrl,normalize}=exportsObject;
const input={action:'places',category:'all',zone:{type:'circle',center:[73.8,15.4],radius_m:5000}};
const url=providerUrl(input,'test-key');assert.equal(url.hostname,'api.geoapify.com');assert.equal(url.searchParams.get('limit'),'40');
assert.equal(url.searchParams.get('filter'),'circle:73.8,15.4,5000');
assert.throws(()=>providerUrl({...input,zone:{...input.zone,radius_m:1e9}},'test'),/radius/);
const route={action:'route',points:[[73.8,15.4],[73.9,15.5]],mode:'walk',path_kind:'short'};
assert.equal(providerUrl(route,'test').searchParams.get('waypoints'),'15.4,73.8|15.5,73.9');
assert.throws(()=>providerUrl({...route,mode:'cab'},'test'),/Unsupported/);
const result=normalize(route,{features:[{properties:{legs:[{time:5.4,distance:20}]},geometry:{type:'LineString',coordinates:route.points}}]},'2030-01-01');
assert.equal(result.routes[0].legs[0].duration_seconds,6);assert.equal(result.routes[0].checked_at,'2030-01-01');
assert.throws(()=>normalize(route,{features:[{properties:{legs:[]},geometry:{type:'LineString'}}]},'now'),/Incomplete/);
assert.deepEqual(normalize(input,{features:[]},'now'),{places:[]});
const places=normalize(input,{features:[{properties:{place_id:'place-1',lon:73.8,lat:15.4,name:'Museum',categories:['culture']}}]},'now');
assert.equal(places.places[0].provider_place_id,'place-1');assert.equal(places.places[0].selection_type,'excluded');
assert.equal(places.places[0].source_checked_at,'now');
// Rich listings keep online provenance and never label meals or fares as free admission.
const rich=normalize(input,{features:[{properties:{place_id:'food',lon:73.8,lat:15.4,categories:['catering','catering.food_court'],
 datasource:{raw:{cuisine:'kerala;seafood',fee:'no',website:'javascript:alert(1)',opening_hours:'09:00-21:00'}}}},
 {properties:{place_id:'bus',lon:73.8,lat:15.4,categories:['public_transport.bus'],datasource:{raw:{operator:'Local buses',fee:'no'}}}},
 {properties:{place_id:'park',lon:73.8,lat:15.4,categories:['leisure.park'],datasource:{raw:{fee:'no',wikipedia:'en:Some park'}}}}]},'now').places;
assert.equal(rich[0].kind,'food');assert.equal(rich[0].fee,'no');assert.equal(rich[0].free_admission,false);
assert.equal(rich[0].website,null);assert.equal(rich[0].cuisine,'kerala;seafood');
assert.equal(rich[1].kind,'transport');assert.equal(rich[1].free_admission,false);
assert.equal(rich[2].free_admission,true);
assert.equal(providerUrl({...input,category:'transport'},'test').searchParams.get('categories'),'public_transport,rental.bicycle,rental.car,rental.boat,service.taxi');
assert.equal(providerUrl({action:'search',text:'Kochi Fort'},'test').searchParams.get('text'),'Kochi Fort');
assert.throws(()=>providerUrl({action:'search',text:'a'},'test'));
assert.equal(normalize({action:'search'},{features:[{properties:{formatted:'Fort Kochi',lon:76.24,lat:9.96}}]},'now').results[0].name,'Fort Kochi');
assert.equal(providerUrl({action:'highlight',wikipedia:'en:Fort Kochi'},'').hostname,'en.wikipedia.org');
assert.throws(()=>providerUrl({action:'highlight',wikipedia:'https://127.0.0.1/private'},''));
assert.throws(()=>providerUrl({action:'highlight',wikipedia:'en:Title|Other'},''));
assert.equal(normalize({action:'highlight'},{extract:'Local history',content_urls:{desktop:{page:'https://en.wikipedia.org/wiki/Fort_Kochi'}}},'now').description,'Local history');
console.log('PASS: provider request bounds, coordinates, modes, normalization, missing/empty results');

(async()=>{
  const handlerSource=readFileSync(join(__dirname,'../functions/trip-explorer/index.ts'),'utf8').replace(/^import .*;\n/gm,'');
  const compiled=ts.transpileModule(handlerSource,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  let handler,authorized=true,accessError=null,configured=true,status=200,providerCalls=0;
  const createClient=()=>({auth:{getUser:async()=>({data:{user:authorized?{id:'organizer'}:null},error:null})},
    rpc:async()=>({error:accessError})});
  const Deno={serve:fn=>handler=fn,env:{get:name=>name==='GEOAPIFY_API_KEY'?(configured?'private-key':undefined):'config'}};
  const fetch=async()=>{providerCalls++;return new Response(JSON.stringify({features:[]}),{status});};
  new Function('Deno','createClient','normalize','providerUrl','fetch',compiled)(Deno,createClient,normalize,providerUrl,fetch);
  const request=(payload=input,token=true)=>new Request('https://example.test/trip-explorer',{method:'POST',headers:token?{Authorization:'Bearer fixture'}:{},body:JSON.stringify({...payload,trip_id:'trip'})});
  assert.equal((await handler(request(input,false))).status,401);assert.equal(providerCalls,0);
  authorized=false;assert.equal((await handler(request())).status,401);authorized=true;
  accessError={message:'Organizer access required'};assert.equal((await handler(request())).status,403);assert.equal(providerCalls,0);
  accessError={message:'Provider rate limit'};assert.equal((await handler(request())).status,429);accessError=null;
  configured=false;assert.equal((await handler(request())).status,503);configured=true;
  assert.equal((await handler(request({...input,zone:{type:'circle',center:[0,0],radius_m:-1}}))).status,400);
  status=429;assert.equal((await handler(request())).status,429);
  status=500;assert.equal((await handler(request())).status,502);
  status=200;const ok=await handler(request());assert.equal(ok.status,200);assert.deepEqual(await ok.json(),{places:[]});
  const preflight=await handler(new Request('https://example.test',{method:'OPTIONS'}));assert.equal(preflight.status,200);
  console.log('PASS: provider handler authentication, trip access, quotas, configuration, upstream failures and CORS');
})().catch(e=>{console.error(e);process.exit(1);});
