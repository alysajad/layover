// Use a web build with MAPBOX_PUBLIC_TOKEN. No hosted test accounts are needed.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox','--enable-unsafe-swiftshader']});
 try {
 for(const width of [390,1440]) {
  const context=await browser.newContext({viewport:{width,height:1000}});
  const page=await context.newPage();
  const errors=[]; let writes=0;
  page.on('pageerror',e=>errors.push(e.message));
  page.on('request',r=>{if(/\/rest\/v1\/rpc\//.test(r.url())) writes++;});
  await page.addInitScript(()=>{
   let gl;
   Object.defineProperty(window,'mapboxgl',{configurable:true,get(){return gl;},set(value){
    gl=value;
    gl.Map=new Proxy(gl.Map,{construct(Target,args){const map=new Target(...args);window.campusMap=map;return map;}});
   }});
  });
  try {
   await page.goto(process.env.PREVIEW_URL||'http://127.0.0.1:5173');
   await page.waitForSelector('flutter-view');
   await page.waitForTimeout(2000);
   await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.click());
   await page.getByRole('button',{name:'Explore demo trip',exact:true}).click();
   await page.getByText('Goa weekend',{exact:true}).first().waitFor();
   await page.getByRole('button',{name:/CUSAT · 3D test run/}).click();
   await page.getByText('SIMULATION · YOU ARE ADMIN',{exact:true}).waitFor();
   await page.waitForFunction(()=>window.campusMap?.getLayer('live-buildings')&&window.campusMap?.getPitch()>50,null,{timeout:45000});
   await page.waitForFunction(()=>window.campusMap?.loaded(),null,{timeout:45000});
   const first=await page.evaluate(()=>JSON.stringify(window.campusMap.getSource('live-group')._data));
   await page.waitForTimeout(2500);
   const second=await page.evaluate(()=>JSON.stringify(window.campusMap.getSource('live-group')._data));
   assert.notEqual(first,second,'Runner markers must move automatically');
   const state=await page.evaluate(()=>({center:window.campusMap.getCenter(),buildings:window.campusMap.queryRenderedFeatures({layers:['live-buildings']}).length}));
   assert.ok(state.center.lat>10.03&&state.center.lat<10.06);
   assert.ok(state.buildings>0,'Campus buildings must render');
   await page.screenshot({path:`/tmp/layover-cusat-${width}.png`});
   await page.getByRole('button',{name:'Test controls',exact:true}).click();
   await page.getByRole('button',{name:/^5× speed/}).click();
   await page.getByRole('button',{name:/^offline/}).first().click();
   await page.screenshot({path:`/tmp/layover-cusat-controls-${width}.png`});
   await page.getByRole('button',{name:'Back to map',exact:true}).click();
   await page.getByRole('button',{name:'Show my test marker',exact:true}).click();
   await page.getByRole('button',{name:'Show test marker',exact:true}).click();
   await page.getByText('Your test marker is visible',{exact:true}).waitFor();
   await page.getByRole('button',{name:'Stop sharing',exact:true}).click();
   assert.equal(writes,0,'Simulation must never call backend RPCs');
   assert.deepEqual(errors,[]);
   console.log(`PASS ${width}px: ${state.buildings} building features in 3D, moving runners, controls, synthetic admin marker, no backend writes`);
  } catch(e) {
   await page.screenshot({path:`/tmp/layover-cusat-failure-${width}.png`});
   console.log('UI:',(await page.locator('body').innerText()).slice(0,1600));
   console.log('Errors:',errors);
   throw e;
  } finally {await context.close();}
 }
 } finally {await browser.close();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
