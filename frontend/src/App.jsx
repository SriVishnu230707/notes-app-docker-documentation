import React, { useCallback, useEffect, useRef, useState } from 'react';
import { request } from './api.js';

export default function App() {
  const [notes, setNotes] = useState([]);
  const [selected, setSelected] = useState(null);
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [search, setSearch] = useState('');
  const [error, setError] = useState('');
  const [loadError, setLoadError] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [writes, setWrites] = useState(null);
  const [message, setMessage] = useState('');
  const titleField = useRef(null);
  const mutationInFlight = useRef(false);

  const refreshActivity = useCallback(async (signal) => {
    try {
      const stats = await request('/stats', { signal });
      setWrites(stats.writes);
    } catch (err) {
      if (err.name !== 'AbortError') setWrites(null);
    }
  }, []);

  const loadNotes = useCallback(async (signal) => {
    setLoading(true);
    setLoadError('');
    try {
      setNotes(await request('/notes', { signal }));
      void refreshActivity(signal);
    } catch (err) {
      if (err.name !== 'AbortError') setLoadError(err.message);
    } finally {
      if (!signal?.aborted) setLoading(false);
    }
  }, [refreshActivity]);

  useEffect(() => {
    const controller = new AbortController();
    void loadNotes(controller.signal);
    return () => controller.abort();
  }, [loadNotes]);

  const original = notes.find(note => note.id === selected);
  const dirty = original
    ? title !== original.title || content !== original.content
    : Boolean(title || content);

  useEffect(() => {
    if (!dirty) return;
    const protectDraft = (event) => { event.preventDefault(); event.returnValue = ''; };
    window.addEventListener('beforeunload', protectDraft);
    return () => window.removeEventListener('beforeunload', protectDraft);
  }, [dirty]);

  function open(note = null) {
    if (busy || loading || note?.id === selected) return;
    if (dirty && !window.confirm('Discard your unsaved changes?')) return;
    setSelected(note?.id || null);
    setTitle(note?.title || '');
    setContent(note?.content || '');
    setError('');
    setMessage('');
    titleField.current?.focus();
  }

  async function save(event) {
    event.preventDefault();
    if (mutationInFlight.current || !title.trim()) return;
    mutationInFlight.current = true;
    setBusy(true); setError(''); setMessage('');
    try {
      const note = await request(selected ? `/notes/${selected}` : '/notes', {
        method: selected ? 'PUT' : 'POST',
        body: JSON.stringify({ title: title.trim(), content }),
      });
      setSelected(note.id); setTitle(note.title); setContent(note.content);
      setNotes(previous => [note, ...previous.filter(item => item.id !== note.id)]);
      setMessage('Saved.');
      void refreshActivity();
    } catch (err) { setError(err.message); }
    finally { mutationInFlight.current = false; setBusy(false); }
  }

  async function remove() {
    if (mutationInFlight.current || !selected || !window.confirm('Delete this note permanently?')) return;
    mutationInFlight.current = true;
    setBusy(true); setError(''); setMessage('');
    try {
      await request(`/notes/${selected}`, { method: 'DELETE' });
      setNotes(previous => previous.filter(note => note.id !== selected));
      setSelected(null); setTitle(''); setContent(''); setMessage('Note deleted.');
      void refreshActivity();
      titleField.current?.focus();
    } catch (err) { setError(err.message); }
    finally { mutationInFlight.current = false; setBusy(false); }
  }

  const filtered = notes.filter(note => `${note.title} ${note.content}`.toLowerCase().includes(search.toLowerCase()));
  return <div className="shell">
    <aside>
      <button className="brand" type="button" onClick={() => open()} disabled={busy || loading} aria-label="Notebook home">
        <span aria-hidden="true">▧</span><span>notebook<span className="brand-dot">.</span></span>
      </button>
      <p className="eyebrow">YOUR SPACE TO THINK</p>
      <button className="new-note" disabled={busy || loading} onClick={() => open()}>＋ New note</button>
      <label className="search-label" htmlFor="search">Search your notes</label>
      <input id="search" type="search" placeholder="Search anything…" value={search} onChange={e => setSearch(e.target.value)} />
      <div className="list-heading">ALL NOTES <span>{notes.length}</span></div>
      <nav aria-label="Notes" aria-busy={loading}>
        {loading ? <p className="muted">Loading your notes…</p> : loadError ? <div>
          <p className="error" role="alert">{loadError}</p>
          <button className="retry" onClick={() => void loadNotes()}>Retry loading notes</button>
        </div> : filtered.length === 0 ? <p className="muted">{search ? 'No matching notes.' : 'A fresh page. Start your first note.'}</p> : filtered.map(note =>
          <button type="button" disabled={busy} key={note.id} aria-pressed={selected === note.id} className={`note-card ${selected === note.id ? 'active' : ''}`} onClick={() => open(note)}>
            <strong>{note.title}</strong><p>{note.content || 'No content yet'}</p>
            <time dateTime={note.updated_at}>{new Date(note.updated_at).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}</time>
          </button>)}
      </nav>
      <footer>Your personal notebook<small>{writes === null ? 'Activity unavailable' : `${writes.toLocaleString()} edits tracked`}</small></footer>
    </aside>
    <main>
      <header><span>PERSONAL WORKSPACE</span><span>{new Date().toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })}</span></header>
      <form onSubmit={save} aria-label="Note editor" aria-busy={busy}>
        <div className="editor-top"><span className="eyebrow">{selected ? 'YOUR NOTE' : 'SOMETHING NEW'}</span><span className="muted">{dirty ? 'Unsaved changes' : selected ? 'All changes saved' : 'Make room for an idea'}</span></div>
        <label className="sr-only" htmlFor="title">Note title</label>
        <input ref={titleField} id="title" className="title" required maxLength={200} placeholder="Untitled idea" value={title} disabled={busy || loading || Boolean(loadError)} onChange={e => { setTitle(e.target.value); setMessage(''); }} />
        <div className="rule" />
        <label className="sr-only" htmlFor="content">Note content</label>
        <textarea id="content" maxLength={50000} placeholder="Let your thoughts unfold here…" value={content} disabled={busy || loading || Boolean(loadError)} onChange={e => { setContent(e.target.value); setMessage(''); }} />
        {error && <p className="error" role="alert">{error}</p>}
        <div className="editor-bottom"><span role="status">{message || `${content.length.toLocaleString()} characters`}</span><div className="actions">
          {selected && <button className="delete" type="button" disabled={busy} onClick={remove}>Delete</button>}
          <button className="save" disabled={busy || loading || Boolean(loadError) || !title.trim() || !dirty}>{busy ? 'Working…' : 'Save note ↗'}</button>
        </div></div>
      </form>
      <div className="reflection">Small thoughts. Big possibilities.</div>
    </main>
  </div>;
}
