'use client';

import Link from 'next/link';
import { useEffect, useMemo, useRef, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';
const wsBase = process.env.NEXT_PUBLIC_WS_URL || 'wss://codeforces-api.manchik.co.uk/ws';
const pageSize = 15;

export default function Home() {
  const [problems, setProblems] = useState([]);
  const [selected, setSelected] = useState(null);
  const [page, setPage] = useState(0);
  const [allTags, setAllTags] = useState([]);
  const [selectedTags, setSelectedTags] = useState([]);
  const [tagsMode, setTagsMode] = useState('any'); // 'any' | 'all'

  useEffect(() => {
    // load tags once
    (async () => {
      try {
        const res = await fetch(`${apiBase}/tags`, { cache: 'no-store' });
        const data = await res.json();
        if (Array.isArray(data)) setAllTags(data);
      } catch (e) {
        console.error('failed to load tags', e);
      }
    })();
  }, []);

  useEffect(() => {
    fetchProblems();
  }, [page, selectedTags, tagsMode]);

  const fetchProblems = async () => {
    const offset = page * pageSize;
    try {
      const qs = new URLSearchParams();
      qs.set('limit', pageSize);
      qs.set('offset', offset);
      if (selectedTags.length > 0) {
        qs.set('tags', selectedTags.join(','));
        qs.set('tags_mode', tagsMode);
      }
      const res = await fetch(`${apiBase}/problems?${qs.toString()}`);
      const data = await res.json();
      const list = Array.isArray(data) ? data : [];
      setProblems(list);
      if (list.length > 0) setSelected(list[0]);
      else setSelected(null);
    } catch (err) {
      console.error('failed to load problems', err);
      setProblems([]);
      setSelected(null);
    }
  };

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Codeforces Web</h1>
          <p>Browse problems, open a statement to submit.</p>
        </div>
        <div className="pill">API: {apiBase}</div>
        <div className="nav-links">
          <Link href="/">Home</Link>
          <Link href="/submissions">My submissions</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/failed">Failed</Link>
        </div>
      </header>

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Problems</h2>
            <span className="muted">select to view</span>
          </div>
          <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start' }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="problem-list">
                {(problems || []).map((p) => (
                  <Link key={`${p.contest_id}-${p.index}`} href={`/contest/${p.contest_id}/problem/${p.index}`} className={`problem ${selected?.id === p.id ? 'active' : ''}`}>
                    <span className="label">
                      {p.contest_id}
                      {p.index}
                    </span>
                    <span>
                      {p.title}
                      <div className="muted" style={{ fontSize: '0.85em', marginTop: 2 }}>
                        {p.rating > 0 ? `rating ${p.rating}` : 'rating —'}
                        {Array.isArray(p.tags) && p.tags.length > 0 && (
                          <>
                            {' '}• tags: {p.tags.slice(0, 4).join(', ')}{p.tags.length > 4 ? '…' : ''}
                          </>
                        )}
                      </div>
                    </span>
                  </Link>
                ))}
                {problems.length === 0 && <div className="muted">No problems available.</div>}
              </div>
              <div className="pagination">
                <button onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0}>
                  Prev
                </button>
                <span className="muted">Page {page + 1}</span>
                <button onClick={() => setPage((p) => p + 1)}>Next</button>
              </div>
            </div>
            <aside style={{ width: 300 }}>
              <div className="muted" style={{ marginBottom: 4 }}>Filter by tags</div>
              <div className="tag-filter-list" style={{ marginBottom: 12 }}>
                {allTags.length === 0 && <div className="muted">No tags available</div>}
                {allTags.map((t) => (
                  <label key={t} className="tag-filter-item">
                    <input
                      type="checkbox"
                      checked={selectedTags.includes(t)}
                      onChange={(e) => {
                        const on = e.target.checked;
                        setPage(0);
                        setSelectedTags((prev) => (on ? [...prev, t] : prev.filter((x) => x !== t)));
                      }}
                    />
                    <span>{t}</span>
                  </label>
                ))}
              </div>
              <div>
                <div className="muted" style={{ marginBottom: 4 }}>Match</div>
                <select value={tagsMode} onChange={(e) => { setTagsMode(e.target.value); setPage(0); }}>
                  <option value="any">Any</option>
                  <option value="all">All</option>
                </select>
              </div>
            </aside>
          </div>
        </div>
      </section>
    </main>
  );
}
