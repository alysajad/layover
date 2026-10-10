const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox']});
  for(const width of [390,1440]){
    const context=await browser.newContext({viewport:{width,height:1000}});
    const page=await context.newPage();const errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    await page.goto(process.env.PREVIEW_URL||'http://127.0.0.1:5173');
    await page.waitForSelector('flutter-view');
    await page.waitForTimeout(2500);
    await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.dispatchEvent(new MouseEvent('click',{bubbles:true})));
    await page.getByText('Goa weekend',{exact:true}).first().waitFor({timeout:30000});
    await page.screenshot({path:`/tmp/layover-companion-${width}.png`,fullPage:true});
    for(const label of ['Plan','Money','Bookings','Group','Overview']){
      const name=new RegExp(`^${label}\\b`);
      await page.getByRole('tab',{name}).or(page.getByRole('button',{name})).last().click();
      await page.waitForTimeout(300);
    }
    assert.deepEqual(errors,[]);
    assert.ok(fs.statSync(`/tmp/layover-companion-${width}.png`).size>10000);
    console.log(`PASS browser navigation and screenshot at ${width}px`);
    await context.close();
  }
  await browser.close();
})().catch(error=>{console.error(error);process.exit(1);});
