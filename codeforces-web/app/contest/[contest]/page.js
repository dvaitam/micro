'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

export default function ContestListing({ params }) {
  const contest = params.contest;
  const [problems, setProblems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      setLoading(true);
      setError('');
      try {
        const res = await fetch(`${apiBase}/problems?contest=${contest}`);
        if (!res.ok) {
          throw new Error(`Failed to load problems (${res.status})`);
        }
        const data = await res.json();
        if (!cancelled) setProblems(data || []);
      } catch (err) {
        if (!cancelled) setError(err.message || 'Failed to load problems');
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    load();
    return () => {
      cancelled = true;
    };
  }, [contest]);

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Contest {contest}</h1>
          <p className="muted">Problems available for this contest</p>
        </div>
        <Link className="muted" href="/submissions">
          My submissions
        </Link>
      </header>

      <section className="card">
        <div className="card-header">
          <h2>Problems</h2>
          {loading && <span className="muted">Loading…</span>}
        </div>
        {error && <div className="notice error">{error}</div>}
        {!loading && !error && problems.length === 0 && <div className="muted">No problems found.</div>}
        <ul className="list">
          {problems.map((p) => (
            <li key={`${p.contest_id}-${p.index}`} className="row space-between">
              <Link href={`/contest/${p.contest_id}/problem/${p.index}`} className="row gap-8" style={{ textDecoration: 'none', color: 'inherit' }}>
                <div className="label">
                  {p.contest_id}
                  {p.index}
                </div>
                <div>
                  <div>{p.title || 'Untitled problem'}</div>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      </section>
    </main>
  );
}
