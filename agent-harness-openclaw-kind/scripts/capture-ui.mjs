// Runs inside the OpenClaw gateway container: open the authenticated Control UI in the
// container's own managed Chromium (over CDP) and screenshot it. The page stays open in
// the browser so approve-ui.mjs can find it.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const { chromium } = createRequire('/app/package.json')('playwright-core');
const browser = await chromium.connectOverCDP('http://127.0.0.1:18800');
const context = browser.contexts()[0];
const page = await context.newPage();
await page.setViewportSize({ width: 1440, height: 1000 });
await page.goto('http://127.0.0.1:18789/#token=' + encodeURIComponent(process.env.OPENCLAW_GATEWAY_TOKEN));
await page.waitForTimeout(4000);
fs.mkdirSync('/home/node/.openclaw/lab-captures', { recursive: true });
await page.screenshot({ path: '/home/node/.openclaw/lab-captures/control-ui.png' });
console.log((await page.locator('body').innerText()).slice(0, 2000));
await browser.close();
