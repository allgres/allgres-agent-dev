import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './tests',
  testMatch: 'ui-role-navigation.spec.mjs',
  workers: 1,
  retries: 1,
  use: { headless: true, trace: 'retain-on-failure' },
  reporter: [['line']],
});
