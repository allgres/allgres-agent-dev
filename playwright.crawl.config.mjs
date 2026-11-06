import { defineConfig } from '@playwright/test';
// The crawler runs alone (its own job): it presses a great many buttons.
export default defineConfig({
  testDir: './tests',
  testMatch: 'ui-crawl.spec.mjs',
  workers: 1,
  retries: 0,
  use: { headless: true, trace: 'retain-on-failure' },
  reporter: [['line']],
});
