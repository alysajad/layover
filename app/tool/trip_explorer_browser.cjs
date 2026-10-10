const {chromium}=require('playwright');
const assert=require('node:assert/strict');
(async()=>{
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox']});
  for(const width of [390,1440]) {
    const context=await browser.newContext({viewport:{width,height:1000}});
    const page=await context.newPage(),errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.goto(process.env.PREVIEW_URL || 'http://127.0.0.1:5174');
    await page.waitForSelector('flutter-view');
    await page.waitForTimeout(1500);
    await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.dispatchEvent(new MouseEvent('click',{bubbles:true})));
    const demo=page.getByRole('button',{name:'Explore demo trip',exact:true});
    if(await demo.isVisible()) await demo.click();
    await page.getByText('Goa weekend',{exact:true}).first().waitFor();
    await page.getByRole('button',{name:/Explore within budget/}).click();
    await page.getByRole('button',{name:'Find places',exact:true}).click();
    await page.getByText('Choose the places worth stopping for',{exact:true}).waitFor();
    await page.getByLabel('must visit',{exact:true}).first().click();
    await page.getByRole('button',{name:'Generate alternatives',exact:true}).click();
    await page.getByText('A few ways to spend the day',{exact:true}).waitFor();
    await page.screenshot({path:`/tmp/layover-explorer-${width}.png`,fullPage:true});
    await page.getByRole('button',{name:'Save new version',exact:true}).click();
    await page.getByText('Saved version 1.',{exact:true}).waitFor();
    await page.getByRole('button',{name:'Share with trip',exact:true}).click();
    await page.getByText('Shared with current trip members.',{exact:true}).waitFor();
    assert.deepEqual(errors,[]);
    await context.close();console.log(`PASS: explorer browser flow at ${width}px`);
  }
  await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
