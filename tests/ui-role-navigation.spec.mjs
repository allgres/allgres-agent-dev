import { test, expect } from '@playwright/test';
import { createHmac } from 'node:crypto';

const baseURL = process.env.ALLGRES_UI_URL || 'http://127.0.0.1:8088';
test.describe.configure({ mode: 'serial' });

async function login(page, username, password) {
  await page.goto(baseURL);
  await page.locator('#liUser').fill(username);
  await page.locator('#liPass').fill(password);
  await page.locator('#liGo').click();
  await expect(page.locator('#whoami')).toContainText(username);
}

test('admin reaches every primary surface directly', async ({ page }) => {
  const cspErrors=[];
  page.on('console',message=>{if(message.type()==='error'&&/inline style|style-src/i.test(message.text()))cspErrors.push(message.text())});
  await login(page, 'ui_admin', 'ui-admin-password');
  const labels = ['Home','Agents','People','General','Projects','Approvals','Activity','Schedules','Functions & procedures','Memories','SQL','Models & prices','APIs','MCP servers','Decision model','Inbound events','Access & appearance','Audit log'];
  for (const label of labels) {
    const button = page.locator('#nav button', { hasText: label }).first();
    await expect(button).toBeVisible();
    await button.click();
    await expect(button).toHaveClass(/active/);
  }
  await page.locator('#nav button', { hasText: 'General' }).click();
  await expect(page.locator('#generalChatThread')).toBeVisible();
  await expect(page.locator('#msgInput')).toHaveCount(0);
  await page.locator('#nav button', { hasText: 'Access & appearance' }).click();
  await expect(page.locator('#bulkApply')).toHaveCount(0);
  expect(cspErrors).toEqual([]);
  await page.evaluate(async () => {
    const body={action:'users.create',username:'ui_regular',password:'ui-regular-password',role:'user',session_token:sessionStorage.getItem('allgres_session_token')};
    const r=await fetch('/api/v1/rpc',{method:'POST',headers:{'content-type':'application/json','x-allgres-client':'dashboard'},body:JSON.stringify(body)});
    const j=await r.json(); if(j.ok===false && !/already|duplicate key/i.test(String(j.error))) throw new Error(j.error);
  });
});

// One test for the whole Canvas walk-through: the web listener allows 120
// requests a minute per address, and this suite already runs from one.
test('admin opens the canvas and builds a team', async ({ page }) => {
  const cspErrors=[];
  page.on('console',message=>{if(message.type()==='error'&&/Content Security Policy|style-src|script-src/i.test(message.text()))cspErrors.push(message.text())});
  const stamp=Date.now();
  const lead=`ui_lead_${stamp}`, worker=`ui_worker_${stamp}`, team=`UI team ${stamp}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.locator('#nav button', { hasText: 'Canvas' }).click();
  await expect(page).toHaveURL(/\/canvas$/);
  const general = page.locator('.agent-node', { hasText: 'general' }).first();
  await expect(general).toBeVisible();
  // The seeded agents do not count as a team, so a fresh install still gets
  // the first-team guide.
  await expect(page.getByRole('region', { name: 'Build your first team' })).toBeVisible();
  // First visit explains the board once; system agents start hidden.
  await page.getByRole('button', { name: 'Got it' }).click();
  await expect(page.locator('.agent-node.is-system')).toHaveCount(0);
  await general.click();
  await expect(page.locator('.inspector')).toContainText('Takes work from');
  const fit = () => page.getByTitle('Fit to screen').click();
  for (const name of [lead, worker]) {
    await page.getByRole('button', { name: 'Add', exact: true }).click();
    await page.getByRole('menuitem', { name: /New agent/ }).click();
    await page.locator('#dlg-name').fill(name);
    await page.getByRole('button', { name: 'Create', exact: true }).click();
    await expect(page.locator(`.agent-node[data-agent="${name}"]`)).toBeVisible();
  }
  await page.getByRole('button', { name: 'Close details' }).click();
  await fit();
  await page.waitForTimeout(400);
  const leadNode=page.locator(`.react-flow__node:has(.agent-node[data-agent="${lead}"])`);
  const workerNode=page.locator(`.react-flow__node:has(.agent-node[data-agent="${worker}"])`);
  // Dropping the worker's card on the lead's puts it under the lead: the
  // lead may now hand it work (an `agent` grant), drawn as a line.
  // React Flow moves a node on real pointer moves, so drag in steps the way
  // a hand would, not in one jump.
  const from = await workerNode.boundingBox(), to = await leadNode.boundingBox();
  await page.mouse.move(from.x + from.width / 2, from.y + 20);
  await page.mouse.down();
  await page.mouse.move(to.x + to.width / 2, to.y + 20, { steps: 12 });
  await page.mouse.up();
  await expect(page.locator('.toast')).toContainText(`${worker} now works under ${lead}`);
  await expect(page.locator('.react-flow__edge.edge-delegate')).not.toHaveCount(0);
  await fit();
  await page.waitForTimeout(400);
  await leadNode.click();
  await expect(page.locator('.inspector')).toContainText('Hands work to');
  await expect(page.locator('.inspector')).toContainText(worker);
  // Shift+click adds the worker; the selection bar makes them a team.
  await fit();
  await page.waitForTimeout(400);
  await page.keyboard.down('Shift');
  await workerNode.click();
  await page.keyboard.up('Shift');
  await page.getByRole('button', { name: 'Make a team' }).click();
  await page.locator('#dlg-name').fill(team);
  await page.getByRole('button', { name: 'Create', exact: true }).click();
  await expect(page.locator(`.group-node[data-group="${team}"]`)).toContainText('2');
  await page.getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(page.locator(`.group-node[data-group="${team}"]`)).toHaveCount(0);
  await page.getByRole('button', { name: 'More' }).click();
  await page.getByRole('menuitem', { name: 'Tidy up layout' }).click();
  await expect(page.locator('.toast')).toContainText('Tidied up');
  await page.getByRole('button', { name: 'More' }).click();
  await page.locator('#showSystem').check();
  await expect(page.locator('.agent-node.is-system').first()).toBeVisible();
  await page.locator('#showSystem').uncheck();
  await expect(page.locator('.agent-node.is-system')).toHaveCount(0);
  await page.getByRole('link', { name: '← Dashboard' }).click();
  await expect(page.locator('#whoami')).toContainText('ui_admin');
  expect(cspErrors).toEqual([]);
});

test('admin data tables fit a narrow viewport', async ({ page }) => {
  await page.setViewportSize({width:390,height:844});
  await login(page, 'ui_admin', 'ui-admin-password');
  for(const label of ['Agents','SQL','Audit log']){
    await page.getByRole('button',{name:label,exact:true}).first().click();
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
  await page.locator('#nav button', { hasText: 'Agents' }).click();
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
  await page.locator('#nav button', { hasText: 'MCP servers' }).click();
  await page.locator('#mcName').fill('ui_mock_mcp');
  await page.locator('#mcUrl').fill(baseURL + '/mock/mcp');
  await page.locator('#mcPrivate').check();
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
  await page.locator('#nav button', { hasText: 'Functions & procedures' }).click();
  await expect(page.locator('#view')).toContainText('ui_mock_mcp_get_status');
  // A server's tools do not appear on the APIs page.
  await page.locator('#nav button', { hasText: 'APIs' }).click();
  await expect(page.locator('#view')).not.toContainText('/mock/mcp');
});

test('admin signs in to an MCP server with OAuth', async ({ page }) => {
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.locator('#nav button', { hasText: 'MCP servers' }).click();
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
  await page.locator('#nav button', { hasText: 'MCP servers' }).click();
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
  await page.locator('#nav button', { hasText: 'APIs' }).click();
  const row = page.locator('#view tbody tr', { hasText: 'ui_ping_mock' });
  await expect(row.getByText('not tested')).toBeVisible();
  await row.getByRole('button', { name: 'Test' }).click();
  await expect(row.getByText('reachable', { exact: true })).toBeVisible({ timeout: 20000 });
  await page.locator('#nav button', { hasText: 'Models & prices' }).click();
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
  await page.locator('#nav button', { hasText: 'Decision model' }).click();
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
  await page.locator('#nav button', { hasText: 'APIs' }).click();
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
  await page.locator('#nav button', { hasText: 'Inbound events' }).click();
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
  await page.locator('#nav button', { hasText: 'Home' }).click();
  await expect(page.getByText('1 inbound event')).toBeVisible({ timeout: 20000 });
  await page.locator('#nav button', { hasText: 'Inbound events' }).click();
  const row = page.locator('#view tbody tr', { hasText: 'pump-3' });
  await expect(row.getByText('waiting')).toBeVisible();
  await row.getByRole('button', { name: 'Start a task' }).click();
  await expect(page.locator('#view tbody tr', { hasText: 'pump-3' }).getByText('task started')).toBeVisible({ timeout: 20000 });
  await expect(page.locator('#view')).not.toContainText(secret);
});

test('regular user sees only scoped chat and personal settings', async ({ page }) => {
  await login(page, 'ui_regular', 'ui-regular-password');
  await expect(page.locator('#nav button')).toHaveCount(4);
  for (const label of ['General','Projects','Approvals','My agents']) {
    const button=page.locator('#nav button',{hasText:label});
    await expect(button).toBeVisible();
    await button.click();
    await expect(button).toHaveClass(/active/);
  }
  await page.locator('#nav button', { hasText: 'General' }).click();
  await expect(page.locator('#generalChatThread')).toBeVisible();
  await expect(page.getByText('not assigned to your account')).toHaveCount(0);
  for (const forbidden of ['Home','Canvas','SQL','Agents','People','Memories','Audit log'])
    await expect(page.locator('#nav').getByRole('button',{name:forbidden,exact:true})).toHaveCount(0);
  await page.goto(baseURL + '/canvas');
  await expect(page.getByText('Admins only')).toBeVisible();
});

test('admin sets up approval routing and sees the decision records', async ({ page }) => {
  page.on('dialog', d => d.accept());
  const stamp = Date.now(), role = `UI approver ${stamp}`, unit = `UI unit ${stamp}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.locator('#nav button', { hasText: 'Approvals' }).click();
  // Mine / All toggle on the approvals list, and the admin Decisions tab.
  await expect(page.getByRole('button', { name: 'Mine', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Mine', exact: true }).click();
  await expect(page.getByText('Nothing is waiting on you')).toBeVisible();
  await page.locator('#nav button', { hasText: 'People' }).click();
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
  await page.locator('#nav button', { hasText: 'Approvals' }).click();
  await page.getByRole('button', { name: 'Decisions', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'approval_decision' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'proposal_decision' })).toBeVisible();
  await expect(page.getByText('Recorded fields:').first()).toContainText('reason');
  await page.getByRole('button', { name: 'Export training set' }).first().click();
  await expect(page.locator('#toast')).toContainText(/Nothing to export|Exported/);
  // Clean up: deleting the role takes its rule and membership with it.
  await page.locator('#nav button', { hasText: 'People' }).click();
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
  await page.locator('#nav button', { hasText: 'Approvals' }).click();
  await expect(page.getByRole('button', { name: 'Mine', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Decisions', exact: true })).toHaveCount(0);
  await expect(page.locator('#nav').getByRole('button', { name: 'People', exact: true })).toHaveCount(0);
});

test('mobile navigation remains keyboard reachable', async ({ page }) => {
  await page.setViewportSize({width:390,height:844});
  await login(page, 'ui_regular', 'ui-regular-password');
  await page.locator('#nav button').first().focus();
  for (let i=0;i<4;i++) {
    await expect(page.locator('#nav button').nth(i)).toBeVisible();
    await page.locator('#nav button').nth(i).press('Enter');
  }
  const width = await page.evaluate(() => ({
    document: document.documentElement.scrollWidth,
    viewport: document.documentElement.clientWidth,
  }));
  expect(width.document).toBeLessThanOrEqual(width.viewport);
});
