import { test, expect } from '@playwright/test';

// A screen that draws something is not a feature that works. Each test here
// does something in the page the way a person would and then checks the
// effect it is supposed to have: the agent really hands the work over, the
// room's lead really gets the message, a price really counts, a model that is
// switched off really is not offered. The effect is read through the API (or
// shown by the mock model), never taken from what the page says.
const baseURL = process.env.ALLGRES_UI_URL || 'http://127.0.0.1:8088';
test.describe.configure({ mode: 'serial' });

async function login(page, username, password) {
  const rpc = async body => (await page.request.post(baseURL + '/api/v1/rpc', { headers: { 'x-allgres-client': 'dashboard' }, data: body })).json();
  const t = await rpc({ action: 'auth.login', username, password });
  if (t.session_token) await rpc({ action: 'me.prefs_set', session_token: t.session_token, prefs: { 'ui.page': null, theme: null, lang: null,
    'canvas.help_seen': null, 'canvas.ran': null, 'canvas.system': null, 'canvas.guide_hidden': null, 'ui.conv_id': null } });
  await page.goto(baseURL);
  await page.locator('#liUser').fill(username);
  await page.locator('#liPass').fill(password);
  await page.locator('#liGo').click();
  await expect(page.locator('#whoami')).toContainText(username);
}
const HUB = { Chat: ['Chat', 'Chat'], Agents: ['Agents'], 'Models & prices': ['Connections', 'Models & prices'] };
async function go(page, label) {
  const [nav, tab] = HUB[label] || [label];
  await page.locator('#nav').getByRole('button', { name: nav, exact: true }).click();
  if (tab && (await page.locator('#pageTabs').getByRole('tab').count()) > 0 && (await page.locator('#pageTabs').getByRole('tab', { name: tab, exact: true }).getAttribute('aria-selected')) !== 'true')
    await page.locator('#pageTabs').getByRole('tab', { name: tab, exact: true }).click();
}
// One API call as the signed-in person.
const api = (page, body) => page.evaluate(async b => (await (await fetch('/api/v1/rpc', { method: 'POST',
  headers: { 'content-type': 'application/json', 'x-allgres-client': 'dashboard' },
  body: JSON.stringify({ ...b, session_token: sessionStorage.getItem('allgres_session_token') }) })).json()), body);
const need = r => { if (r.ok === false) throw new Error(JSON.stringify(r)); return r; };

// The built-in mock model, a provider on it, and agents that run on it. An agent's
// own prompt can script what the mock answers ("MOCK_SCRIPT: ..." is its answer, "MOCK_ACTION: ..." an action).
async function seed(page) {
  const p = await api(page, { action: 'provider.create', name: 'fx_mock', kind: 'openai_compat', base_url: baseURL + '/mock', allow_private_network: true });
  if (p.ok === false && !/already|duplicate key/i.test(String(p.error))) throw new Error(p.error);
}
async function makeAgent(page, name, prompt) {
  const a = await api(page, { action: 'agents.create', name, system_prompt: prompt, llm_config: { provider: 'fx_mock', model: 'allgres-mock' }, is_active: true });
  if (a.ok === false && !/already|duplicate key/i.test(String(a.error))) throw new Error(a.error);
  return (await api(page, { action: 'agents.list' })).agents.find(x => x.name === name).agent_id;
}
async function finished(page, session_id, ms = 60000) {
  const until = Date.now() + ms;
  for (;;) {
    const s = await api(page, { action: 'sessions.get', session_id });
    if (s.ok !== false && (s.tasks || []).length && (s.tasks || []).every(t => ['completed', 'failed', 'cancelled'].includes(t.status))) return s;
    if (Date.now() > until) throw new Error('session did not finish: ' + JSON.stringify(s).slice(0, 600));
    await page.waitForTimeout(500);
  }
}

test('a line drawn on the Canvas is what lets an agent hand work over', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await seed(page);
  // MOCK_ACTION makes the mock model answer with exactly this action.
  const script = 'MOCK_ACTION: {"action":"delegate","agent_name":"fx_helper","input":{"goal":"count the invoices"},"wait":false}';
  const boss = await makeAgent(page, 'fx_boss', script);
  await makeAgent(page, 'fx_helper', 'Answers briefly.');

  // No line: the boss tries to hand work over and is refused, so nothing is made for the helper.
  const before = await finished(page, need(await api(page, { action: 'run', agent_id: boss, goal: 'go' })).session_id);
  expect(before.tasks.filter(t => t.agent === 'fx_helper')).toHaveLength(0);

  // Draw the line in the Canvas's details, as a person does.
  await go(page, 'Agents');
  await page.locator('#view tr', { hasText: 'fx_boss' }).first().locator('.agentOnCanvas').click();
  const cv = page.frameLocator('#canvasFrame');
  await expect(cv.locator('aside.inspector[aria-label="fx_boss"]')).toBeVisible({ timeout: 20000 });
  await cv.getByLabel('Add who it hands work to').selectOption({ label: 'fx_helper' });
  await expect.poll(async () => (await api(page, { action: 'permissions.list', agent_id: boss })).permissions?.some(p => p.type === 'agent' && p.ref === 'fx_helper'),
    { timeout: 20000 }).toBe(true);

  // With the line: the same request now ends with a task for the helper, and it ran.
  const after = await finished(page, need(await api(page, { action: 'run', agent_id: boss, goal: 'go again' })).session_id, 90000);
  const helperTask = after.tasks.find(t => t.agent === 'fx_helper');
  expect(helperTask, 'the helper got a task').toBeTruthy();
  expect(helperTask.parent_task_id).toBe(after.tasks.find(t => t.agent === 'fx_boss').task_id);
  expect(helperTask.status).toBe('completed');
});

test('the lead of a room is the one who gets a message that calls nobody', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await seed(page);
  const lead = await makeAgent(page, 'fx_room_lead', 'Answers briefly.');
  const mate = await makeAgent(page, 'fx_room_mate', 'Answers briefly.');
  const room = need(await api(page, { action: 'rooms.create', name: 'fx-lead-room' })).room_id;
  for (const id of [lead, mate]) need(await api(page, { action: 'rooms.member_add', room_id: room, agent_id: id }));

  await go(page, 'Chat');
  await page.locator('#convList .convItem', { hasText: 'fx-lead-room' }).click();
  await page.locator('#view .row', { hasText: 'fx_room_lead' }).getByRole('button', { name: 'Make lead' }).click();
  await expect.poll(async () => (await api(page, { action: 'rooms.get', room_id: room })).room.lead_agent_id, { timeout: 20000 }).toBe(lead);

  await page.locator('#rmText').fill('Who is looking at the quarter figures?');
  await page.locator('#rmSend').click();
  // Nobody was called by name, yet an agent answered, and it was the lead and nobody else.
  await expect(page.locator('#rmThread .msg', { hasText: 'Allgres mock runtime OK' })).toBeVisible({ timeout: 60000 });
  const got = await api(page, { action: 'rooms.get', room_id: room });
  const answers = got.messages.filter(m => m.by_agent && m.kind === 'say');
  expect(answers.length).toBeGreaterThan(0);
  expect(answers.every(m => m.author === 'fx_room_lead')).toBe(true);
});

test('a price typed beside a model is the price that counts toward a room\'s cost', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await seed(page);
  const agent = await makeAgent(page, 'fx_priced', 'Answers briefly.');
  const room = need(await api(page, { action: 'rooms.create', name: 'fx-cost-room' })).room_id;
  need(await api(page, { action: 'rooms.member_add', room_id: room, agent_id: agent }));

  await go(page, 'Models & prices');
  const prov = page.locator('details.mrProv[data-prov="fx_mock"]');
  await expect(prov).toBeVisible();
  if ((await prov.getAttribute('open')) === null) await prov.locator('summary').click();
  const row = prov.locator('tr[data-model="allgres-mock"]');
  await expect(row).toBeVisible({ timeout: 30000 });
  await row.locator('.mrIn').fill('5');
  await row.locator('.mrOut').fill('10');
  await row.locator('.mrPriceSave').click();
  await expect(prov.locator('tr[data-model="allgres-mock"] .mrIn')).toHaveValue('5');

  need(await api(page, { action: 'rooms.post', room_id: room, text: 'hello @fx_priced' }));
  await expect.poll(async () => Number((await api(page, { action: 'rooms.get', room_id: room })).room.cost_usd), { timeout: 60000 }).toBeGreaterThan(0);
});

test('a model that is switched off is not offered, is refused by Use on agents, and fails an agent set to it', async ({ page }) => {
  test.setTimeout(90000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await seed(page);
  await makeAgent(page, 'fx_off_target', 'Answers briefly.');
  const offered = async () => (await api(page, { action: 'providers.available' })).providers.find(p => p.name === 'fx_mock')?.available_models || [];

  await go(page, 'Models & prices');
  const prov = page.locator('details.mrProv[data-prov="fx_mock"]');
  if ((await prov.getAttribute('open')) === null) await prov.locator('summary').click();
  const row = prov.locator('tr[data-model="allgres-mock-embed"]');
  await expect(row).toBeVisible({ timeout: 30000 });
  expect(await offered()).toContain('allgres-mock-embed');
  await row.locator('.mrOn').uncheck();
  await expect.poll(offered, { timeout: 20000 }).not.toContain('allgres-mock-embed');

  // "Use on agents…" refuses it. An agent that was set to it some other way says why it cannot
  // work, and its turn fails instead of calling the model.
  const agents = (await api(page, { action: 'agents.list' })).agents;
  const target = agents.find(a => a.name === 'fx_off_target');
  const applied = await api(page, { action: 'models.apply', provider: 'fx_mock', model: 'allgres-mock-embed', agent_ids: [target.agent_id] });
  expect(applied.ok).toBe(false);
  need(await api(page, { action: 'agents.update', agent_id: target.agent_id, llm_config: { provider: 'fx_mock', model: 'allgres-mock-embed' } }));
  const listed = (await api(page, { action: 'agents.list' })).agents.find(a => a.agent_id === target.agent_id);
  expect(listed.model_issue).toMatch(/switched off/);
  const ran = await finished(page, need(await api(page, { action: 'run', agent_id: target.agent_id, goal: 'go' })).session_id);
  expect(ran.tasks[0].status).toBe('failed');
  need(await api(page, { action: 'agents.update', agent_id: target.agent_id, llm_config: { provider: 'fx_mock', model: 'allgres-mock' } }));
  // Switch it back on so later tests find it.
  await prov.locator('tr[data-model="allgres-mock-embed"] .mrOn').check();
  await expect.poll(offered, { timeout: 20000 }).toContain('allgres-mock-embed');
});

test('an agent switched off in the Canvas takes no work, and switched on takes it again', async ({ page }) => {
  test.setTimeout(120000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await seed(page);
  const id = await makeAgent(page, 'fx_switch', 'Answers briefly.');
  await go(page, 'Agents');
  await page.locator('#view tr', { hasText: 'fx_switch' }).first().locator('.agentOnCanvas').click();
  const cv = page.frameLocator('#canvasFrame');
  const insp = cv.locator('aside.inspector[aria-label="fx_switch"]');
  await expect(insp).toBeVisible({ timeout: 20000 });
  const sw = insp.getByRole('switch');
  if ((await sw.getAttribute('aria-checked')) === 'true') await sw.click();
  await expect.poll(async () => (await api(page, { action: 'agents.list' })).agents.find(a => a.agent_id === id).is_active, { timeout: 20000 }).toBe(false);
  const refused = await api(page, { action: 'run', agent_id: id, goal: 'work please' });
  expect(refused.ok).toBe(false);

  await sw.click();
  await expect.poll(async () => (await api(page, { action: 'agents.list' })).agents.find(a => a.agent_id === id).is_active, { timeout: 20000 }).toBe(true);
  const done = await finished(page, need(await api(page, { action: 'run', agent_id: id, goal: 'work please' })).session_id);
  expect(done.tasks[0].status).toBe('completed');
});

test('an archived chat leaves the list and takes no more messages', async ({ page }) => {
  test.setTimeout(90000);
  await login(page, 'ui_admin', 'ui-admin-password');
  await seed(page);
  page.on('dialog', d => d.accept());
  await go(page, 'Chat');
  await page.locator('#convNew').click();
  await expect(page.locator('#convArchive')).toBeVisible();
  const id = await page.evaluate(() => state.convId);
  expect(id).toBeTruthy();
  await page.locator('#convArchive').click();
  await expect(page.locator(`#convList .convItem[data-id="${id}"]`)).toHaveCount(0);
  const listed = (await api(page, { action: 'conv.list' })).conversations.map(c => c.conversation_id);
  expect(listed).not.toContain(id);
  const sent = await api(page, { action: 'conv.send', conversation_id: id, message: 'still there?' });
  expect(sent.ok).toBe(false);
});
