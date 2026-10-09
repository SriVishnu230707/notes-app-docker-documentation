import { test, expect } from '@playwright/test';
import { readFile } from 'node:fs/promises';

async function mockApi(page, options = {}) {
  const state = { notes: options.notes || [], writes: 0, failLoad: options.failLoad || false, failSave: false, failStats: false };
  await page.route('**/api/**', async route => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    const reply = (status, json) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(json) });
    if (path === '/api/stats') return state.failStats ? reply(503, { detail: 'Activity unavailable' }) : reply(200, { writes: state.writes, redis_available: true });
    if (req.method() === 'GET' && path === '/api/notes') {
      if (state.badLoad) return reply(200, { notes: [] });
      return state.failLoad ? reply(503, { detail: 'Database is unavailable' }) : reply(200, state.notes);
    }
    if (state.failSave) return reply(503, { detail: 'Database is unavailable' });
    if (state.conflict && req.method() !== 'POST') return reply(412, { detail: 'This note changed elsewhere. Reload notes before saving or deleting.' });
    if (req.method() === 'POST') {
      const now = new Date().toISOString();
      const note = { ...req.postDataJSON(), id: '11111111-1111-4111-8111-111111111111', created_at: now, updated_at: now };
      state.notes.unshift(note); state.writes++;
      return reply(201, note);
    }
    const id = path.split('/').at(-1);
    const index = state.notes.findIndex(note => note.id === id);
    if (index < 0) return reply(404, { detail: 'Note not found' });
    if (req.method() === 'PUT') {
      state.notes[index] = { ...state.notes[index], ...req.postDataJSON(), updated_at: new Date().toISOString() };
      state.writes++;
      return reply(200, state.notes[index]);
    }
    if (req.method() === 'DELETE') {
      state.notes.splice(index, 1); state.writes++;
      return route.fulfill({ status: 204 });
    }
    return reply(200, state.notes[index]);
  });
  return state;
}

test('create, edit, search, reload and delete a note', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await mockApi(page);
  await page.goto('/');
  await page.getByLabel('Note title').fill('Docker notes');
  await page.getByLabel('Note content').fill('Containers keep projects consistent.');
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  await page.getByLabel('Note content').fill('Updated container notes.');
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  await page.reload();
  await page.getByRole('button', { name: /Docker notes Updated container/ }).click();
  await expect(page.getByLabel('Note content')).toHaveValue('Updated container notes.');
  await page.getByLabel('Search your notes').fill('not-found');
  await expect(page.getByText('No matching notes.')).toBeVisible();
  await page.getByLabel('Search your notes').fill('container');
  await expect(page.getByRole('button', { name: /Docker notes Updated container/ })).toBeVisible();
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: 'Delete', exact: true }).click();
  await expect(page.getByRole('status')).toHaveText('Note deleted.');
  await expect(page.getByLabel('Note title')).toHaveValue('');
  await expect(page.getByLabel('Note title')).toBeFocused();
  expect(errors).toEqual([]);
});

test('protects drafts when switching notes', async ({ page }) => {
  const note = { id: '22222222-2222-4222-8222-222222222222', title: 'Existing note', content: 'Stored body', created_at: '2026-10-06T10:00:00Z', updated_at: '2026-10-06T10:00:00Z' };
  await mockApi(page, { notes: [note] });
  await page.goto('/');
  await page.getByLabel('Note title').fill('Unsaved draft');
  page.once('dialog', dialog => dialog.dismiss());
  await page.getByRole('button', { name: /Existing note Stored body/ }).click();
  await expect(page.getByLabel('Note title')).toHaveValue('Unsaved draft');
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: /Existing note Stored body/ }).click();
  await expect(page.getByLabel('Note title')).toHaveValue('Existing note');
});

test('retains draft after a failed save and allows retry', async ({ page }) => {
  const state = await mockApi(page);
  await page.goto('/');
  await page.getByLabel('Note title').fill('Keep my draft');
  await page.getByLabel('Note content').fill('Do not lose this.');
  state.failSave = true;
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('alert')).toHaveText('Database is unavailable');
  await expect(page.getByLabel('Note content')).toHaveValue('Do not lose this.');
  state.failSave = false;
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
});

test('successful writes survive activity lookup failure', async ({ page }) => {
  const state = await mockApi(page);
  await page.goto('/');
  await page.getByLabel('Note title').fill('Saved despite metrics');
  state.failStats = true;
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  await expect(page.getByText('Activity unavailable')).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
  expect(state.notes).toHaveLength(1);
});

test('failed initial load can be retried', async ({ page }) => {
  const state = await mockApi(page, { failLoad: true });
  await page.goto('/');
  await expect(page.getByRole('alert')).toHaveText('Database is unavailable');
  await expect(page.getByLabel('Note title')).toBeDisabled();
  state.failLoad = false;
  await page.getByRole('button', { name: 'Retry loading notes' }).click();
  await expect(page.getByLabel('Note title')).toBeEnabled();
  await expect(page.getByRole('alert')).toHaveCount(0);
});

test('requires a meaningful title', async ({ page }) => {
  await mockApi(page);
  await page.goto('/');
  await page.getByLabel('Note title').fill('   ');
  await expect(page.getByRole('button', { name: 'Save note' })).toBeDisabled();
});

test('mobile layout stays within the viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mockApi(page);
  await page.goto('/');
  await expect(page.getByLabel('Note title')).toBeEnabled();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy();
  await page.screenshot({ path: 'test-results/mobile.png', fullPage: true });
});

test('desktop workspace renders without browser errors', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await mockApi(page);
  await page.goto('/');
  await expect(page.getByLabel('Note title')).toBeEnabled();
  await page.screenshot({ path: 'test-results/desktop.png', fullPage: true });
  expect(errors).toEqual([]);
});

test('malformed notes response shows a recoverable error instead of crashing', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const state = await mockApi(page);
  state.badLoad = true;
  await page.goto('/');
  await expect(page.getByRole('alert')).toContainText('unexpected response');
  state.badLoad = false;
  await page.getByRole('button', { name: 'Retry loading notes' }).click();
  await expect(page.getByLabel('Note title')).toBeEnabled();
  expect(errors).toEqual([]);
});

test('a deleted remote note can be recovered without losing the draft', async ({ page }) => {
  const note = { id: '22222222-2222-4222-8222-222222222222', title: 'Existing note', content: 'Stored body', created_at: '2026-10-07T00:00:00Z', updated_at: '2026-10-07T00:00:00Z' };
  const state = await mockApi(page, { notes: [note] });
  await page.goto('/');
  await page.getByRole('button', { name: /Existing note Stored body/ }).click();
  await page.getByLabel('Note content').fill('Preserve these edits.');
  state.notes = [];
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('alert')).toHaveText('Note not found');
  await page.getByRole('button', { name: 'Keep draft as a new note' }).click();
  await expect(page.getByLabel('Note content')).toHaveValue('Preserve these edits.');
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  expect(state.notes[0].content).toBe('Preserve these edits.');
});

test('a conflicting edit preserves the draft and blocks repeated overwrites', async ({ page }) => {
  const note = { id: '22222222-2222-4222-8222-222222222222', title: 'Existing note', content: 'Original', created_at: '2026-10-07T00:00:00Z', updated_at: '2026-10-07T00:00:00Z' };
  const state = await mockApi(page, { notes: [note] });
  await page.goto('/');
  await page.getByRole('navigation', { name: 'Notes' }).getByRole('button').click();
  await page.getByLabel('Note content').fill('Keep my competing edit');
  state.conflict = true;
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('alert')).toContainText('changed elsewhere');
  await expect(page.getByLabel('Note content')).toHaveValue('Keep my competing edit');
  await expect(page.getByRole('button', { name: 'Save note' })).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Delete', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Keep draft as a new note' }).click();
  await page.getByRole('button', { name: 'Save note' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  expect(state.notes).toHaveLength(2);
});

test('sorting and trimmed search preserve the current unsaved draft', async ({ page }) => {
  const notes = [
    { id: '11111111-1111-4111-8111-111111111111', title: 'Zebra', content: 'Container guide', created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-09T00:00:00Z' },
    { id: '22222222-2222-4222-8222-222222222222', title: 'Alpha', content: 'Meeting notes', created_at: '2026-10-08T00:00:00Z', updated_at: '2026-10-08T00:00:00Z' },
  ];
  const state = await mockApi(page, { notes });
  await page.goto('/');
  const cards = page.getByRole('navigation', { name: 'Notes' }).getByRole('button');
  await expect(cards.first()).toContainText('Zebra');
  await page.getByLabel('Note title').fill('My unsaved idea');
  await page.getByLabel('Sort notes').selectOption('title');
  await expect(cards.first()).toContainText('Alpha');
  await page.getByLabel('Sort notes').selectOption('created');
  await expect(cards.first()).toContainText('Alpha');
  await page.getByLabel('Sort notes').selectOption('updated');
  await expect(cards.first()).toContainText('Zebra');
  await page.getByLabel('Search your notes').fill('  CONTAINER  ');
  await expect(cards).toHaveCount(1);
  await expect(page.getByText('1 of 2', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Clear search' }).click();
  await expect(cards).toHaveCount(2);
  await expect(page.getByLabel('Search your notes')).toBeFocused();
  await expect(page.getByLabel('Note title')).toHaveValue('My unsaved idea');
  expect(state.writes).toBe(0);
});

test('keyboard shortcuts save once and respect conflict and validation guards', async ({ page }) => {
  const state = await mockApi(page);
  await page.goto('/');
  await expect(page.getByLabel('Note title')).toBeEnabled();
  await page.keyboard.press('Control+s');
  expect(state.writes).toBe(0);
  await page.getByLabel('Note title').fill('Shortcut note');
  await page.getByLabel('Note content').fill('A useful thought.');
  await page.keyboard.press('Control+s');
  await expect(page.getByRole('status')).toHaveText('Saved.');
  await page.keyboard.press('Control+s');
  await expect(page.getByRole('button', { name: 'Save note' })).toBeDisabled();
  expect(state.writes).toBe(1);
  await page.keyboard.press('Meta+k');
  await expect(page.getByLabel('Search your notes')).toBeFocused();
  await page.getByLabel('Note content').fill('An unsaved competing edit.');
  state.conflict = true;
  await page.keyboard.press('Meta+s');
  await expect(page.getByRole('alert')).toContainText('changed elsewhere');
  await page.keyboard.press('Control+s');
  await expect(page.getByLabel('Note content')).toHaveValue('An unsaved competing edit.');
  expect(state.writes).toBe(1);
});

test('Markdown download includes the current Unicode draft without saving it', async ({ page }) => {
  const state = await mockApi(page);
  await page.goto('/');
  await expect(page.getByRole('button', { name: 'Download Markdown' })).toBeDisabled();
  await page.getByLabel('Note title').fill('Ideas — café');
  await page.getByLabel('Note content').fill('Hello, world!\n\n- Keep this draft ✨');
  await expect(page.getByRole('status')).toHaveText('7 words · 34 / 50,000 characters');
  const pendingDownload = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Download Markdown' }).click();
  const download = await pendingDownload;
  expect(download.suggestedFilename()).toBe('notebook-note.md');
  expect(await readFile(await download.path(), 'utf8')).toBe('# Ideas — café\n\nHello, world!\n\n- Keep this draft ✨\n');
  await expect(page.getByRole('status')).toHaveText('Draft downloaded. Changes are still unsaved.');
  await expect(page.getByRole('button', { name: 'Save note' })).toBeEnabled();
  expect(state.notes).toHaveLength(0);
  expect(state.writes).toBe(0);
});
