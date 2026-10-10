// Use a web build with MAPBOX_PUBLIC_TOKEN. No hosted test accounts are needed.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const scripts=new Map();
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox','--enable-unsafe-swiftshader']});
 try {
 for(const width of (process.env.PHONE_ONLY ? [390] : [390,1440])) {
  const context=await browser.newContext({viewport:{width,height:1000}});
  const page=await context.newPage();
  const errors=[]; let writes=0;
  page.on('pageerror',e=>errors.push(e.stack?.slice(0,1000)||e.message));
  page.on('console',m=>{if(m.type()==='error')console.log('Console:',m.text().replace(/access_token=[^&\s]+/g,'access_token=REDACTED').slice(0,1200));});
  page.on('requestfailed',r=>{const u=new URL(r.url());console.log('Failed:',u.hostname,u.pathname,r.failure()?.errorText);});
  page.on('request',r=>{if(/\/rest\/v1\/rpc\//.test(r.url())) writes++;});
  // Use the exact CanvasKit binaries bundled in this build rather than the CDN.
  await page.route('https://www.gstatic.com/flutter-canvaskit/**',async route=>{
   const suffix=route.request().url().split('/').slice(5).join('/');
   const file=path.resolve(__dirname,'../build/web/canvaskit',suffix);
   if(fs.existsSync(file)) await route.fulfill({headers:{'access-control-allow-origin':'*'},path:file,contentType:file.endsWith('.wasm')?'application/wasm':'application/javascript'});
   else await route.continue();
  });
  await page.route('**/mapbox-gl.js', async route=>{
   try {
    const url=route.request().url();
    let script=scripts.get(url);
    if(!script) {
     script=process.env.MAPBOX_GL_PATH ? fs.readFileSync(process.env.MAPBOX_GL_PATH,'utf8') : await (await route.fetch({timeout:60000})).text();
     scripts.set(url,script);
    }
    await route.fulfill({contentType:'application/javascript',body:script+`;window.mapboxgl.Map=new Proxy(window.mapboxgl.Map,{construct(Target,args){const map=new Target(...args);window.campusMap=map;return map;}});`});
   } catch(e) {errors.push('Mapbox script download: '+e.message.split('\n')[0]);await route.abort();}
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
   console.log('Opened campus UI');
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
   await page.getByLabel('5× speed',{exact:true}).click();
   await page.getByLabel('offline',{exact:true}).first().click();
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
   console.log('Controls:',await page.locator('[role=radio],[role=checkbox]').evaluateAll(xs=>xs.map(x=>({role:x.getAttribute('role'),label:x.getAttribute('aria-label')}))));
   throw e;
  } finally {await context.close();}
 }
 } finally {await browser.close();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
