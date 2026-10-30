#!/usr/bin/env node
// Lists on-screen English strings that web/i18n/en.json does not have yet, by
// page, from a running instance (docs/i18n.md). Needs Playwright and an admin.
//   ALLGRES_UI_URL=http://127.0.0.1:8088 ALLGRES_USER=admin ALLGRES_PASS=… node scripts/i18n_extract.mjs
import { chromium } from '@playwright/test';
import fs from 'node:fs';

const base = process.env.ALLGRES_UI_URL || 'http://127.0.0.1:8088';
const en = JSON.parse(fs.readFileSync(new URL('../web/i18n/en.json', import.meta.url), 'utf8'));
const known = new Set(Object.values(en.sections).flatMap((m) => Object.keys(m)));
const keep = (x) => /[A-Za-z]/.test(x) && x.length >= 2 && x.length <= 220 && !/^(ui_|[0-9a-f]{8})/.test(x) && !/\d{4}-\d\d-\d\d/.test(x);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
await page.goto(base);
await page.locator('#liUser').fill(process.env.ALLGRES_USER || 'admin');
await page.locator('#liPass').fill(process.env.ALLGRES_PASS || '');
await page.locator('#liGo').click();
await page.waitForSelector('#whoami', { state: 'attached' });
const grab = (sel) => page.evaluate((sel) => {
  const out = [];
  const walk = (n) => {
    if (n.nodeType === 3) { const t = n.nodeValue.trim(); if (t) out.push(t); return; }
    if (n.nodeType !== 1 || /^(SCRIPT|STYLE|IFRAME)$/.test(n.tagName)) return;
    for (const a of ['placeholder', 'title', 'aria-label']) if (n.getAttribute(a)) out.push(n.getAttribute(a));
    n.childNodes.forEach(walk);
  };
  document.querySelectorAll(sel).forEach(walk);
  return out;
}, sel);
const found = {};
for (const id of await page.evaluate(() => adminPages.filter((p) => p !== 'Canvas'))) {
  await page.evaluate((i) => openPage(i), id);
  await page.waitForTimeout(700);
  found[id] = (await grab('#nav, .top, #pageTabs, #view')).filter((x) => keep(x) && !known.has(x));
}
const out = Object.fromEntries(Object.entries(found).map(([k, v]) => [k, [...new Set(v)]]).filter(([, v]) => v.length));
console.log(JSON.stringify(out, null, 1));
await browser.close();
