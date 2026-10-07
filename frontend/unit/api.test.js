import test from 'node:test';
import assert from 'node:assert/strict';
import { request, ApiError } from '../src/api.js';

const note = { id: '11111111-1111-4111-8111-111111111111', title: 'Note', content: '', created_at: '2026-10-07T00:00:00Z', updated_at: '2026-10-07T00:00:00Z' };
const originalFetch = globalThis.fetch;
test.afterEach(() => { globalThis.fetch = originalFetch; });
const response = (data, status = 200) => new Response(JSON.stringify(data), { status });

test('accepts the API note list', async () => {
  globalThis.fetch = async () => response([note]);
  assert.deepEqual(await request('/notes'), [note]);
});
test('rejects wrong list and note shapes before rendering', async () => {
  for (const data of [{ notes: [] }, [null], [{ ...note, id: '../bad-path' }], [{ ...note, title: null }], [{ ...note, updated_at: 'invalid' }]]) {
    globalThis.fetch = async () => response(data);
    await assert.rejects(request('/notes'), /unexpected response/);
  }
  globalThis.fetch = async () => response({ ok: true }, 201);
  await assert.rejects(request('/notes', { method: 'POST', body: '{}' }), /Reload notes before retrying/);
});
test('rejects invalid activity shapes', async () => {
  for (const data of [{ writes: {}, redis_available: true }, { writes: -1, redis_available: true }, { writes: 2 }, null]) {
    globalThis.fetch = async () => response(data);
    await assert.rejects(request('/stats'), ApiError);
  }
});
test('preserves HTTP status and formats validation details', async () => {
  globalThis.fetch = async () => response({ detail: [{ loc: ['body', 'title'], msg: 'Invalid title' }, null] }, 422);
  await assert.rejects(request('/notes'), error => error.status === 422 && error.message.includes('title: Invalid title'));
  globalThis.fetch = async () => response({ detail: 'Note not found' }, 404);
  await assert.rejects(request('/notes/unknown'), error => error.status === 404);
});
test('handles non-JSON proxy errors', async () => {
  globalThis.fetch = async () => new Response('<html>Bad gateway</html>', { status: 502 });
  await assert.rejects(request('/notes'), error => error.status === 502 && error.message.includes('502'));
});
test('times out stalled writes without implying they were not saved', async () => {
  globalThis.fetch = async (_, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
  });
  await assert.rejects(request('/notes', { method: 'POST', body: '{}', timeoutMs: 10 }), /may have been saved/);
});
test('forwards intentional cancellation', async () => {
  const controller = new AbortController();
  controller.abort();
  globalThis.fetch = async (_, options) => { options.signal.throwIfAborted(); };
  await assert.rejects(request('/notes', { signal: controller.signal }), error => error.name === 'AbortError');
});
test('accepts empty DELETE responses but rejects empty successful reads', async () => {
  globalThis.fetch = async () => new Response(null, { status: 204 });
  assert.equal(await request('/notes/id', { method: 'DELETE' }), null);
  await assert.rejects(request('/notes'), /unexpected response/);
});

test('normalizes method casing and rejects duplicate note IDs', async () => {
  globalThis.fetch = async (_, options) => {
    assert.equal(options.method, 'DELETE');
    return new Response(null, { status: 204 });
  };
  assert.equal(await request('/notes/id', { method: 'delete' }), null);
  globalThis.fetch = async () => response([note, note]);
  await assert.rejects(request('/notes'), /unexpected response/);
});
