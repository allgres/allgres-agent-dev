import { test, expect } from '@playwright/test';
import { createHmac } from 'node:crypto';

const baseURL = process.env.ALLGRES_UI_URL || 'http://127.0.0.1:8088';
test.describe.configure({ mode: 'serial' });

async function login(page, username, password) {
  // The last page is remembered per person in the database, so a test starts
  // from the person's first page rather than wherever an earlier test ended.
  const rpc = async body => (await page.request.post(baseURL + '/api/v1/rpc', { headers: { 'x-allgres-client': 'dashboard' }, data: body })).json();
  const t = await rpc({ action: 'auth.login', username, password });
  if (t.session_token) await rpc({ action: 'me.prefs_set', session_token: t.session_token, prefs: { 'ui.page': null, 'ui.chat_mode': null } });
  await page.goto(baseURL);
  await page.locator('#liUser').fill(username);
  await page.locator('#liPass').fill(password);
  await page.locator('#liGo').click();
  await expect(page.locator('#whoami')).toContainText(username);
}


// Menu entries are hubs (Chat, Activity, Abilities, Connections, Settings);
// the pages inside one are tabs. go() walks it the way a person does.
const HUB = {
  General: ['Chat', 'General'], Rooms: ['Chat', 'Rooms'], Projects: ['Chat', 'Projects'], 'Team messages': ['Chat', 'Team messages'],
  Activity: ['Activity', 'Activity'], Schedules: ['Activity', 'Schedules'],
  'Functions & procedures': ['Abilities', 'Functions & procedures'], Memories: ['Abilities', 'Memories'],
  'Models & prices': ['Connections', 'Models & prices'], APIs: ['Connections', 'APIs'], 'MCP servers': ['Connections', 'MCP servers'],
  'Decision model': ['Connections', 'Decision model'], 'Inbound events': ['Connections', 'Inbound events'],
  'Access & appearance': ['Settings', 'Access & appearance'], 'Audit log': ['Settings', 'Audit log'], SQL: ['Settings', 'SQL console'],
};
async function go(page, label) {
  const [nav, tab] = HUB[label] || [label];
  await page.locator('#nav').getByRole('button', { name: nav, exact: true }).click();
  // The hub opens on its first tab; clicking the tab that is already open does nothing.
  const t = page.locator('#pageTabs').getByRole('tab', { name: tab, exact: true });
  if (tab && (await t.getAttribute('aria-selected')) !== 'true') await t.click();
}

test('admin reaches every primary surface directly', async ({ page }) => {
  const cspErrors=[];
  page.on('console',message=>{if(message.type()==='error'&&/inline style|style-src/i.test(message.text()))cspErrors.push(message.text())});
  await login(page, 'ui_admin', 'ui-admin-password');
  const labels = ['Home','Agents','Users','General','Rooms','Projects','Team messages','Approvals','Activity','Schedules','Functions & procedures','Memories','SQL','Models & prices','APIs','MCP servers','Decision model','Inbound events','Teams','Access & appearance','Audit log'];
  for (const label of labels) {
    await go(page, label);
    await expect(page.locator('#nav button.active')).toHaveCount(1);
    if (HUB[label]) await expect(page.locator('#pageTabs .hubtab.active')).toHaveText(HUB[label][1]);
  }
  await expect(page.locator('#nav').getByRole('button', { name: 'Canvas' })).toHaveCount(0);
  await expect(page.locator('#toCanvas')).toBeVisible();
  await go(page, 'General');
  await expect(page.locator('#generalChatThread')).toBeAttached();
  await expect(page.locator('#msgInput')).toHaveCount(0);
  await go(page, 'Access & appearance');
  await expect(page.locator('#bulkApply')).toHaveCount(0);
  expect(cspErrors).toEqual([]);
  await page.evaluate(async () => {
    const body={action:'users.create',username:'ui_regular',password:'ui-regular-password',role:'user',session_token:sessionStorage.getItem('allgres_session_token')};
    const r=await fetch('/api/v1/rpc',{method:'POST',headers:{'content-type':'application/json','x-allgres-client':'dashboard'},body:JSON.stringify(body)});
    const j=await r.json(); if(j.ok===false && !/already|duplicate key/i.test(String(j.error))) throw new Error(j.error);
  });
});

test('the top bar stays put: Canvas is only the body; language is set in Settings and theme follows', async ({ page, browser }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  // English is the default, and there is no language button in the bar.
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  await expect(page.locator('.top').getByRole('button', { name: '한' })).toHaveCount(0);
  const top = await page.locator('.top').elementHandle();
  await page.locator('#toCanvas').click();
  const cv = page.frameLocator('#canvasFrame');
  await expect(cv.locator('.agent-node').first()).toBeVisible();
  // The bar has one size and its buttons one place on every page, in both languages.
  const spots = async () => page.evaluate(() => ['#toDashboard', '#toCanvas', '#themeBtn', '#logoutBtn'].map(q => {
    const r = document.querySelector(q).getBoundingClientRect(); return [q, Math.round(r.x), Math.round(r.y), Math.round(r.width)]; }).concat([['bar', Math.round(document.querySelector('.top').getBoundingClientRect().height)]]));
  const home = await spots();
  for (const id of ['Agents', 'Chat', 'Approvals', 'Settings', 'Canvas']) {
    await page.evaluate(i => openPage(i), id);
    await expect(page.locator('#pageTitle')).not.toHaveText('');
    expect(await spots()).toEqual(home);
  }
  // Same header element before and after; the Canvas brings no header of its own.
  expect(await top.evaluate(el => el.isConnected)).toBe(true);
  await expect(cv.locator('.brand')).toHaveCount(0);
  // Korean is chosen in Settings → Language; it reaches the dashboard and the Canvas.
  await page.evaluate(() => openPage('Settings'));
  await expect(page.locator('#uiLangSel option')).toHaveCount(2);
  await page.locator('#uiLangSel').selectOption('ko');
  await expect(page.locator('#nav').getByRole('button', { name: '채팅', exact: true })).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('lang', 'ko');
  const ko = await spots();
  await page.evaluate(() => openPage('Canvas'));
  await expect(page.locator('#pageTitle')).toHaveText('캔버스');
  await expect(cv.getByRole('button', { name: '조직' })).toBeVisible();
  expect(await spots()).toEqual(ko);
  // It is remembered across a reload.
  await page.reload();
  await expect(page.locator('#nav').getByRole('button', { name: '채팅', exact: true })).toBeVisible();
  // Light theme too.
  await page.locator('#themeBtn').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(cv.locator('html')).toHaveAttribute('data-theme', 'light');
  // The choices are kept for this person in the database, not in the browser:
  // another browser that signs in as them gets Korean and the light theme, and
  // this one stores nothing.
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
  const other = await browser.newContext();
  const p2 = await other.newPage();
  await p2.goto(baseURL);
  await p2.locator('#liUser').fill('ui_admin');
  await p2.locator('#liPass').fill('ui-admin-password');
  await p2.locator('#liGo').click();
  await expect(p2.locator('html')).toHaveAttribute('lang', 'ko');
  await expect(p2.locator('#pageTitle')).toHaveText('캔버스');
  await expect(p2.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(p2.locator('#nav').getByRole('button', { name: '채팅', exact: true })).toBeVisible();
  await other.close();
  // Back to English.
  await page.evaluate(() => openPage('Settings'));
  await page.locator('#uiLangSel').selectOption('en');
  await page.locator('#toDashboard').click();
  await expect(page.locator('#nav').getByRole('button', { name: 'Chat', exact: true })).toBeVisible();
  await page.locator('#themeBtn').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
});

test('functions and procedures are made from one Create screen and land back on the list', async ({ page }) => {
  const fn = `ui_made_fn_${Date.now()}`, pc = `ui-made-pc-${Date.now()}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await go(page, 'Functions & procedures');
  await expect(page.locator('#newFunc')).toHaveCount(0);
  await page.locator('#createAbility').click();
  await expect(page.locator('#pageTitle')).toHaveText('Create');
  // Pick which one, then fill it in.
  await page.locator('#abPickFn').click();
  await page.locator('#nfName').fill(fn);
  await page.locator('#nfDesc').fill('Made on the Create screen.');
  await page.locator('#nfUrl').fill('https://example.com/status');
  await page.locator('#saveNewFunc').click();
  await expect(page.locator('#pageTitle')).toHaveText('Abilities');
  await expect(page.locator('#view')).toContainText(fn);
  // A procedure the same way; Back goes to the choice, not out.
  await page.locator('#createAbility').click();
  await page.locator('#abPickFn').click();
  await expect(page.locator('#saveNewFunc')).toBeVisible();
  await page.locator('#abBack').click();
  await page.locator('#abPickPc').click();
  await page.locator('#npcName').fill(pc);
  await page.locator('#npcContent').fill('1. Look. 2. Report.');
  await page.locator('#saveNewPc').click();
  await expect(page.locator('#pageTitle')).toHaveText('Abilities');
  await expect(page.locator('#view')).toContainText(pc);
});

// One test for the whole Canvas walk-through: the web listener allows 120
// requests a minute per address, and this suite already runs from one.
test('admin opens the canvas and builds a team', async ({ page }) => {
  const cspErrors=[];
  page.on('console',message=>{if(message.type()==='error'&&/Content Security Policy|style-src|script-src/i.test(message.text()))cspErrors.push(message.text())});
  const stamp=Date.now();
  const lead=`ui_lead_${stamp}`, worker=`ui_worker_${stamp}`, team=`UI team ${stamp}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.locator('#toCanvas').click();
  // The Canvas is the body under the dashboard's own top bar.
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator('#pageTitle')).toHaveText('Canvas');
  const cv = page.frameLocator('#canvasFrame');
  await expect(page.locator('#nav button.active')).toHaveCount(0);
  const general = cv.locator('.agent-node', { hasText: 'general' }).first();
  await expect(general).toBeVisible();
  // The seeded agents do not count as a team, so a fresh install still gets
  // the first-team guide.
  await expect(cv.getByRole('region', { name: 'Build your first team' })).toBeVisible();
  // First visit explains the board once; system agents start hidden.
  await cv.getByRole('button', { name: 'Got it' }).click();
  await expect(cv.locator('.agent-node.is-system')).toHaveCount(0);
  await general.click();
  await expect(cv.locator('.inspector')).toContainText('Takes work from');
  const fit = () => cv.getByTitle('Fit to screen').click();
  for (const name of [lead, worker]) {
    await cv.getByRole('button', { name: 'Add', exact: true }).click();
    await cv.getByRole('menuitem', { name: /New agent/ }).click();
    await cv.locator('#dlg-name').fill(name);
    await cv.getByRole('button', { name: 'Create', exact: true }).click();
    await expect(cv.locator(`.agent-node[data-agent="${name}"]`)).toBeVisible();
  }
  await cv.getByRole('button', { name: 'Close details' }).click();
  await fit();
  await page.waitForTimeout(400);
  const leadNode=cv.locator(`.react-flow__node:has(.agent-node[data-agent="${lead}"])`);
  const workerNode=cv.locator(`.react-flow__node:has(.agent-node[data-agent="${worker}"])`);
  // Dropping the worker's card on the lead's puts it under the lead: the
  // lead may now hand it work (an `agent` grant), drawn as a line.
  // React Flow moves a node on real pointer moves, so drag in steps the way
  // a hand would, not in one jump.
  const from = await workerNode.boundingBox(), to = await leadNode.boundingBox();
  await page.mouse.move(from.x + from.width / 2, from.y + 20);
  await page.mouse.down();
  await page.mouse.move(to.x + to.width / 2, to.y + 20, { steps: 12 });
  await page.mouse.up();
  await expect(cv.locator('.toast')).toContainText(`${worker} now works under ${lead}`);
  await expect(cv.locator('.react-flow__edge.edge-delegate')).not.toHaveCount(0);
  await fit();
  await page.waitForTimeout(400);
  await leadNode.click();
  await expect(cv.locator('.inspector')).toContainText('Hands work to');
  await expect(cv.locator('.inspector')).toContainText(worker);
  // Shift+click adds the worker; the selection bar makes them a team.
  await fit();
  await page.waitForTimeout(400);
  await page.keyboard.down('Shift');
  await workerNode.click();
  await page.keyboard.up('Shift');
  await cv.getByRole('button', { name: 'Make a team' }).click();
  await cv.locator('#dlg-name').fill(team);
  await cv.getByRole('button', { name: 'Create', exact: true }).click();
  await expect(cv.locator(`.group-node[data-group="${team}"]`)).toContainText('2');
  await cv.getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(cv.locator(`.group-node[data-group="${team}"]`)).toHaveCount(0);
  await cv.getByRole('button', { name: 'More' }).click();
  await cv.getByRole('menuitem', { name: 'Tidy up layout' }).click();
  await expect(cv.locator('.toast')).toContainText('Tidied up');
  await cv.getByRole('button', { name: 'More' }).click();
  await cv.locator('#showSystem').check();
  await expect(cv.locator('.agent-node.is-system').first()).toBeVisible();
  await cv.locator('#showSystem').uncheck();
  await expect(cv.locator('.agent-node.is-system')).toHaveCount(0);
  await page.locator('#toDashboard').click();
  await expect(page.locator('#canvasFrame')).toHaveCount(0);
  await expect(page.locator('#whoami')).toContainText('ui_admin');
  expect(cspErrors).toEqual([]);
});

test('admin data tables fit a narrow viewport', async ({ page }) => {
  await page.setViewportSize({width:390,height:844});
  await login(page, 'ui_admin', 'ui-admin-password');
  for(const label of ['Agents','SQL','Audit log']){
    await go(page,label);
    const width=await page.evaluate(()=>({document:document.documentElement.scrollWidth,viewport:document.documentElement.clientWidth}));
    expect(width.document).toBeLessThanOrEqual(width.viewport);
  }
});

test('first-run setup keeps unconfigured agents in drafts', async ({ page }) => {
  const draftName=`ui_draft_${Date.now()}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  // A fresh install starts at Home with the three get-started steps, in order.
  await expect(page.getByRole('heading', { name: 'Get started' })).toBeVisible();
  await expect(page.getByRole('button', { name: '1. Connect a model' })).toBeVisible();
  // The earlier canvas test already built a team here, so step 2 may show as done.
  await expect(page.getByRole('button', { name: /Build a team/ })).toBeVisible();
  await expect(page.getByRole('button', { name: '3. Give it a first job' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Waiting for you' })).toBeVisible();
  await expect(page.getByText('Nothing needs your decision.')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'In progress' })).toBeVisible();
  await expect(page.getByText('System status')).toBeVisible();
  await go(page, 'Agents');
  await expect(page.getByText('System agents (')).toBeVisible();
  await page.getByText('System agents (').click();
  await expect(page.locator('#view details').getByRole('cell', { name: 'health_monitor' })).toBeVisible();
  await expect(page.locator('#view > .panel').first().getByRole('cell', { name: 'health_monitor' })).toHaveCount(0);
  await page.locator('#newAgent').click();
  await page.locator('#aName').fill(draftName);
  await page.locator('#aProvider').selectOption('');
  await page.locator('#aDraft').uncheck();
  await page.locator('#saveA').click();
  await expect(page.locator('#toast')).toBeVisible();
  await expect(page.locator('#toast')).toContainText('provider and model');
  await page.locator('#aDraft').check();
  await page.locator('#saveA').click();
  await expect(page.locator('#view')).toContainText(draftName);
});

test('admin connects an MCP server, confirms tool risk, and registers a tool', async ({ page }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  await go(page, 'MCP servers');
  // The page draws the form, then its lists; fill again if the redraw cleared it.
  await expect(async () => {
    await page.locator('#mcName').fill('ui_mock_mcp');
    await page.locator('#mcUrl').fill(baseURL + '/mock/mcp');
    await page.locator('#mcPrivate').check();
    await expect(page.locator('#mcName')).toHaveValue('ui_mock_mcp');
  }).toPass({ timeout: 15000 });
  await page.locator('#mcGo').click();
  const server = page.locator('#view .panel', { hasText: 'ui_mock_mcp' });
  await expect(server.getByText('connected', { exact: true })).toBeVisible({ timeout: 20000 });
  const row = name => server.locator('tbody tr', { hasText: name });
  // Nothing can be registered before a person says how risky a tool is.
  await expect(row('get_status').getByRole('button', { name: 'Register' })).toBeDisabled();
  await expect(row('move_arm').getByText('Suggested: physical')).toBeVisible();
  await row('get_status').locator('select.mcpRisk').selectOption('read');
  await expect(row('get_status').getByRole('button', { name: 'Register' })).toBeEnabled();
  await row('move_arm').locator('select.mcpRisk').selectOption('physical');
  await expect(row('move_arm').getByText('Always asks a person')).toBeVisible();
  await row('get_status').getByRole('button', { name: 'Register' }).click();
  await expect(row('get_status').getByText('Give an agent the ability')).toBeVisible();
  // The registered tool shows up as a function an agent can be given.
  await go(page, 'Functions & procedures');
  await expect(page.locator('#view')).toContainText('ui_mock_mcp_get_status');
  // A server's tools do not appear on the APIs page.
  await go(page, 'APIs');
  await expect(page.locator('#view')).not.toContainText('/mock/mcp');
});

test('admin signs in to an MCP server with OAuth', async ({ page }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  await go(page, 'MCP servers');
  await page.locator('#mcName').fill('ui_mock_oauth');
  await page.locator('#mcUrl').fill(baseURL + '/mock/mcp-oauth');
  await page.locator('#mcAuth').selectOption('oauth');
  await page.locator('#mcPrivate').check();
  await page.locator('#mcGo').click();
  const server = () => page.locator('#view .panel', { hasText: 'ui_mock_oauth' });
  await expect(server().getByText('needs a login or key')).toBeVisible({ timeout: 20000 });
  await expect(server().getByText('Not signed in yet.')).toBeVisible();
  // The mock authorization server sends the browser straight back with a code.
  await server().getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Signed in' })).toBeVisible({ timeout: 30000 });
  await page.getByRole('link', { name: 'Open Allgres' }).click();
  await go(page, 'MCP servers');
  await expect(server().getByText('Signed in until')).toBeVisible({ timeout: 20000 });
  await expect(server().getByText('connected', { exact: true })).toBeVisible({ timeout: 20000 });
  await expect(server().locator('tbody tr', { hasText: 'get_status' })).toBeVisible();
  await expect(page.locator('#view')).not.toContainText('mock-access-token');
  page.once('dialog', d => d.accept());
  await server().getByRole('button', { name: 'Sign out' }).click();
  await expect(server().getByText('Not signed in yet.')).toBeVisible({ timeout: 20000 });
});

test('admin tests an API connection and accepts a reported model price', async ({ page }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  // A provider on the built-in mock, probed through the worker, and a plain
  // API connection to the mock's own address.
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const p = await call({ action: 'provider.create', name: 'ui_price_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    const probe = await call({ action: 'providers.probe_start', provider_id: p.provider_id });
    if (probe.ok === false) throw new Error(probe.error);
    const c = await call({ action: 'connections.create', name: 'ui_ping_mock', base_url: base + '/healthz', auth_kind: 'none', allow_private_network: true });
    if (c.ok === false) throw new Error(c.error);
  }, baseURL);
  await go(page, 'APIs');
  const row = page.locator('#view tbody tr', { hasText: 'ui_ping_mock' });
  await expect(row.getByText('not tested')).toBeVisible();
  await row.getByRole('button', { name: 'Test' }).click();
  await expect(row.getByText('reachable', { exact: true })).toBeVisible({ timeout: 20000 });
  await go(page, 'Models & prices');
  const block = page.locator('#unpricedBlock');
  await expect(block).toContainText('no price', { timeout: 20000 });
  const model = block.locator('tbody tr', { hasText: 'allgres-mock' }).filter({ hasText: 'ui_price_mock' }).filter({ hasNotText: 'embed' });
  await expect(model).toContainText('0.001 in / 0.002 out');
  await model.getByRole('button', { name: 'Use this price' }).click();
  const priced = page.locator('#view tbody tr', { hasText: 'ui_price_mock' }).filter({ hasText: '0.001' });
  await expect(priced.first()).toBeVisible({ timeout: 20000 });
});

test('admin connects a decision model and sees its checkpoints', async ({ page }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  await go(page, 'Decision model');
  await expect(page.getByText('No decision is handed to it')).toBeVisible();
  // Without the key the server shows only its status: that is "key needed".
  await page.locator('#dmName').fill('ui_laya_nokey');
  await page.locator('#dmUrl').fill(baseURL + '/mock/laya');
  await page.locator('#dmPrivate').check();
  await page.locator('#dmGo').click();
  const card = name => page.locator('#view .panel', { hasText: name });
  await expect(card('ui_laya_nokey').getByText('key needed')).toBeVisible({ timeout: 20000 });
  await page.locator('#dmName').fill('ui_laya');
  await page.locator('#dmUrl').fill(baseURL + '/mock/laya');
  await page.locator('#dmKey').fill('laya-mock-key');
  await page.locator('#dmPrivate').check();
  await page.locator('#dmGo').click();
  await expect(card('ui_laya').getByText('connected', { exact: true })).toBeVisible({ timeout: 20000 });
  await expect(card('ui_laya').getByRole('cell', { name: 'support-triage' })).toBeVisible();
  await expect(card('ui_laya').getByText('key stored')).toBeVisible();
  await expect(page.locator('#view')).not.toContainText('laya-mock-key');
  // It is a decision model, not an API connection or an MCP server.
  await go(page, 'APIs');
  await expect(page.locator('#view')).not.toContainText('ui_laya');
});

test('admin receives a signed inbound event and starts a task from it', async ({ page }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.evaluate(async () => {
    const r = await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ action: 'agents.create', name: 'ui_inbound_agent', system_prompt: 'Handles alerts.', session_token: sessionStorage.getItem('allgres_session_token') }) });
    const j = await r.json(); if (j.ok === false && !/already|duplicate key/i.test(String(j.error))) throw new Error(j.error);
  });
  await go(page, 'Inbound events');
  await page.locator('#inName').fill('ui-alerts');
  await page.locator('#inAgent').selectOption({ label: 'ui_inbound_agent' });
  await page.locator('#inAdd').click();
  const secret = (await page.locator('#inSecretText').innerText()).trim();
  expect(secret.length).toBeGreaterThanOrEqual(40);
  const body = JSON.stringify({ sensor: 'pump-3', temp: 91 });
  const ts = String(Math.floor(Date.now() / 1000));
  const sign = (s, t, b) => 'sha256=' + createHmac('sha256', s).update(`${t}.${b}`).digest('hex');
  const post = (sig, id) => page.request.post(baseURL + '/inbound/ui-alerts', {
    data: body, headers: { 'content-type': 'application/json', 'x-allgres-timestamp': ts, 'x-allgres-signature': sig, 'x-allgres-event-id': id } });
  expect((await post('sha256=' + '0'.repeat(64), 'e0')).status()).toBe(401);
  expect((await post(sign(secret, ts, body), 'e1')).status()).toBe(202);
  const again = await post(sign(secret, ts, body), 'e1');
  expect(again.status()).toBe(200);
  expect((await again.json()).duplicate).toBe(true);
  // It waits for a person, and shows on Home.
  await go(page, 'Home');
  await expect(page.getByText('1 inbound event')).toBeVisible({ timeout: 20000 });
  await go(page, 'Inbound events');
  const row = page.locator('#view tbody tr', { hasText: 'pump-3' });
  await expect(row.getByText('waiting')).toBeVisible();
  await row.getByRole('button', { name: 'Start a task' }).click();
  await expect(page.locator('#view tbody tr', { hasText: 'pump-3' }).getByText('task started')).toBeVisible({ timeout: 20000 });
  await expect(page.locator('#view')).not.toContainText(secret);
});

test('admin makes a room, calls an agent with a role, and a person makes a task from it', async ({ page }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  // An agent on the built-in mock model, so its answer comes back through the real worker.
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    let p = await call({ action: 'provider.create', name: 'ui_room_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false && !/already|duplicate key/i.test(String(p.error))) throw new Error(p.error);
    const a = await call({ action: 'agents.create', name: 'ui_room_agent', system_prompt: 'Answers briefly.',
      llm_config: { provider: 'ui_room_mock', model: 'allgres-mock' }, is_active: true });
    if (a.ok === false && !/already|duplicate key/i.test(String(a.error))) throw new Error(a.error);
  }, baseURL);
  await go(page, 'Rooms');
  await page.locator('#rmName').fill('ui-audit-room');
  await page.locator('#rmPurpose').fill('plan the audit');
  await page.locator('#rmCreate').click();
  await expect(page.getByRole('heading', { name: 'ui-audit-room' })).toBeVisible();
  await page.locator('#rmAgent').selectOption({ label: 'ui_room_agent' });
  await page.locator('#rmRole').selectOption({ label: 'reviewer' });
  await page.locator('#rmAddAgent').click();
  await expect(page.locator('#view').getByText('ui_room_agent')).toBeVisible();
  await expect(page.locator('#view').getByText('A role tells the agent what it is asked to do here. It gives no permission.')).toBeVisible();
  // An @mention calls the agent; its answer comes back to the room.
  await page.locator('#rmText').fill('Please review the figures @ui_room_agent');
  await page.locator('#rmSend').click();
  await expect(page.locator('#rmThread .msg', { hasText: 'Allgres mock runtime OK' })).toBeVisible({ timeout: 45000 });
  await expect(page.locator('#rmThread .msg', { hasText: 'Allgres mock runtime OK' }).getByText('agent', { exact: true })).toBeVisible();
  // A person makes a task from a message.
  await page.locator('#rmThread .msg', { hasText: 'Please review the figures' }).getByRole('button', { name: 'Make a task' }).click();
  await page.locator('#rtGo').click();
  await expect(page.locator('#rmThread .msg', { hasText: 'Task for ui_room_agent' })).toBeVisible({ timeout: 20000 });
  // A closed room takes nothing new.
  await page.locator('#rmToggle').click();
  await expect(page.locator('#rmText')).toHaveCount(0);
});

test('assisted room: agents ask each other, the lead proposes, a person confirms', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  // Three scripted agents on the built-in mock model (MOCK_SCRIPT is its test-only script line).
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const llm = { provider: 'ui_room_mock', model: 'allgres-mock' };
    let p = await call({ action: 'provider.create', name: 'ui_room_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false && !/already|duplicate key/i.test(String(p.error))) throw new Error(p.error);
    const make = async (name, script) => {
      const a = await call({ action: 'agents.create', name, system_prompt: 'MOCK_SCRIPT: ' + script, llm_config: llm, is_active: true });
      if (a.ok === false) throw new Error(a.error);
      return a.agent_id;
    };
    const lead = await make('ui_as_lead', 'Plan ready. @ui_as_rev please check the figures.\\nPROPOSE @ui_as_impl: reconcile the March ledger');
    await make('ui_as_rev', 'Checked, the figures are fine.');
    await make('ui_as_impl', 'Ledger reconciled, no difference found.');
    for (const ref of ['ui_as_rev', 'ui_as_impl']) {
      const g = await call({ action: 'permissions.grant', agent_id: lead, type: 'agent', ref });
      if (g.ok === false) throw new Error(g.error);
    }
  }, baseURL);
  await go(page, 'Rooms');
  await page.locator('#rmName').fill('ui-assisted');
  await page.locator('#rmCreate').click();
  await expect(page.getByRole('heading', { name: 'ui-assisted' })).toBeVisible();
  for (const [name, role] of [['ui_as_lead', 'lead'], ['ui_as_rev', 'reviewer'], ['ui_as_impl', 'implementer']]) {
    await page.locator('#rmAgent').selectOption({ label: name });
    await page.locator('#rmRole').selectOption({ label: role });
    await page.locator('#rmAddAgent').click();
    await expect(page.locator('#view .row', { hasText: name }).first()).toBeVisible();
  }
  await page.locator('#view .row', { hasText: 'ui_as_lead' }).getByRole('button', { name: 'Make lead' }).click();
  // Once the lead is set its row no longer offers "Make lead".
  await expect(page.locator('#view .row', { hasText: 'ui_as_lead' }).getByRole('button', { name: 'Make lead' })).toHaveCount(0);
  await expect(page.locator('#view .status', { hasText: /^lead$/ })).toHaveCount(1);
  await page.locator('#rmMode').selectOption('assisted');
  await page.locator('#rmSaveLimits').click();
  await expect(page.getByText('assisted', { exact: true }).first()).toBeVisible();
  // One message to the lead: it asks the reviewer, who answers, and it proposes a task.
  await page.locator('#rmText').fill('Kick off the audit @ui_as_lead');
  await page.locator('#rmSend').click();
  await expect(page.locator('#rmThread .msg', { hasText: 'Checked, the figures are fine.' })).toBeVisible({ timeout: 60000 });
  await expect(page.locator('#rmThread .msg', { hasText: 'Proposed task for ui_as_impl: reconcile the March ledger' })).toBeVisible();
  // The proposal waits for a person: the implementer has not been called.
  await expect(page.locator('#rmThread .msg', { hasText: 'Ledger reconciled' })).toHaveCount(0);
  const waiting = page.locator('#view .panel', { hasText: 'Waiting for you' });
  await expect(waiting).toContainText('reconcile the March ledger');
  await waiting.getByRole('button', { name: 'Confirm' }).click();
  await expect(page.locator('#rmThread .msg', { hasText: 'Ledger reconciled, no difference found.' })).toBeVisible({ timeout: 60000 });
  await expect(page.locator('#view .panel', { hasText: 'Waiting for you' })).toHaveCount(0);
  // The person's confirmation is kept as a decision record.
  const stats = await page.evaluate(async () => {
    const r = await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ action: 'decisions.stats', session_token: sessionStorage.getItem('allgres_session_token') }) });
    return r.json();
  });
  const point = stats.points.find(x => x.point_key === 'room_task_confirmation');
  expect(point).toMatchObject({ records: 1, human: 1, gold: 1 });
});

test('auto room: the lead proposes and the room starts the task by itself', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  // A priced model is what lets the room count its cost, so auto mode is allowed.
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const llm = { provider: 'ui_auto_mock', model: 'allgres-mock' };
    const p = await call({ action: 'provider.create', name: 'ui_auto_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    const pr = await call({ action: 'model_prices.set', provider_id: p.provider_id, model: 'allgres-mock', input_price_per_1k: 0.001, output_price_per_1k: 0.002 });
    if (pr.ok === false) throw new Error(pr.error);
    const make = async (name, script) => {
      const a = await call({ action: 'agents.create', name, system_prompt: 'MOCK_SCRIPT: ' + script, llm_config: llm, is_active: true });
      if (a.ok === false) throw new Error(a.error);
      return a.agent_id;
    };
    const lead = await make('ui_au_lead', 'Plan ready.\\nPROPOSE @ui_au_impl: write the quarterly summary');
    await make('ui_au_impl', 'Summary written.');
    const g = await call({ action: 'permissions.grant', agent_id: lead, type: 'agent', ref: 'ui_au_impl' });
    if (g.ok === false) throw new Error(g.error);
  }, baseURL);
  await go(page, 'Rooms');
  await page.locator('#rmName').fill('ui-auto');
  await page.locator('#rmCreate').click();
  await expect(page.getByRole('heading', { name: 'ui-auto' })).toBeVisible();
  for (const [name, role] of [['ui_au_lead', 'lead'], ['ui_au_impl', 'implementer']]) {
    await page.locator('#rmAgent').selectOption({ label: name });
    await page.locator('#rmRole').selectOption({ label: role });
    await page.locator('#rmAddAgent').click();
    await expect(page.locator('#view .row', { hasText: name }).first()).toBeVisible();
  }
  // Auto is refused until the room has a lead.
  await page.locator('#rmMode').selectOption('auto');
  await page.locator('#rmSaveLimits').click();
  await expect(page.getByText('it needs a lead').first()).toBeVisible();
  await page.locator('#view .row', { hasText: 'ui_au_lead' }).getByRole('button', { name: 'Make lead' }).click();
  await expect(page.locator('#view .row', { hasText: 'ui_au_lead' }).getByRole('button', { name: 'Make lead' })).toHaveCount(0);
  await expect(page.locator('#view .status', { hasText: /^lead$/ })).toHaveCount(1);
  await page.locator('#rmMode').selectOption('auto');
  await page.locator('#rmSaveLimits').click();
  await expect(page.locator('#view .status', { hasText: /^auto$/ })).toBeVisible();
  // One message: the lead proposes and the room starts the task without a click.
  await page.locator('#rmText').fill('Write up the quarter @ui_au_lead');
  await page.locator('#rmSend').click();
  await expect(page.locator('#rmThread .msg', { hasText: 'Started automatically. Task for ui_au_impl: write the quarterly summary' })).toBeVisible({ timeout: 60000 });
  await expect(page.locator('#rmThread .msg', { hasText: 'Summary written.' })).toBeVisible({ timeout: 60000 });
  await expect(page.locator('#view .panel', { hasText: 'Waiting for you' })).toHaveCount(0);
  // The choice is the model's: an llm record with no gold label.
  const stats = await page.evaluate(async () => {
    const r = await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ action: 'decisions.stats', session_token: sessionStorage.getItem('allgres_session_token') }) });
    return r.json();
  });
  const point = stats.points.find(x => x.point_key === 'room_task_confirmation');
  expect(point.records).toBeGreaterThanOrEqual(1);
  expect(point.gold).toBe(1);
});

test('teams: a second team, a window that waits for a person, and shared notes', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const llm = { provider: 'ui_team_mock', model: 'allgres-mock' };
    const p = await call({ action: 'provider.create', name: 'ui_team_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    for (const name of ['ui_tm_a', 'ui_tm_b']) {
      const a = await call({ action: 'agents.create', name, system_prompt: 'You help the team.', llm_config: llm, is_active: true });
      if (a.ok === false) throw new Error(a.error);
    }
    for (const name of ['ui-team-one', 'ui-team-two']) {
      const g = await call({ action: 'canvas.groups.create', name });
      if (g.ok === false) throw new Error(JSON.stringify(g));
    }
  }, baseURL);
  const team = (name) => page.locator('#view .panel[data-team="' + name + '"]');
  await go(page, 'Teams');
  await expect(team('ui-team-one')).toBeVisible();
  // ui_tm_a sits in team one first, then also in team two.
  await page.evaluate(async () => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const ags = (await call({ action: 'agents.list' })).agents;
    const gs = (await call({ action: 'teams.list' })).teams;
    const id = n => ags.find(a => a.name === n).agent_id;
    const gid = n => gs.find(g => g.name === n).group_id;
    for (const n of ['ui_tm_a', 'ui_tm_b']) {
      const r = await call({ action: 'canvas.groups.set_member', agent_id: id(n), group_id: gid('ui-team-one') });
      if (r.ok === false) throw new Error(JSON.stringify(r));
    }
  });
  await go(page, 'Home');
  await go(page, 'Teams');
  await expect(team('ui-team-one')).toContainText('ui_tm_a');
  // The page can re-render under the click; adding twice is harmless, so retry the pair.
  await expect(async () => {
    await team('ui-team-two').locator('.tmSecAgent').selectOption({ label: 'ui_tm_a' });
    await team('ui-team-two').getByRole('button', { name: 'Also in this team' }).click();
    await expect(team('ui-team-two').locator('.status', { hasText: 'second team' })).toBeVisible({ timeout: 4000 });
  }).toPass({ timeout: 40000 });
  // The window waits for a person; hand work to it, then pick who takes it.
  await team('ui-team-two').locator('.tmMode').selectOption('person');
  await team('ui-team-two').getByRole('button', { name: 'Save window' }).click();
  await team('ui-team-two').locator('.tmGoal').fill('Summarize the ticket backlog');
  await team('ui-team-two').getByRole('button', { name: 'Hand over' }).click();
  const waiting = page.locator('#view .panel', { hasText: 'Waiting for you' });
  await expect(waiting).toContainText('Summarize the ticket backlog');
  await waiting.getByRole('button', { name: 'Give it to them' }).click();
  await expect(page.locator('#view .panel', { hasText: 'Handed over' }).getByText('Summarize the ticket backlog')).toBeVisible();
  await expect(page.locator('#view .panel', { hasText: 'Handed over' }).locator('.status', { hasText: /finished|completed|queued|running|working/ }).first()).toBeVisible({ timeout: 60000 });
  // A shared note for the team.
  await page.locator('#tnScope').selectOption('team');
  await page.locator('#tnTeam').selectOption({ label: 'ui-team-two' });
  await page.locator('#tnText').fill('Team two closes the month on the 3rd.');
  await page.locator('#tnAdd').click();
  await expect(page.getByText('Team two closes the month on the 3rd.')).toBeVisible();
  // The person's pick is kept as a gold decision.
  const stats = await page.evaluate(async () => {
    const r = await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ action: 'decisions.stats', session_token: sessionStorage.getItem('allgres_session_token') }) });
    return r.json();
  });
  expect(stats.points.some(x => x.point_key.startsWith('team_assign_') && x.gold >= 1)).toBe(true);
  // The Canvas shows the second team on that team's box and in its inspector.
  await page.goto(baseURL + '/canvas');
  const box = page.locator('.group-node', { hasText: 'ui-team-two' });
  await expect(box.locator('.gn-also')).toContainText('ui_tm_a');
  await box.locator('.gn-head').click();
  await expect(page.locator('.inspector')).toContainText('Also in this team');
  await expect(page.locator('.inspector')).toContainText('ui_tm_a');
});

test('an agent proposes a function, the person sees the check, approves, and gives it to an agent', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  const names = await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const llm = { provider: 'ui_cr_mock', model: 'allgres-mock' };
    const p = await call({ action: 'provider.create', name: 'ui_cr_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    const action = JSON.stringify({ action: 'create_function', name: 'ui_cr_echo', description: 'Echoes what it is given.',
      body: "BEGIN RETURN jsonb_build_object('echo', p_args); END;", reason: 'A small echo for tests.' });
    const maker = await call({ action: 'agents.create', name: 'ui_cr_maker', system_prompt: 'MOCK_ACTION: ' + action, llm_config: llm, is_active: true });
    if (maker.ok === false) throw new Error(maker.error);
    const user = await call({ action: 'agents.create', name: 'ui_cr_user', system_prompt: 'Uses the echo.', llm_config: llm, is_active: true });
    if (user.ok === false) throw new Error(user.error);
    const run = await call({ action: 'run', agent_id: maker.agent_id, goal: 'Make an echo function' });
    if (run.ok === false) throw new Error(run.error);
    return true;
  }, baseURL);
  expect(names).toBe(true);
  await go(page, 'Approvals');
  const card = page.locator('#view .listrow', { hasText: 'ui_cr_echo' }).first();
  // The agent proposes when its run reaches the worker; reopen the tab until it shows.
  await expect(async () => {
    await page.locator('.apTabBtn', { hasText: 'Proposals' }).click();
    await expect(card).toBeVisible({ timeout: 3000 });
  }).toPass({ timeout: 60000 });
  await expect(card).toContainText('Check before you decide');
  await expect(card).toContainText('compiles');
  await expect(card).toContainText('not run');
  await card.getByRole('button', { name: /approve/i }).click();
  const done = page.locator('#view .listrow', { hasText: 'ui_cr_echo' }).filter({ hasText: 'Give it to' });
  await expect(done).toBeVisible({ timeout: 20000 });
  await done.locator('label', { hasText: 'ui_cr_user' }).locator('input').check();
  await done.getByRole('button', { name: 'Give', exact: true }).click();
  await expect(page.locator('#view .listrow', { hasText: 'ui_cr_echo' }).filter({ hasText: 'already: ui_cr_user' })).toBeVisible();
});

test('decision model: watch a point, compare with a person, and meet the gate before handing over', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const p = await call({ action: 'provider.create', name: 'ui_dg_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    const action = JSON.stringify({ action: 'await_human', reason: 'OK to go ahead with the delivery?' });
    const a = await call({ action: 'agents.create', name: 'ui_dg_agent', system_prompt: 'MOCK_ACTION: ' + action,
      llm_config: { provider: 'ui_dg_mock', model: 'allgres-mock' }, is_active: true });
    if (a.ok === false) throw new Error(a.error);
    const m = await call({ action: 'decision_models.connect', name: 'ui-dg-laya', base_url: base + '/mock/laya', allow_private_network: true });
    if (m.ok === false) throw new Error(m.error);
    const run = await call({ action: 'run', agent_id: a.agent_id, goal: 'Deliver the order' });
    if (run.ok === false) throw new Error(run.error);
  }, baseURL);
  // Watch the approval point.
  await go(page, 'Decision model');
  const row = page.locator('#view .listrow[data-point="approval_decision"]');
  await expect(row).toBeVisible();
  await row.locator('.dgModel').selectOption({ label: 'ui-dg-laya' });
  await row.getByRole('button', { name: 'Watch' }).click();
  await expect(page.locator('#view .listrow[data-point="approval_decision"] .status', { hasText: 'watching' })).toBeVisible();
  // A person approves the agent's question; the model is asked afterwards and compared.
  await go(page, 'Approvals');
  await expect(async () => {
    await page.locator('.apTabBtn', { hasText: 'Approvals' }).click();
    await expect(page.locator('#view .listrow', { hasText: 'OK to go ahead with the delivery?' }).first()).toBeVisible({ timeout: 3000 });
  }).toPass({ timeout: 60000 });
  await page.locator('#view .listrow', { hasText: 'OK to go ahead with the delivery?' }).first().locator('.apAccept').click();
  await go(page, 'Decision model');
  await expect(async () => {
    await page.evaluate(() => loadPage());
    await expect(page.locator('#view .listrow[data-point="approval_decision"]')).toContainText('Compared 1 decisions: the model agreed on 1', { timeout: 3000 });
  }).toPass({ timeout: 60000 });
  // Handing over is refused until enough has been watched.
  const handOver = page.locator('#view .listrow[data-point="approval_decision"]').getByRole('button', { name: 'Hand over' });
  await expect(handOver).toBeDisabled();
  await expect(page.locator('#view .listrow[data-point="approval_decision"]')).toContainText('Hand over unlocks after at least 10 compared decisions');
  // The way back.
  await page.getByRole('button', { name: 'Turn everything off' }).click();
  await expect(page.locator('#view .listrow[data-point="approval_decision"] .status', { hasText: /^off$/ })).toBeVisible();
  // The scripted agent asks again after every answer; leave nothing waiting for later tests.
  await page.evaluate(async () => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const ag = (await call({ action: 'agents.list' })).agents.find(x => x.name === 'ui_dg_agent');
    await call({ action: 'agents.update', agent_id: ag.agent_id, is_active: false }).catch(() => {});
    const list = (await call({ action: 'approvals.list', limit: 200 })).approvals || [];
    for (const ap of list.filter(x => x.agent === 'ui_dg_agent')) await call({ action: 'approvals.decide', approval_id: ap.approval_id, accept: false });
  });
});

test('teams are made, renamed and deleted from the dashboard', async ({ page }) => {
  test.setTimeout(90000);
  await login(page, 'ui_admin', 'ui-admin-password');
  page.on('dialog', d => d.accept());
  await go(page, 'Teams');
  await page.locator('#tnewName').fill('ui-made-team');
  await page.locator('#tnewGo').click();
  const box = page.locator('#view .panel[data-team="ui-made-team"]');
  await expect(box).toBeVisible();
  await box.locator('summary', { hasText: 'Rename' }).click();
  await box.locator('.tmName').fill('ui-renamed-team');
  await box.locator('.tmKind').selectOption('division');
  await box.getByRole('button', { name: 'Save', exact: true }).click();
  const renamed = page.locator('#view .panel[data-team="ui-renamed-team"]');
  await expect(renamed).toBeVisible();
  await expect(renamed).toContainText('division');
  await renamed.locator('summary', { hasText: 'Rename' }).click();
  await renamed.getByRole('button', { name: 'Delete team' }).click();
  await expect(page.locator('#view .panel[data-team="ui-renamed-team"]')).toHaveCount(0);
});

test('General chat shows only the answer and can start a new chat', async ({ page }) => {
  test.setTimeout(90000);
  await login(page, 'ui_admin', 'ui-admin-password');
  page.on('dialog', d => d.accept());
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const p = await call({ action: 'provider.create', name: 'ui_chat_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    const ags = (await call({ action: 'agents.list' })).agents;
    const g = ags.find(a => a.name === 'general');
    const r = await call({ action: 'agents.update', agent_id: g.agent_id, llm_config: { provider: 'ui_chat_mock', model: 'allgres-mock' }, is_active: true });
    if (r.ok === false) throw new Error(JSON.stringify(r));
  }, baseURL);
  await go(page, 'General');
  await page.locator('#generalChatInput').fill('hello there');
  await page.locator('#generalChatSend').click();
  const reply = page.locator('#generalChatThread', { hasText: 'Allgres mock runtime OK' });
  await expect(reply).toBeVisible({ timeout: 60000 });
  await expect(page.locator('#generalChatThread')).not.toContainText('"action"');
  await page.locator('#generalChatNew').click();
  await expect(page.locator('#generalChatThread')).toContainText('Say hello to General.');
  await expect(page.locator('#generalChatThread')).not.toContainText('hello there');
});

test('one model is put on chosen agents at once, and can be the default for new agents', async ({ page }) => {
  test.setTimeout(90000);
  await login(page, 'ui_admin', 'ui-admin-password');
  page.on('dialog', d => d.accept());
  await page.evaluate(async (base) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const p = await call({ action: 'provider.create', name: 'ui_ma_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    for (const name of ['ui_ma_a', 'ui_ma_b', 'ui_ma_c']) {
      const a = await call({ action: 'agents.create', name, system_prompt: 'x', is_active: false });
      if (a.ok === false) throw new Error(a.error);
    }
  }, baseURL);
  const targets = () => page.evaluate(async () => (await (await fetch('/api/v1/rpc', { method: 'POST',
    headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
    body: JSON.stringify({ action: 'models.targets', session_token: sessionStorage.getItem('allgres_session_token') }) })).json()));
  await go(page, 'Models & prices');
  // Each provider folds open to its models; add one by name, then put it on chosen agents.
  const prov = page.locator('details.mrProv[data-prov="ui_ma_mock"]');
  await expect(prov).toBeVisible();
  if ((await prov.getAttribute('open')) === null) await prov.locator('summary').click();
  await prov.locator('.mrAddName').fill('ma-model-1');
  await prov.locator('.mrAdd').click();
  const mrow = prov.locator('tr[data-model="ma-model-1"]');
  await expect(mrow).toBeVisible();
  await mrow.locator('.mrUse').click();
  for (const n of ['ui_ma_a', 'ui_ma_b']) await page.locator('#modal label', { hasText: n }).locator('input.maAgent').check();
  await expect(page.locator('#maSummary')).toContainText('Will change 2 agents');
  await page.locator('#maDefault').check();
  await page.locator('#maApply').click();
  await expect(page.locator('#maBody')).toContainText('New agents start with');
  let t = (await targets());
  const model = n => t.agents.find(a => a.name === n)?.model || '';
  expect(model('ui_ma_a')).toBe('ma-model-1');
  expect(model('ui_ma_b')).toBe('ma-model-1');
  expect(model('ui_ma_c')).toBe('');
  // The default reaches an agent made afterwards, not the ones that exist.
  await page.evaluate(async () => (await fetch('/api/v1/rpc', { method: 'POST',
    headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
    body: JSON.stringify({ action: 'agents.create', name: 'ui_ma_d', system_prompt: 'x', is_active: false, session_token: sessionStorage.getItem('allgres_session_token') }) })).json());
  t = await targets();
  expect(t.agents.find(a => a.name === 'ui_ma_d').model).toBe('ma-model-1');
  expect(model('ui_ma_c')).toBe('');
  // Put things back so later tests start clean.
  await page.getByRole('button', { name: 'Stop doing that' }).click();
  await expect(page.locator('#maBody')).toContainText('No default for new agents');
  // A model that is switched off cannot be put on agents, and a model in use cannot be removed.
  await prov.locator('tr[data-model="ma-model-1"] .mrOn').uncheck();
  await expect(prov.locator('tr[data-model="ma-model-1"] .mrUse')).toBeDisabled();
  await prov.locator('tr[data-model="ma-model-1"] .mrOn').check();
  // The list redraws after each change; wait for it before the next click.
  await expect(prov.locator('tr[data-model="ma-model-1"] .mrUse')).toBeEnabled();
  await prov.locator('tr[data-model="ma-model-1"] .mrRemove').click();
  await expect(page.locator('#toast')).toContainText('still in use');
  // A model nobody uses can be priced and removed.
  await prov.locator('.mrAddName').fill('ma-spare');
  await prov.locator('.mrAdd').click();
  const spare = prov.locator('tr[data-model="ma-spare"]');
  await expect(spare).toBeVisible();
  await spare.locator('.mrPrice').click();
  await page.locator('#mrIn').fill('0.001');
  await page.locator('#mrOut').fill('0.002');
  await page.locator('#mrSavePrice').click();
  await expect(spare).toContainText('$0.001');
  await expect(page.locator('#modal')).toHaveClass(/hidden/);
  await expect(spare).toContainText('$0.001');
  await spare.locator('.mrRemove').click();
  await expect(prov.locator('tr[data-model="ma-spare"]')).toHaveCount(0);
});

test('an agent is held to the models ticked for it, and the list warns when its model is not among them', async ({ page }) => {
  test.setTimeout(90000);
  const name = `ui_am_agent_${Date.now()}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.evaluate(async ([base, name]) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const p = await call({ action: 'provider.create', name: 'ui_am_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    await call({ action: 'models.registry_add', provider: 'ui_am_mock', models: ['allgres-mock', 'am-other'] });
    const a = await call({ action: 'agents.create', name, system_prompt: 'x', llm_config: { provider: 'ui_am_mock', model: 'allgres-mock' }, is_active: true });
    if (a.ok === false) throw new Error(a.error);
  }, [baseURL, name]);
  await go(page, 'Agents');
  const row = () => page.locator('#view tr', { hasText: name }).first();
  await expect(row()).toBeVisible();
  await expect(row().locator('.agentModelIssue')).toHaveCount(0);
  // Tick only the other model: this agent's own model is no longer among them.
  await row().locator('.editAgent').click();
  await page.locator('#amBox summary').click();
  await page.locator('.amModel[data-prov="ui_am_mock"][data-model="am-other"]').check();
  await page.locator('#saveA').click();
  await expect(row().locator('.agentModelIssue')).toContainText('not among the models this agent may use');
  await row().locator('.editAgent').click();
  await expect(page.locator('#aModelIssue')).toContainText('cannot run');
  // Tick its own model too: the warning goes.
  await page.locator('.amModel[data-prov="ui_am_mock"][data-model="allgres-mock"]').check();
  await page.locator('#saveA').click();
  await expect(row().locator('.agentModelIssue')).toHaveCount(0);
  // Switching the model off in Models & prices warns too.
  await page.evaluate(async () => (await fetch('/api/v1/rpc', { method: 'POST',
    headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
    body: JSON.stringify({ action: 'models.registry_set', provider: 'ui_am_mock', model: 'allgres-mock', enabled: false, session_token: sessionStorage.getItem('allgres_session_token') }) })).json());
  await go(page, 'Home');
  await go(page, 'Agents');
  await expect(row().locator('.agentModelIssue')).toContainText('switched off');
});

test('reasoning and sampling are set on an agent and as a model default, and a Claude provider shows only what it receives', async ({ page }) => {
  test.setTimeout(90000);
  const name = `ui_inf_agent_${Date.now()}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  const cfg = () => page.evaluate(async (name) => {
    const r = await (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ action: 'agents.list', session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    return (r.agents || r.rows || r).find(a => a.name === name)?.llm_config;
  }, name);
  await page.evaluate(async ([base, name]) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const p = await call({ action: 'provider.create', name: 'ui_inf_mock', kind: 'openai_compat', base_url: base + '/mock', allow_private_network: true });
    if (p.ok === false) throw new Error(p.error);
    await call({ action: 'models.registry_add', provider: 'ui_inf_mock', models: ['allgres-mock'] });
    const c = await call({ action: 'provider.create', name: 'ui_inf_claude', kind: 'anthropic', base_url: 'https://api.anthropic.com', api_key: 'sk-ant-x' });
    const a = await call({ action: 'agents.create', name, system_prompt: 'x', llm_config: { provider: 'ui_inf_mock', model: 'allgres-mock' }, is_active: true });
    if (a.ok === false) throw new Error(a.error);
  }, [baseURL, name]);
  await go(page, 'Agents');
  const row = () => page.locator('#view tr', { hasText: name }).first();
  await row().locator('.editAgent').click();
  await page.locator('#rpBox summary').click();
  // An OpenAI-compatible provider: sampling is open, Claude's thinking is not used.
  await expect(page.locator('#apTemp')).toBeEnabled();
  await expect(page.locator('#apThink')).toBeDisabled();
  await page.locator('#apEffort').selectOption('high');
  await page.locator('#apTemp').fill('0.3');
  await page.locator('#apMax').fill('2048');
  await page.locator('#apStop').fill('END\nSTOP');
  await page.locator('#saveA').click();
  await expect(page.locator('#modal')).toHaveClass(/hidden/);
  await expect.poll(async () => JSON.stringify(await cfg())).toContain('"effort":"high"');
  const saved = await cfg();
  expect(saved.temperature).toBe(0.3);
  expect(saved.max_tokens).toBe(2048);
  expect(saved.stop).toEqual(['END', 'STOP']);
  // A model's own defaults are saved from Models & prices.
  await go(page, 'Models & prices');
  const prov = page.locator('details', { hasText: 'ui_inf_mock' }).first();
  const mrow = prov.locator('tr[data-model="allgres-mock"]');
  if (!(await mrow.isVisible())) await prov.locator('summary').first().click();
  await mrow.locator('.mrParams').click();
  await page.locator('#mpTopP').fill('0.9');
  await page.locator('#mrSaveParams').click();
  await expect(page.locator('#modal')).toHaveClass(/hidden/);
  const reg = await page.evaluate(async () => (await (await fetch('/api/v1/rpc', { method: 'POST',
    headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
    body: JSON.stringify({ action: 'models.registry', session_token: sessionStorage.getItem('allgres_session_token') }) })).json()));
  expect(JSON.stringify(reg)).toContain('"top_p":0.9');
});

test('an agent is copied with its setup', async ({ page }) => {
  const src = `ui_copy_src_${Date.now()}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.evaluate(async (name) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const c = await call({ action: 'agents.create', name, system_prompt: 'copy me exactly', is_active: false });
    if (c.ok === false) throw new Error(c.error);
    await call({ action: 'permissions.grant', agent_id: c.agent_id, type: 'http_host', ref: 'example.com' });
  }, src);
  await go(page, 'Agents');
  await page.locator('#view tr', { hasText: src }).first().locator('.editAgent').click();
  await expect(page.locator('#cloneAgent')).toBeVisible();
  await page.locator('#cloneAgent').click();
  await expect(page.locator('#view')).toContainText(`${src}_copy`);
  await page.locator('#view tr', { hasText: `${src}_copy` }).first().locator('.editAgent').click();
  await expect(page.locator('#aPrompt')).toHaveValue('copy me exactly');
  await expect(page.locator('#permList')).toContainText('example.com');
  await page.locator('#closeM').click();
  // The Agents list is the only place that hides system agents' copy button.
  await page.locator('#view details summary', { hasText: 'System agents' }).click();
  await page.locator('#view details tr', { hasText: 'health_monitor' }).first().locator('.editAgent').click();
  await expect(page.locator('#cloneAgent')).toHaveCount(0);
});

test('a provider is tested before it is saved, and a 200 with an error body is not "connected"', async ({ page }) => {
  const name = `ui_lms_${Date.now()}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await go(page, 'Models & prices');
  await page.getByRole('button', { name: 'Add provider' }).click();
  await page.locator('#npName').fill(name);
  await page.locator('#npUrl').fill(baseURL + '/mockbad');
  await page.locator('#npPrivate').check();
  await page.locator('#npTestModel').fill('allgres-mock');
  await page.locator('#testNew').click();
  // The server answers 200 with {"error": "Unexpected endpoint…"}: not a model list.
  await expect(page.locator('#npProbeOut')).toContainText('not with a model list', { timeout: 20000 });
  await expect(page.locator('#npProbeOut')).toContainText('Unexpected endpoint');
  await expect(page.locator('#npProbeOut')).toContainText('/v1');
  // Nothing is saved by testing.
  await expect(page.locator('#view')).not.toContainText(name);
  // One click adds /v1 and tests again, this time through to a chat reply.
  await page.locator('#probeFixV1').click();
  await expect(page.locator('#npUrl')).toHaveValue(baseURL + '/mockbad/v1');
  await expect(page.locator('#npProbeOut')).toContainText('Chat works', { timeout: 30000 });
  await expect(page.locator('#npProbeOut')).toContainText('lists');
  await page.locator('#saveNewP').click();
  await expect(page.locator('#view')).toContainText(name);
  // A person tries the model they chose in General without sending a chat.
  await go(page, 'General');
  await page.locator('#cmProvider').selectOption({ label: `${name} (openai_compat)` });
  await page.locator('#cmModel').fill('allgres-mock');
  await page.locator('#cmTest').click();
  await expect(page.locator('#cmTestOut')).toContainText('The model answered', { timeout: 30000 });
  await page.locator('#cmModel').fill('allgres-mock');
  await expect(page.locator('#generalChatThread')).not.toContainText('Unexpected endpoint');
});

test('regular user sees only scoped chat and personal settings', async ({ page }) => {
  await login(page, 'ui_regular', 'ui-regular-password');
  await expect(page.locator('#nav button')).toHaveCount(3);
  await expect(page.locator('#toCanvas')).toBeHidden();
  for (const label of ['General','Rooms','Projects','Approvals']) {
    await go(page, label);
    await expect(page.locator('#nav button.active')).toHaveCount(1);
  }
  await page.locator('#nav').getByRole('button', { name: 'My agents' }).click();
  await expect(page.locator('#nav button.active')).toHaveText('My agents');
  // A person who is in no room sees none, and cannot make one.
  await go(page, 'Rooms');
  await expect(page.getByText('An admin adds you to a room.')).toBeVisible();
  await expect(page.locator('#view')).not.toContainText('ui-audit-room');
  await expect(page.locator('#rmCreate')).toHaveCount(0);
  await go(page, 'General');
  await expect(page.locator('#generalChatThread')).toBeAttached();
  await expect(page.getByText('not assigned to your account')).toHaveCount(0);
  for (const forbidden of ['Home','Canvas','SQL','Agents','Users','Memories','Audit log','Connections'])
    await expect(page.locator('#nav').getByRole('button',{name:forbidden,exact:true})).toHaveCount(0);
  await page.goto(baseURL + '/canvas');
  await expect(page.getByText('Admins only')).toBeVisible();
});

test('admin sets up approval routing and sees the decision records', async ({ page }) => {
  page.on('dialog', d => d.accept());
  const stamp = Date.now(), role = `UI approver ${stamp}`, unit = `UI unit ${stamp}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await go(page, 'Approvals');
  // Mine / All toggle on the approvals list, and the admin Decisions tab.
  await expect(page.getByRole('button', { name: 'Mine', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Mine', exact: true }).click();
  await expect(page.getByText('Nothing is waiting on you')).toBeVisible();
  await go(page, 'Users');
  await expect(page.getByRole('heading', { name: 'Rules' })).toBeVisible();
  // A role, a unit, a person who holds the role, and a rule that names it.
  await page.locator('#roName').fill(role);
  await page.locator('#roAdd').click();
  // Assert on the table, not the panel: a panel also holds the forms, whose
  // selects list the same names before the page has redrawn.
  const panel = name => page.locator('.panel', { has: page.getByRole('heading', { name, exact: true }) });
  await expect(panel('Roles').locator('table')).toContainText(role);
  await page.locator('#unName').fill(unit);
  await page.locator('#unAdd').click();
  await expect(panel('Units').locator('table')).toContainText(unit);
  await page.locator('#meUser').selectOption({ label: 'ui_regular' });
  await page.locator('#meRole').selectOption({ label: role });
  await page.locator('#meUnit').selectOption({ label: unit });
  await page.locator('#meAdd').click();
  const people = panel('People').locator('table');
  await expect(people).toContainText('ui_regular');
  await expect(people).toContainText(unit);
  await page.locator('#ruApplies').selectOption('approval');
  await page.locator('#ruKind').fill('execution');
  await page.locator('#ruRole').selectOption({ label: role });
  await page.locator('#ruUnit').selectOption({ label: unit });
  await page.locator('#ruAdd').click();
  const rules = panel('Rules').locator('table');
  await expect(rules).toContainText('kind execution');
  await expect(rules).toContainText(role);
  // Escalation needs both halves.
  await page.locator('#ruEscHours').fill('2');
  await page.locator('#ruRole').selectOption({ label: role });
  await page.locator('#ruAdd').click();
  await expect(page.locator('#toast')).toContainText('Escalation needs both a time and a role');
  await expect(rules).toContainText(role);
  // Decision records: the two decision points, empty so far.
  await go(page, 'Approvals');
  await page.getByRole('button', { name: 'Decisions', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'approval_decision' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'proposal_decision' })).toBeVisible();
  await expect(page.getByText('Recorded fields:').first()).toContainText('reason');
  await page.getByRole('button', { name: 'Export training set' }).first().click();
  await expect(page.locator('#toast')).toContainText(/Nothing to export|Exported/);
  // Clean up: deleting the role takes its rule and membership with it.
  await go(page, 'Users');
  await panel('Roles').locator('tr', { hasText: role }).getByRole('button', { name: 'Delete' }).click();
  await expect(panel('Roles').locator('table')).not.toContainText(role);
  await expect(panel('Rules').locator('table')).not.toContainText('kind execution');
  await panel('Units').locator('tr', { hasText: unit }).getByRole('button', { name: 'Delete' }).click();
  await expect(panel('Units').locator('table')).not.toContainText(unit);
  // A regular user gets the toggle but not the admin tabs.
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.locator('#liGo')).toBeVisible();
  await page.locator('#liUser').fill('ui_regular');
  await page.locator('#liPass').fill('ui-regular-password');
  await page.locator('#liGo').click();
  await expect(page.locator('#whoami')).toContainText('ui_regular');
  await go(page, 'Approvals');
  await expect(page.getByRole('button', { name: 'Mine', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Decisions', exact: true })).toHaveCount(0);
  await expect(page.locator('#nav').getByRole('button', { name: 'Users', exact: true })).toHaveCount(0);
});

test('mobile navigation remains keyboard reachable', async ({ page }) => {
  await page.setViewportSize({width:390,height:844});
  await login(page, 'ui_regular', 'ui-regular-password');
  await page.locator('#nav button').first().focus();
  for (let i=0;i<3;i++) {
    await expect(page.locator('#nav button').nth(i)).toBeVisible();
    await page.locator('#nav button').nth(i).press('Enter');
  }
  const width = await page.evaluate(() => ({
    document: document.documentElement.scrollWidth,
    viewport: document.documentElement.clientWidth,
  }));
  expect(width.document).toBeLessThanOrEqual(width.viewport);
});
