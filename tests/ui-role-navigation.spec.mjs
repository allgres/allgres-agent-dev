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
  await expect(page.getByText('System agents', { exact: true }).first()).toBeVisible();
  await general.click();
  await expect(page.locator('.inspector')).toContainText('Hierarchy');
  for (const name of [lead, worker]) {
    await page.locator('.pal-item', { hasText: 'Created where you drop it' }).click();
    await page.locator('#dlg-name').fill(name);
    await page.locator('#dlg-provider').selectOption('');
    await page.getByRole('button', { name: 'Create agent' }).click();
    await expect(page.locator(`.agent-node[data-agent="${name}"]`)).toBeVisible();
  }
  const leadNode=page.locator(`.react-flow__node:has(.agent-node[data-agent="${lead}"])`);
  const workerNode=page.locator(`.react-flow__node:has(.agent-node[data-agent="${worker}"])`);
  // Both agents on screen and clear of the General dock before dragging.
  if (await page.getByRole('button', { name: 'Hide' }).isVisible()) await page.getByRole('button', { name: 'Hide' }).click();
  await page.getByRole('button', { name: 'Fit', exact: true }).click();
  await page.waitForTimeout(400);
  // A line from the lead's bottom dot to the worker is an `agent` grant.
  await leadNode.locator('.react-flow__handle-bottom').dragTo(workerNode.locator('.react-flow__handle-top'));
  await expect(page.locator('.react-flow__edge.edge-delegate')).not.toHaveCount(0);
  await leadNode.click();
  await expect(page.locator('.inspector')).toContainText(`Delegates to${worker}`);
  // Shift+click selects both; Group selected puts them in one box.
  await page.keyboard.down('Shift');
  await workerNode.click();
  await page.keyboard.up('Shift');
  await page.getByRole('button', { name: 'Group selected (2)' }).click();
  await page.locator('#dlg-name').fill(team);
  await page.getByRole('button', { name: 'Create group' }).click();
  await expect(page.locator(`.group-node[data-group="${team}"]`)).toContainText('2');
  await page.getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(page.locator(`.group-node[data-group="${team}"]`)).toHaveCount(0);
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
