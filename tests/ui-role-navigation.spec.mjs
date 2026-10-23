import { test, expect } from '@playwright/test';

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
  const labels = ['Dashboard','General','Projects','Approvals','SQL','Settings','Agents','Memories','Audit'];
  for (const label of labels) {
    const button = page.locator('#nav button', { hasText: label }).first();
    await expect(button).toBeVisible();
    await button.click();
    await expect(button).toHaveClass(/active/);
  }
  await page.locator('#nav button', { hasText: 'General' }).click();
  await expect(page.locator('#generalChatThread')).toBeVisible();
  await expect(page.locator('#msgInput')).toHaveCount(0);
  await page.locator('#nav button', { hasText: 'Settings' }).click();
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
  // The Agents page's permissions.grant is held to the same delegation rules
  // as the board (fn_grant_permission enforces them for every path): no line
  // into a system agent, none past the ceiling (general holds a procedure the
  // new lead does not).
  const refused = await page.evaluate(async ({ lead }) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const agents = (await call({ action: 'agents.list' })).agents;
    const leadId = agents.find(a => a.name === lead).agent_id;
    const out = [];
    for (const ref of ['fixer', 'general']) out.push(await call({ action: 'permissions.grant', agent_id: leadId, type: 'agent', ref }));
    return out;
  }, { lead });
  expect(refused[0].ok).toBe(false);
  expect(refused[0].error).toMatch(/system agents .*cannot take delegated work/);
  expect(refused[1].ok).toBe(false);
  expect(refused[1].error).toMatch(/exceeds the ceiling/);
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

// Every registered Function is a grant choice -- not only the two built-ins:
// an MCP tool such as web_search shows up in permissions.options and in the
// Canvas "Add an ability" list.
test('registered functions are offered as grant choices', async ({ page }) => {
  const stamp=Date.now();
  const fn=`ui_web_search_${stamp}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  const opts = await page.evaluate(async ({ fn, stamp }) => {
    const call = async body => (await fetch('/api/v1/rpc', { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
      body: JSON.stringify({ ...body, session_token: sessionStorage.getItem('allgres_session_token') }) })).json();
    const conn = await call({ action: 'connections.create', name: `ui_mcp_${stamp}`, base_url: 'https://mcp.ui-test.invalid/mcp' });
    if (conn.ok === false) throw new Error(conn.error);
    const made = await call({ action: 'functions.create', name: fn, description: 'search the web', handler: 'mcp_call',
      args_template: { tool: 'web_search' }, mcp_connection_id: conn.connection_id });
    if (made.ok === false) throw new Error(made.error);
    return call({ action: 'permissions.options' });
  }, { fn, stamp });
  expect(opts.functions).toEqual(expect.arrayContaining(['http_get', 'http_request', fn]));
  expect(opts.function_catalog).toEqual(expect.arrayContaining([
    expect.objectContaining({ name: fn, kind: 'mcp_call', description: 'search the web' })]));
  await page.goto(baseURL + '/canvas');
  const gotIt = page.getByRole('button', { name: 'Got it' });
  if (await gotIt.isVisible().catch(() => false)) await gotIt.click();
  await page.locator('.agent-node', { hasText: 'general' }).first().click();
  await expect(page.getByLabel('Add an ability').locator(`option[value="function:${fn}"]`)).toHaveCount(1);
});

// A fresh install (only the seeded general/analyst/health_monitor besides
// system agents, no teams) shows the "Build your first team" card. The board
// is narrowed to that state by rewriting canvas.state, so the test does not
// depend on what earlier tests or suites created.
test('canvas empty state ignores the seeded agents', async ({ page }) => {
  const SEEDED = ['general', 'analyst', 'health_monitor'];
  let keep = SEEDED;
  await page.route('**/api/v1/rpc', async route => {
    const body = route.request().postDataJSON?.() ?? null;
    if (!body || body.action !== 'canvas.state') return route.continue();
    const res = await route.fetch();
    const j = await res.json();
    j.agents = (j.agents || []).filter(a => a.is_system || keep.includes(a.name));
    j.groups = [];
    return route.fulfill({ response: res, json: j });
  });
  await login(page, 'ui_admin', 'ui-admin-password');
  await page.goto(baseURL + '/canvas');
  const gotIt = page.getByRole('button', { name: 'Got it' });
  if (await gotIt.isVisible().catch(() => false)) await gotIt.click();
  await expect(page.locator('.agent-node', { hasText: 'analyst' }).first()).toBeVisible();
  await expect(page.getByRole('region', { name: 'Build your first team' })).toBeVisible();
  // One agent of the operator's own and the card goes away.
  const agents = await page.evaluate(async () => (await (await fetch('/api/v1/rpc', { method: 'POST',
    headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
    body: JSON.stringify({ action: 'agents.list', session_token: sessionStorage.getItem('allgres_session_token') }) })).json()).agents);
  const own = agents.find(a => !a.is_system && !SEEDED.includes(a.name));
  expect(own, 'an earlier test created an agent of its own').toBeTruthy();
  keep = [...SEEDED, own.name];
  await page.reload();
  await expect(page.locator(`.agent-node[data-agent="${own.name}"]`)).toBeVisible();
  await expect(page.getByRole('region', { name: 'Build your first team' })).toHaveCount(0);
});

test('admin data tables fit a narrow viewport', async ({ page }) => {
  await page.setViewportSize({width:390,height:844});
  await login(page, 'ui_admin', 'ui-admin-password');
  for(const label of ['Agents','SQL','Audit']){
    await page.getByRole('button',{name:label,exact:true}).first().click();
    const width=await page.evaluate(()=>({document:document.documentElement.scrollWidth,viewport:document.documentElement.clientWidth}));
    expect(width.document).toBeLessThanOrEqual(width.viewport);
  }
});

test('first-run setup keeps unconfigured agents in drafts', async ({ page }) => {
  const draftName=`ui_draft_${Date.now()}`;
  await login(page, 'ui_admin', 'ui-admin-password');
  await expect(page.getByText('Start a conversation')).toBeVisible();
  await expect(page.getByRole('button', { name: '3. Say hello to General' })).toBeVisible();
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
  for (const forbidden of ['Dashboard','Canvas','SQL','Agents','Memories','Audit'])
    await expect(page.locator('#nav').getByRole('button',{name:forbidden,exact:true})).toHaveCount(0);
  await page.goto(baseURL + '/canvas');
  await expect(page.getByText('Admins only')).toBeVisible();
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
