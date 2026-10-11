// Run against the local demo build; screenshots are saved to /tmp.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH, args: ['--no-sandbox', '--enable-unsafe-swiftshader'] });
  try {
    for (const width of [390, 1440]) {
      const context = await browser.newContext({ viewport: { width, height: 1000 } });
      const page = await context.newPage();
      const errors = [];
      page.setDefaultTimeout(12000);
      page.on('pageerror', error => errors.push(error.message));
      // Use the matching CanvasKit bundled by Flutter, without relying on its CDN.
      await page.route('https://www.gstatic.com/flutter-canvaskit/**', async route => {
        const suffix = route.request().url().split('/').slice(5).join('/');
        const file = path.resolve(__dirname, '../build/web/canvaskit', suffix);
        if (fs.existsSync(file)) await route.fulfill({ path: file, headers: { 'access-control-allow-origin': '*' }, contentType: file.endsWith('.wasm') ? 'application/wasm' : 'application/javascript' });
        else await route.continue();
      });
      try {
      await page.goto(process.env.PREVIEW_URL || 'http://127.0.0.1:5174');
      await page.waitForSelector('flutter-view');
      await page.waitForTimeout(1500);
      await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.dispatchEvent(new MouseEvent('click', { bubbles: true })));
      await page.getByText('Goa weekend', { exact: true }).first().waitFor();
      await page.getByRole('tab', { name: /^Money\b/ }).or(page.getByRole('button', { name: /^Money\b/ })).last().click();
      await page.getByLabel('Expenses', { exact: true }).click();
      await page.getByRole('button', { name: 'Paste payment message', exact: true }).click();
      await page.getByRole('textbox', { name: 'Payment notification or bank message' }).fill('Paid INR 840 to Sunset Cafe. UPI Ref 123456789012');
      await page.getByRole('button', { name: 'Continue', exact: true }).click();
      await page.getByRole('button', { name: 'Review expense', exact: true }).click();
      await page.getByRole('button', { name: 'Review', exact: true }).waitFor();
      await page.screenshot({ path: `/tmp/layover-payment-review-${width}.png`, fullPage: true });
      await page.getByRole('button', { name: 'Review', exact: true }).click();
      await page.getByRole('button', { name: 'Confirm', exact: true }).click();
      await page.getByText(/INR 840.00 · Food/).waitFor();
      await page.screenshot({ path: `/tmp/layover-payment-inbox-${width}.png`, fullPage: true });
      assert.deepEqual(errors, []);
      console.log(`PASS payment import and shared expense at ${width}px`);
      } catch (error) {
        await page.screenshot({path: `/tmp/layover-payment-failure-${width}.png`});
        console.log('UI:', (await page.locator('body').innerText()).slice(0, 3000));
        console.log('Errors:', errors);
        throw error;
      } finally { await context.close(); }
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });
