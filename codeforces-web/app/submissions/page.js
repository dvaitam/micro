'use client';

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';
const wsBase = process.env.NEXT_PUBLIC_WS_URL || 'wss://codeforces-api.manchik.co.uk/ws';

export default function SubmissionsPage() {
  const [token, setToken] = useState('');
  const [subs, setSubs] = useState([]);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(false);
  const socketRef = useRef(null);

  useEffect(() => {
    const saved = typeof window !== 'undefined' ? localStorage.getItem('cf_token') : '';
    if (saved) setToken(saved);
  }, []);

  useEffect(() => {
    if (token) fetchSubs(page);
    return () => {
      if (socketRef.current) socketRef.current.close();
    };
  }, [token, page]);

  const fetchSubs = async (pageNum = 0) => {
    const limit = 20;
    const offset = pageNum * limit;
    try {
      const res = await fetch(`${apiBase}/me/submissions?limit=${limit}&offset=${offset}`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (!res.ok) return;
      const data = await res.json();
      const list = Array.isArray(data) ? data : [];
      setSubs(list);
      setHasMore(list.length === limit);
    } catch (err) {
      console.error('failed to load submissions', err);
    }
  };

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>My Submissions</h1>
          <p>Live progress per test.</p>
        </div>
        <div className="nav-links">
          <Link href="/">Home</Link>
          <button onClick={() => fetchSubs(page)}>Refresh</button>
        </div>
      </header>

      {!token && <div className="notice error">Login on the home page to view your submissions.</div>}

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Submissions</h2>
            <span className="muted">page {page + 1}</span>
          </div>
          <table className="status-table">
            <thead>
              <tr>
                <th>Problem</th>
                <th>Submitted</th>
                <th>Status</th>
                <th>Verdict</th>
                <th>Output</th>
              </tr>
            </thead>
            <tbody>
              {(subs || []).map((s) => (
                <tr key={s.id}>
                  <td>
                    <div className="row space-between">
                      <Link className="label" href={`/contest/${s.contest_id}/problem/${s.index}`}>
                        {s.contest_id}
                        {s.index}
                      </Link>
                    </div>
                  </td>
                  <td>
                    <span className="muted">{s.timestamp}</span>
                  </td>
                  <td>{s.status}</td>
                  <td>{s.verdict ? s.verdict : <span className="muted">-</span>}</td>
                  <td>
                    <div className="output-cell">
                      {s.stdout && (
                        <details>
                          <summary className="muted">Stdout</summary>
                          <pre className="code-block">{s.stdout}</pre>
                        </details>
                      )}
                      {s.stderr && (
                        <details>
                          <summary className="muted">Stderr</summary>
                          <pre className="code-block">{s.stderr}</pre>
                        </details>
                      )}
                      {!s.stdout && !s.stderr && <span className="muted">No output</span>}
                    </div>
                  </td>
                </tr>
              ))}
              {subs.length === 0 && (
                <tr>
                  <td className="muted" colSpan={5}>
                    No submissions
                  </td>
                </tr>
              )}
            </tbody>
          </table>
          <div className="pagination">
            <button onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0}>
              Prev
            </button>
            <button onClick={() => setPage((p) => p + 1)} disabled={!hasMore}>
              Next
            </button>
          </div>
        </div>
      </section>
    </main>
  );
}
