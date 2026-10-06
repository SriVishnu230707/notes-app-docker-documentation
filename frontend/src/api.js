export async function request(path, options = {}) {
  let response;
  try {
    response = await fetch(`/api${path}`, {
      ...options,
      headers: {
        ...(options.body ? { 'Content-Type': 'application/json' } : {}),
        ...options.headers,
      },
    });
  } catch (error) {
    if (error.name === 'AbortError') throw error;
    throw new Error('Unable to connect. Please try again.');
  }
  if (response.status === 204) return null;
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    if (typeof data?.detail === 'string') throw new Error(data.detail);
    if (Array.isArray(data?.detail)) {
      throw new Error(data.detail.map(item => `${item.loc?.at(-1) || 'Note'}: ${item.msg}`).join('. '));
    }
    throw new Error(`Request failed (${response.status}). Please try again.`);
  }
  if (data === null) throw new Error('Received an unexpected response. Please try again.');
  return data;
}
