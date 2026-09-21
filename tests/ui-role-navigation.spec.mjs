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
  await login(page, 'ui_admin', 'ui-admin-password');
  const labels = ['Dashboard','General','Projects','Approvals','SQL','Overview','Agents','Memories','Audit'];
  for (const label of labels) {
    const button = page.locator('#nav button', { hasText: label }).first();
    await expect(button).toBeVisible();
    await button.click();
    await expect(button).toHaveClass(/active/);
  }
  await page.locator('#nav button', { hasText: 'Overview' }).click();
  await expect(page.locator('#bulkApply')).toHaveCount(0);
  await page.evaluate(async () => {
    const body={action:'users.create',username:'ui_regular',password:'ui-regular-password',role:'user',session_token:sessionStorage.getItem('allgres_session_token')};
    const r=await fetch('/api/v1/rpc',{method:'POST',headers:{'content-type':'application/json','x-allgres-client':'dashboard'},body:JSON.stringify(body)});
    const j=await r.json(); if(j.ok===false && !String(j.error).includes('already')) throw new Error(j.error);
  });
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
  for (const forbidden of ['Dashboard','SQL','Agents','Memories','Audit'])
    await expect(page.locator('#nav button',{hasText:forbidden})).toHaveCount(0);
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
