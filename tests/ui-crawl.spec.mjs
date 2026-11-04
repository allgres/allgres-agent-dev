import { test, expect } from '@playwright/test';

// A crawler: open every page and tab of the dashboard and the Canvas, press the
// buttons the way a person would, and watch for what should never happen --
// an uncaught error, a console error, a style-policy violation, a request the
// server answered with a database error, a page that scrolls sideways, a title
// cut short. It does not know what is *right*; tests/ui-feature-effects.spec.mjs
// checks that things work. Buttons that delete or sign out are not pressed, and a
// dialog that opens is closed without saving.
const baseURL = process.env.ALLGRES_UI_URL || 'http://127.0.0.1:8088';

// Never pressed: they remove data or end the session.
const SKIP = /delete|remove|archive|sign ?out|log ?out|stop doing|revoke|reset|clear|drop|discard|uninstall|reject|decline|turn off|cancel|danger|rmDrop|rmToggle|mrRemove|rmCancel|rmDecline|clrTok|signOut|#toCanvas|toDashboard|activate|toggleActive|toggleRole|make (admin|user)|manageAssign/i;
// An error from the server that the page asked for on purpose (a form refused, a permission denied).
const BENIGN_SQLSTATE = new Set(['P0001', '42501', '22023']);
const SKIP_KO = /삭제|제거|보관|로그아웃|중단|폐기|초기화|비우기|거절|거부|끄기|취소|활성화|비활성|해지|관리자로|일반 사용자로/;
const LANG = process.env.CRAWL_LANG === 'ko' ? 'ko' : 'en';
const PRESS = 'button:not([disabled]), summary, [role="tab"]';

async function login(page, username, password) {
  const rpc = async body => (await page.request.post(baseURL + '/api/v1/rpc', { headers: { 'x-allgres-client': 'dashboard' }, data: body })).json();
  const t = await rpc({ action: 'auth.login', username, password });
  if (t.session_token) await rpc({ action: 'me.prefs_set', session_token: t.session_token, prefs: { 'ui.page': null, theme: null, lang: LANG === 'ko' ? 'ko' : null,
    'canvas.help_seen': null, 'canvas.ran': null, 'canvas.system': null, 'canvas.guide_hidden': null, 'ui.conv_id': null } });
  await page.goto(baseURL);
  await page.locator('#liUser').fill(username);
  await page.locator('#liPass').fill(password);
  await page.locator('#liGo').click();
  await expect(page.locator('#whoami')).toContainText(username);
}
const api = (page, body) => page.evaluate(async b => (await (await fetch('/api/v1/rpc', { method: 'POST',
  headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
  body: JSON.stringify({ ...b, session_token: sessionStorage.getItem('allgres_session_token') }) })).json()), body);

// What the pages show when there is something to show.
async function seed(page) {
  const call = async b => { const r = await api(page, b); if (r.ok === false && !/already|duplicate key/i.test(String(r.error))) console.log('seed:', b.action, r.error); return r; };
  await call({ action: 'provider.create', name: 'crawl_mock', kind: 'openai_compat', base_url: baseURL + '/mock', allow_private_network: true });
  for (const n of ['crawl_a', 'crawl_b'])
    await call({ action: 'agents.create', name: n, system_prompt: 'Answers briefly.', llm_config: { provider: 'crawl_mock', model: 'allgres-mock' }, is_active: true });
  const agents = (await api(page, { action: 'agents.list' })).agents;
  const a = agents.find(x => x.name === 'crawl_a'), b = agents.find(x => x.name === 'crawl_b');
  await call({ action: 'permissions.grant', agent_id: a.agent_id, type: 'agent', ref: 'crawl_b' });
  await call({ action: 'projects.create', name: 'crawl_project', description: 'for the crawler', agent_id: a.agent_id, preset_prompt: 'Be short.' });
  const room = await call({ action: 'rooms.create', name: 'crawl-room' });
  if (room.room_id) { await call({ action: 'rooms.member_add', room_id: room.room_id, agent_id: a.agent_id }); await call({ action: 'rooms.member_add', room_id: room.room_id, agent_id: b.agent_id }); }
  await call({ action: 'connections.create', name: 'crawl_api', base_url: baseURL + '/healthz', auth_kind: 'none', allow_private_network: true });
  const conv = await call({ action: 'conv.new', agent_id: a.agent_id });
  if (conv.conversation_id) await call({ action: 'conv.send', conversation_id: conv.conversation_id, message: 'hello crawler' });
  await call({ action: 'users.create', username: 'crawl_user', password: 'crawl-user-password', role: 'user' });
}

// Make the things the pages show, as an administrator in a page of its own (every seed call is repeatable).
async function ensureSeeded(browser) {
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  await login(p, 'ui_admin', 'ui-admin-password');
  await seed(p);
  await ctx.close();
}

function watch(page, issues, where) {
  const add = (kind, text) => issues.push({ where: where(), kind, text: String(text).replace(/\s+/g, ' ').slice(0, 500) });
  page.on('pageerror', e => add('uncaught error', `${e.message} @ ${String(e.stack || '').split('\n').slice(1, 3).map(l => l.trim()).join(' | ')}`));
  page.on('console', m => {
    if (m.type() !== 'error') return;
    const text = m.text();
    // A resource the page asked for and the browser could not load is the network's affair, not the page's.
    if (/Failed to load resource/.test(text)) return;
    add('console error', text);
  });
  page.on('dialog', d => d.dismiss().catch(() => {}));
  page.on('response', async r => {
    if (!r.url().includes('/api/v1/')) return;
    if (r.status() >= 500) { add('server error', `${r.status()} ${r.url().replace(baseURL, '')}`); return; }
    if (!r.url().endsWith('/api/v1/rpc')) return;
    try {
      const body = await r.json();
      if (body && body.ok === false && body.sqlstate && !BENIGN_SQLSTATE.has(body.sqlstate)) {
        let action = '?';
        try { action = r.request().postDataJSON().action; } catch { /* not JSON */ }
        add('database error', `${action}: ${body.error} (${body.sqlstate})`);
      }
    } catch { /* an event stream or an empty body */ }
  });
}

// Wait until the page has stopped asking for things.
async function settle(page) {
  await page.waitForTimeout(250);
  for (let i = 0; i < 12; i++) {
    const busy = await page.evaluate(() => Boolean(document.querySelector('#view')?.textContent?.match(/^\s*Loading…\s*$/)));
    if (!busy) break;
    await page.waitForTimeout(250);
  }
}

// In Korean, a visible word of plain English left on a page is a string nobody translated.
async function untranslated(page, issues, where) {
  if (LANG !== 'ko') return;
  const found = await page.evaluate(() => {
    const out = new Set();
    const w = document.createTreeWalker(document.querySelector('#view') || document.body, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) {
      const el = n.parentElement;
      if (!el || /^(SCRIPT|STYLE|CODE|PRE|OPTION|TEXTAREA|INPUT)$/.test(el.tagName) || el.closest('code,pre,.mono,td.mono,[data-user]')) continue;
      const r = el.getBoundingClientRect();
      if (!r.width || !r.height) continue;
      const t = n.textContent.trim();
      // Two or more English words in a row with no Korean in the text.
      if (/[가-힣]/.test(t)) continue;
      const words = t.match(/[A-Za-z][a-z]{2,}/g) || [];
      if (words.length >= 2 && !/[_/@.:\d]/.test(t)) out.add(t.slice(0, 60));
    }
    return [...out];
  });
  for (const t of found.slice(0, 8)) issues.push({ where: where(), kind: 'untranslated', text: t });
}

async function layout(page, issues, where) {
  await untranslated(page, issues, where);
  const bad = await page.evaluate(() => {
    const out = [];
    const de = document.documentElement;
    if (de.scrollWidth > de.clientWidth + 1) out.push(`the page scrolls sideways (${de.scrollWidth} wide in ${de.clientWidth})`);
    for (const el of document.querySelectorAll('h1,h2,h3,.title,summary b,th,.convTitle')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).textOverflow === 'ellipsis') out.push(`a title is cut short: "${el.textContent.trim().slice(0, 40)}"`);
    }
    // Text standing on end: a table cell far narrower than its words, so each line holds a letter or two.
    for (const el of document.querySelectorAll('td,th')) {
      const r = el.getBoundingClientRect();
      const txt = el.textContent.trim();
      if (r.width === 0 || txt.length < 4 || /\s/.test(txt) && txt.split(/\s+/).every(w => w.length < 3)) continue;
      if (r.width < 34 && r.height > r.width * 2.2) out.push(`text stands on end in a narrow column: "${txt.slice(0, 30)}" (${Math.round(r.width)}px wide, ${Math.round(r.height)}px tall)`);
    }
    // A button cut off at the edge of its box or the window.
    for (const el of document.querySelectorAll('#view button, #view .btn')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      let p = el.parentElement, clipped = false;
      while (p && p !== document.body) {
        const o = getComputedStyle(p);
        if (/(auto|scroll|hidden)/.test(o.overflowX) && p.scrollWidth > p.clientWidth + 1) break;   // it can be scrolled to
        p = p.parentElement;
      }
      if (!p || p === document.body) clipped = r.right > window.innerWidth + 1;
      if (clipped) out.push(`a button is beyond the window: "${(el.innerText || '').trim().slice(0, 30)}"`);
    }
    // Buttons side by side in one row that are not one height.
    for (const row of document.querySelectorAll('td, .row, .actions, .btnrow')) {
      const bs = [...row.querySelectorAll(':scope > button, :scope > .btn')].filter(b => { const r = b.getBoundingClientRect(); return r.width && r.height; });
      if (bs.length < 2) continue;
      const hs = bs.map(b => Math.round(b.getBoundingClientRect().height));
      if (Math.max(...hs) - Math.min(...hs) > 4) out.push(`buttons in one row are not one height (${hs.join(', ')}px): ${bs.map(b => '"' + (b.innerText || '').trim().slice(0, 14) + '"').join(', ')}`);
    }
    // The notice a person sees when they have asked for too much.
    if (/rate_limited|too many requests/i.test(document.querySelector('#toast')?.textContent || '')) out.push('the server said "rate_limited"');
    return out;
  });
  for (const text of bad) issues.push({ where: where(), kind: 'layout', text });
}

// The page shows a failure it caught itself as a notice at the bottom. A notice that is a program error
// ("null is not an object", "x is not a function") and not a message written for a person is a bug.
const PROGRAM_ERROR = /is not an object|is null|is undefined|undefined is not|cannot read|cannot set|is not a function|is not iterable|TypeError|ReferenceError|SyntaxError|\[object Object\]/i;
async function toastCheck(page, issues, where) {
  const text = await page.evaluate(() => { const t = document.querySelector('#toast'); return t && getComputedStyle(t).display !== 'none' ? t.textContent : ''; }).catch(() => '');
  if (text && PROGRAM_ERROR.test(text)) issues.push({ where: where(), kind: 'error notice', text });
}

// Press every button in `scope` once (never the ones in SKIP), closing what opens.
async function press(page, scope, reopen, issues, where, limit = 40, alsoSkip = null) {
  for (let i = 0; i < limit; i++) {
    const els = scope.locator(PRESS);
    const n = await els.count();
    if (i >= n) break;
    const el = els.nth(i);
    const label = await el.evaluate(e => `${e.innerText || e.getAttribute('aria-label') || ''} #${e.id} .${e.className}`.replace(/\s+/g, ' ').trim()).catch(() => '');
    if (!label || SKIP.test(label) || SKIP_KO.test(label) || (alsoSkip && alsoSkip.test(label))) continue;
    if (!(await el.isVisible().catch(() => false))) continue;
    const before = await page.evaluate(() => document.querySelector('#pageTitle')?.textContent);
    if (process.env.CRAWL_VERBOSE) console.log('  press:', where(), '>', label.slice(0, 60));
    try { await el.click({ timeout: 2500 }); } catch { continue; }
    await settle(page);
    await toastCheck(page, issues, () => `${where()} > ${label.slice(0, 40)}`);
    if (await page.locator('#modal:not(.hidden)').count()) {
      const inDialog = () => `${where()} > ${label.slice(0, 40)}`;
      await layout(page, issues, inDialog);
      // A dialog's own buttons are pressed once too (Start, Save, Add...): that is where "null is
      // not an object" hides. What they save is throwaway data of the crawl.
      // Its Close button is left for last (closeModal below), or the others would never be reached.
      await press(page, page.locator('#modal'), async () => {}, issues, inDialog, 12, /closeM|^close\b/i);
      await page.evaluate(() => closeModal?.());
    }
    const after = await page.evaluate(() => document.querySelector('#pageTitle')?.textContent);
    if (before !== after) await reopen();   // the press took us elsewhere: come back
  }
}

async function crawlDashboard(page, issues, current) {
  let pages = await page.locator('#nav button').allInnerTexts();
  // CRAWL_PAGES=Chat,Agents crawls only those menu entries (to look into something it found).
  if (process.env.CRAWL_PAGES) pages = pages.filter(n => process.env.CRAWL_PAGES.split(',').includes(n));
  for (const name of pages) {
    const open = async () => { await page.locator('#nav').getByRole('button', { name, exact: true }).click({ timeout: 4000 }); await settle(page); };
    console.log('crawl:', name);
    current.page = name; current.tab = '';
    try { await open(); } catch { issues.push({ where: name, kind: 'navigation', text: 'the menu entry could not be opened' }); continue; }
    await layout(page, issues, () => `${name}`);
    const tabs = await page.locator('#pageTabs [role="tab"]').allInnerTexts();
    const list = tabs.length ? tabs : [''];
    for (const tab of list) {
      current.tab = tab;
      // Back to this page and tab; if a press left somewhere with no such tab, say so and move on.
      const reopen = async () => {
        try { await open(); if (tab) await page.locator('#pageTabs').getByRole('tab', { name: tab, exact: true }).click({ timeout: 4000 }); } catch { /* not reachable now */ }
        await settle(page);
      };
      await reopen();
      await layout(page, issues, () => `${name}${tab ? ' / ' + tab : ''}`);
      await press(page, page.locator('#view'), reopen, issues, () => `${name}${tab ? ' / ' + tab : ''}`);
    }
  }
}

async function crawlCanvas(page, issues, current) {
  current.page = 'Canvas'; current.tab = '';
  await page.locator('#toCanvas').click();
  const cv = page.frameLocator('#canvasFrame');
  await cv.locator('body').waitFor({ timeout: 20000 });
  await page.waitForTimeout(1500);
  await layout(page, issues, () => 'Canvas');
  // The board's own buttons, then an agent's details and each of its tabs.
  await press(page, cv.locator('body'), async () => { await page.locator('#toCanvas').click(); await page.waitForTimeout(800); }, issues, () => 'Canvas', 25);
  const card = cv.locator('.agent-node, .an-head').first();
  if (await card.count()) {
    await card.click({ timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(600);
    for (const tab of ['Overview', 'Chat', 'Activity']) {
      const t = cv.getByRole('tab', { name: tab, exact: true });
      if (await t.count()) { await t.click().catch(() => {}); await page.waitForTimeout(500); await layout(page, issues, () => `Canvas / details / ${tab}`); }
    }
  }
}

function report(issues) {
  const seen = new Set();
  const rows = issues.filter(i => { const k = `${i.kind}|${i.where}|${i.text}`; if (seen.has(k)) return false; seen.add(k); return true; });
  return rows.map(i => `[${i.kind}] ${i.where}: ${i.text}`).join('\n');
}

test('the dashboard and the Canvas, as an administrator, show no error when every button is pressed', async ({ page, browser }) => {
  test.setTimeout(20 * 60 * 1000);
  const issues = [], current = { page: '', tab: '' };
  const where = () => `${current.page}${current.tab ? ' / ' + current.tab : ''}`;
  page.setDefaultTimeout(6000);
  await ensureSeeded(browser);
  await login(page, 'ui_admin', 'ui-admin-password');
  watch(page, issues, where);
  // CRAWL_ONLY=canvas runs just the Canvas (to look into something it found).
  if (process.env.CRAWL_ONLY !== 'canvas') await crawlDashboard(page, issues, current);
  await crawlCanvas(page, issues, current);
  const text = report(issues);
  if (text) console.log('\nCRAWL FOUND:\n' + text + '\n');
  expect(text, 'what the crawl found').toBe('');
});

test('the pages of a person who is not an administrator show no error either', async ({ page, browser }) => {
  test.setTimeout(10 * 60 * 1000);
  const issues = [], current = { page: '', tab: '' };
  const where = () => `(user) ${current.page}${current.tab ? ' / ' + current.tab : ''}`;
  page.setDefaultTimeout(6000);
  await ensureSeeded(browser);
  await login(page, 'crawl_user', 'crawl-user-password');
  watch(page, issues, where);
  await crawlDashboard(page, issues, current);
  const text = report(issues);
  if (text) console.log('\nCRAWL FOUND (user):\n' + text + '\n');
  expect(text, 'what the crawl found').toBe('');
});
