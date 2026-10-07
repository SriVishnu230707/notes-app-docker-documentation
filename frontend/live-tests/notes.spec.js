import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';

test('browser CRUD persists through Nginx, FastAPI and PostgreSQL', async ({ page, request }) => {
  const title = `Browser check ${randomUUID()}`;
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  let noteId;
  try {
    const before = await request.get('/api/stats');
    expect(before.ok()).toBeTruthy();
    const writesBefore = (await before.json()).writes;
    expect(Number.isInteger(writesBefore)).toBeTruthy();
    await page.goto('/');
    await page.getByLabel('Note title').fill(title);
    await page.getByLabel('Note content').fill('Created from the real browser.');
    const created = page.waitForResponse(response => response.url().endsWith('/api/notes') && response.request().method() === 'POST');
    await page.getByRole('button', { name: 'Save note' }).click();
    const response = await created;
    expect(response.status()).toBe(201);
    noteId = (await response.json()).id;
    await expect(page.getByRole('status')).toHaveText('Saved.');

    await page.getByLabel('Note content').fill('Saved to PostgreSQL — café.');
    await page.getByRole('button', { name: 'Save note' }).click();
    await expect(page.getByRole('status')).toHaveText('Saved.');
    await page.reload();
    await page.getByLabel('Search your notes').fill(title);
    await page.getByRole('navigation', { name: 'Notes' }).getByRole('button', { name: new RegExp(title) }).click();
    await expect(page.getByLabel('Note content')).toHaveValue('Saved to PostgreSQL — café.');
    const persisted = await request.get(`/api/notes/${noteId}`);
    expect(persisted.ok()).toBeTruthy();
    expect((await persisted.json()).content).toBe('Saved to PostgreSQL — café.');

    page.once('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Delete', exact: true }).click();
    await expect(page.getByRole('status')).toHaveText('Note deleted.');
    expect((await request.get(`/api/notes/${noteId}`)).status()).toBe(404);
    const after = await request.get('/api/stats');
    expect(after.ok()).toBeTruthy();
    expect((await after.json()).writes).toBeGreaterThanOrEqual(writesBefore + 3);
    expect(errors).toEqual([]);
  } finally {
    // Remove only this test's note, including if a later assertion fails.
    if (noteId) {
      const cleanup = await request.delete(`/api/notes/${noteId}`);
      expect([204, 404]).toContain(cleanup.status());
    } else {
      // A create may commit even if its response was interrupted.
      const notes = await request.get('/api/notes');
      if (notes.ok()) {
        for (const note of await notes.json()) {
          if (note.title === title) {
            expect((await request.delete(`/api/notes/${note.id}`)).status()).toBe(204);
          }
        }
      }
    }
  }
});

test('production assets and live dependency health are reachable', async ({ request }) => {
  const health = await request.get('/api/health');
  expect(health.status()).toBe(200);
  expect(await health.json()).toEqual({ status: 'ok', postgres: 'ok', redis: 'ok' });
  const html = await request.get('/');
  expect(html.status()).toBe(200);
  expect(html.headers()['cache-control']).toContain('no-cache');
  expect(html.headers()['content-security-policy']).toContain("frame-ancestors 'none'");
  expect(html.headers()['x-content-type-options']).toBe('nosniff');
  const text = await html.text();
  const asset = text.match(/src="(\/assets\/[^" ]+\.js)"/);
  expect(asset).not.toBeNull();
  const javascript = await request.get(asset[1]);
  expect(javascript.status()).toBe(200);
  expect(javascript.headers()['content-type']).toMatch(/javascript/);
  expect(javascript.headers()['cache-control']).toContain('immutable');
  expect(javascript.headers()['content-security-policy']).toContain("script-src 'self'");
  const missing = await request.get('/assets/missing-live-check.js');
  expect(missing.status()).toBe(404);
  expect(missing.headers()['x-frame-options']).toBe('DENY');
  expect((await request.get('/api/notes', { headers: { Host: 'attacker.example' } })).status()).toBe(400);
  expect((await request.post('/api/notes', { headers: { Origin: 'https://attacker.example' }, data: { title: 'Must not save' } })).status()).toBe(403);
});

test('two tabs cannot overwrite or delete a newer note version', async ({ page, context, request }) => {
  const title = `Conflict check ${randomUUID()}`;
  const created = await request.post('/api/notes', { data: { title, content: 'Original' } });
  expect(created.status()).toBe(201);
  const noteId = (await created.json()).id;
  const second = await context.newPage();
  try {
    for (const tab of [page, second]) {
      await tab.goto('/');
      await tab.getByLabel('Search your notes').fill(title);
      await tab.getByRole('navigation', { name: 'Notes' }).getByRole('button', { name: new RegExp(title) }).click();
    }
    await page.getByLabel('Note content').fill('First tab saved');
    await page.getByRole('button', { name: 'Save note' }).click();
    await expect(page.getByRole('status')).toHaveText('Saved.');
    await second.getByLabel('Note content').fill('Competing draft');
    await second.getByRole('button', { name: 'Save note' }).click();
    await expect(second.getByRole('alert')).toContainText('changed elsewhere');
    await expect(second.getByLabel('Note content')).toHaveValue('Competing draft');
    await expect(second.getByRole('button', { name: 'Delete', exact: true })).toBeDisabled();
    const stored = await request.get(`/api/notes/${noteId}`);
    expect((await stored.json()).content).toBe('First tab saved');
    second.once('dialog', dialog => dialog.accept());
    await second.getByRole('button', { name: 'Reload saved notes' }).click();
    await second.getByRole('navigation', { name: 'Notes' }).getByRole('button', { name: new RegExp(title) }).click();
    await expect(second.getByLabel('Note content')).toHaveValue('First tab saved');
  } finally {
    await second.close();
    expect([204, 404]).toContain((await request.delete(`/api/notes/${noteId}`)).status());
  }
});
