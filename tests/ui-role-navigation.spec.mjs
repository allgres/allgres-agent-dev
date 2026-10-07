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
  for (const forbidden of ['Dashboard','SQL','Agents','Memories','Audit'])
    await expect(page.locator('#nav').getByRole('button',{name:forbidden,exact:true})).toHaveCount(0);
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
