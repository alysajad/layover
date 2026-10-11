// Local demo: exercise drawn areas and the budget shortlist at phone/desktop sizes.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox','--enable-unsafe-swiftshader']});
 try {for(const width of [390,1440]) {
  const context=await browser.newContext({viewport:{width,height:1000}});
  const page=await context.newPage();page.setDefaultTimeout(20000);
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://www.gstatic.com/flutter-canvaskit/**',async route=>{
    const suffix=route.request().url().split('/').slice(5).join('/');
    const file=path.resolve(__dirname,'../build/web/canvaskit',suffix);
    if(fs.existsSync(file)) await route.fulfill({headers:{'access-control-allow-origin':'*'},path:file,contentType:file.endsWith('.wasm')?'application/wasm':'application/javascript'});
    else await route.continue();
  });
  try {
    await page.goto(process.env.PREVIEW_URL||'http://127.0.0.1:5174');
    await page.waitForSelector('flutter-view');await page.waitForTimeout(1500);
    await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.click());
    const demo=page.getByRole('button',{name:'Explore demo trip',exact:true});
    if(await demo.isVisible()) await demo.click();
    await page.getByText('Goa weekend',{exact:true}).first().waitFor();
    await page.getByRole('button',{name:/Explore within budget/}).click();
    await page.getByRole('button',{name:'Edit budget and time',exact:true}).click();
    assert.equal(await page.getByRole('textbox',{name:/longitude|latitude/i}).count(),0);
    await page.screenshot({path:`/tmp/layover-budget-settings-${width}.png`});
    await page.getByRole('button',{name:'Apply',exact:true}).click();
    await page.getByLabel('Freehand',{exact:true}).click();
    const surface=page.getByText('Draw a freehand area on the map',{exact:true});
    await surface.scrollIntoViewIfNeeded();
    const b=await surface.boundingBox();assert.ok(b);
    await page.mouse.move(b.x+b.width*.2,b.y+b.height*.25);await page.mouse.down();
    for(const [x,y] of [[.8,.25],[.8,.8],[.2,.8],[.2,.25]]) await page.mouse.move(b.x+b.width*x,b.y+b.height*y,{steps:20});
    await page.mouse.up();
    await page.getByText(/Your drawn area ·/).waitFor();
    await page.screenshot({path:`/tmp/layover-drawn-area-${width}.png`});
    await page.getByRole('button',{name:'Undo area',exact:true}).click();
    await page.getByRole('button',{name:'Find places',exact:true}).click();
    await page.getByLabel(/Demo heritage courtyard/).first().waitFor();
    await page.getByRole('button',{name:'Suggest budget stops',exact:true}).click();
    await page.getByText(/Suggested 3 stops/).waitFor();
    await page.screenshot({path:`/tmp/layover-area-results-${width}.png`});
    await page.getByLabel(/Demo local bus stop/).first().scrollIntoViewIfNeeded();
    await page.screenshot({path:`/tmp/layover-area-transport-${width}.png`});
    await page.getByRole('button',{name:'Generate alternatives',exact:true}).click();
    await page.getByText('A few ways to spend the day',{exact:true}).waitFor();
    await page.screenshot({path:`/tmp/layover-explorer-${width}.png`});
    await page.getByRole('button',{name:'Save new version',exact:true}).click();
    await page.getByText('Saved version 1.',{exact:true}).waitFor();
    await page.getByRole('button',{name:'Share with trip',exact:true}).click();
    await page.getByText('Shared with current trip members.',{exact:true}).waitFor();
    assert.deepEqual(errors,[]);console.log(`PASS ${width}px: draw freehand, undo, calendar/dropdown settings, food/transport discovery, budget shortlist and routes`);
  } catch(e) {await page.screenshot({path:`/tmp/layover-explorer-failure-${width}.png`});console.log((await page.locator('body').innerText()).slice(0,2400));console.log(errors);throw e;}
  finally {await context.close();}
 }} finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
