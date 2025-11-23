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

  useEffect(() => {
    fetchProblems();
  }, [page]);

  const fetchProblems = async () => {
    const offset = page * pageSize;
    try {
      const res = await fetch(`${apiBase}/problems?limit=${pageSize}&offset=${offset}`);
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
        </div>
      </header>

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Problems</h2>
            <span className="muted">select to view</span>
          </div>
          <div className="problem-list">
            {(problems || []).map((p) => (
              <Link key={`${p.contest_id}-${p.index}`} href={`/contest/${p.contest_id}/problem/${p.index}`} className={`problem ${selected?.id === p.id ? 'active' : ''}`}>
                <span className="label">
                  {p.contest_id}
                  {p.index}
                </span>
                <span>{p.title}</span>
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

      </section>
    </main>
  );
}
