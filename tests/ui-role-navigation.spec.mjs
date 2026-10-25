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
