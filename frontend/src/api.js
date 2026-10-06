export class ApiError extends Error {
  constructor(message, status) { super(message); this.name = 'ApiError'; this.status = status; }
}

function isNote(value) {
  return value && typeof value.id === 'string'
    && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value.id)
    && typeof value.title === 'string'
    && typeof value.content === 'string'
    && typeof value.created_at === 'string' && Number.isFinite(Date.parse(value.created_at))
    && typeof value.updated_at === 'string' && Number.isFinite(Date.parse(value.updated_at));
}

function validResponse(path, method, data) {
  if (path === '/stats') return data && typeof data.redis_available === 'boolean'
    && (data.writes === null || (Number.isSafeInteger(data.writes) && data.writes >= 0));
  if (path === '/notes' && method === 'GET') return Array.isArray(data) && data.every(isNote);
  if (path.startsWith('/notes')) return isNote(data);
  return data !== null;
}

export async function request(path, options = {}) {
  const { timeoutMs = 15000, signal, ...fetchOptions } = options;
  const controller = new AbortController();
  const cancel = () => controller.abort();
  if (signal?.aborted) cancel();
  else signal?.addEventListener('abort', cancel, { once: true });
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
  const method = options.method || 'GET';
  try {
    const response = await fetch(`/api${path}`, {
      ...fetchOptions, signal: controller.signal,
      headers: { ...(options.body ? { 'Content-Type': 'application/json' } : {}), ...options.headers },
    });
    if (response.status === 204 && method === 'DELETE') return null;
    let data = null;
    try { data = await response.json(); }
    catch (error) { if (controller.signal.aborted) throw error; }
    if (!response.ok) {
      if (typeof data?.detail === 'string') throw new ApiError(data.detail, response.status);
      if (Array.isArray(data?.detail)) {
        const detail = data.detail.map(item => `${item?.loc?.at(-1) || 'Note'}: ${item?.msg || 'Invalid value'}`).join('. ');
        throw new ApiError(detail || 'Invalid note.', response.status);
      }
      throw new ApiError(`Request failed (${response.status}). Please try again.`, response.status);
    }
    if (!validResponse(path, method, data)) {
      throw new ApiError('Received an unexpected response. Reload notes before retrying.', response.status);
    }
    return data;
  } catch (error) {
    if (timedOut) throw new ApiError(method === 'GET'
      ? 'Request timed out. Please try again.'
      : 'Request timed out. Your changes may have been saved; reload notes before retrying.');
    if (signal?.aborted || error instanceof ApiError) throw error;
    throw new ApiError(method === 'GET' ? 'Unable to connect. Please try again.'
      : 'Connection interrupted. Your changes may have been saved; reload notes before retrying.');
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', cancel);
  }
}
