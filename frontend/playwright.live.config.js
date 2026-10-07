import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './live-tests',
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 30_000,
  forbidOnly: Boolean(process.env.CI),
  use: {
    baseURL: process.env.NOTES_E2E_BASE_URL || 'http://127.0.0.1:8080',
    browserName: 'chromium',
    channel: process.env.PLAYWRIGHT_CHANNEL || undefined,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  // These tests use the running Docker stack, with no Vite server or API mocks.
});
