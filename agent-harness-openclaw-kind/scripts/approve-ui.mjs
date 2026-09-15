// Runs inside the OpenClaw gateway container: find the session's pending exec approval in
// the Control UI, check it is exactly `uname -a`, screenshot it and click Allow once.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const { chromium } = createRequire('/app/package.json')('playwright-core');
const browser = await chromium.connectOverCDP('http://127.0.0.1:18800');
const context = browser.contexts()[0];
const page = context.pages().find(p => p.url().startsWith('http://127.0.0.1:18789/'));
if (!page) throw Error('Open the authenticated Control UI with capture-ui.mjs first');
await page.getByText('explicit:' + process.argv[2], { exact: true }).first().click({ timeout: 60000 });
const allow = page.getByRole('button', { name: 'Allow once', exact: true });
await allow.waitFor({ timeout: 90000 });
await page.getByText('Exec approval needed', { exact: true }).waitFor();
// Fail closed if the visible request is not our exact harmless command.
if (!(await page.getByText('uname -a', { exact: true }).count())) throw Error('Unexpected command in the approval');
if (await allow.count() !== 1) throw Error('Ambiguous approvals');
fs.mkdirSync('/home/node/.openclaw/lab-captures', { recursive: true });
await page.screenshot({ path: '/home/node/.openclaw/lab-captures/approval.png' });
await allow.click();
await browser.close();
