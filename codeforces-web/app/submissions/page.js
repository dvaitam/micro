'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

export default function SubmissionsPage() {
  const [subs, setSubs] = useState([]);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(false);

  useEffect(() => { document.title = 'Recent Submissions | CF Web'; }, []);

  useEffect(() => {
    fetchSubs(page);
  }, [page]);

  const fetchSubs = async (pageNum = 0) => {
    const limit = 50;
    const offset = pageNum * limit;
    try {
      const res = await fetch(`${apiBase}/submissions?limit=${limit}&offset=${offset}`);
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
          <h1>Recent Submissions</h1>
          <p>All submissions across users.</p>
        </div>
      </header>

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Recent submissions</h2>
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
