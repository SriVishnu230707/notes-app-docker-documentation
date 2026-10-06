import { test, expect } from '@playwright/test';

async function mockApi(page, options = {}) {
  const state = { notes: options.notes || [], writes: 0, failLoad: options.failLoad || false, failSave: false, failStats: false };
  await page.route('**/api/**', async route => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    const reply = (status, json) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(json) });
    if (path === '/api/stats') return state.failStats ? reply(503, { detail: 'Activity unavailable' }) : reply(200, { writes: state.writes, redis_available: true });
    if (req.method() === 'GET' && path === '/api/notes') return state.failLoad ? reply(503, { detail: 'Database is unavailable' }) : reply(200, state.notes);
    if (state.failSave) return reply(503, { detail: 'Database is unavailable' });
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
