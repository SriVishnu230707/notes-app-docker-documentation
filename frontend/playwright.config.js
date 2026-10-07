import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1,
  use: {
    baseURL: `http://127.0.0.1:${process.env.NOTES_TEST_PORT || 5173}`,
    browserName: 'chromium',
    channel: process.env.PLAYWRIGHT_CHANNEL || undefined,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  webServer: {
    command: `npm run dev -- --host 127.0.0.1 --port ${process.env.NOTES_TEST_PORT || 5173} --strictPort`,
    url: `http://127.0.0.1:${process.env.NOTES_TEST_PORT || 5173}`,
    reuseExistingServer: false,
  },
});
