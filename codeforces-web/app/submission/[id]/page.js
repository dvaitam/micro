'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

export default function SubmissionFixPage({ params }) {
  const subId = params.id;
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    const load = async () => {
      setLoading(true);
      setError('');
      try {
        const res = await fetch(`${apiBase}/submissions?id=${subId}`, { cache: 'no-store' });
        if (!res.ok) throw new Error(`Failed to load submission (${res.status})`);
        const d = await res.json();
        setData(d);
      } catch (err) {
        setError(err.message || 'Failed to load submission');
      } finally {
        setLoading(false);
      }
    };
    load();
  }, [subId]);

  const copy = async (text) => {
    try {
      await navigator.clipboard.writeText(text || '');
      alert('Copied');
    } catch {
      alert('Copy failed');
    }
  };

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Submission #{subId}</h1>
          <p className="muted">Use code/output as a starting point to retry.</p>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/submissions">My submissions</Link>
        </div>
      </header>

      {loading && <div className="muted">Loading…</div>}
      {error && <div className="notice error">{error}</div>}

      {data && (
        <section className="grid">
          <div className="card">
            <div className="card-header">
              <h2>Metadata</h2>
            </div>
            <div>
              Problem:{' '}
              <Link href={`/contest/${data.contest_id}/problem/${data.index}`}>
                {data.contest_id}
                {data.index}
              </Link>
            </div>
            <div>
              Status: {data.status} {data.verdict && `- ${data.verdict}`}
            </div>
            <div>Lang: {data.lang}</div>
            <div className="muted">{data.timestamp}</div>
          </div>

          <div className="card">
            <div className="card-header">
              <h2>Code</h2>
              <button onClick={() => copy(data.code)}>Copy</button>
            </div>
            <pre className="code-block">{data.code || '(empty)'}</pre>
          </div>

          <div className="card">
            <div className="card-header">
              <h2>Stdout</h2>
              <button onClick={() => copy(data.stdout)}>Copy</button>
            </div>
            <pre className="code-block">{data.stdout || '(empty)'}</pre>
          </div>

          <div className="card">
            <div className="card-header">
              <h2>Stderr</h2>
              <button onClick={() => copy(data.stderr)}>Copy</button>
            </div>
            <pre className="code-block">{data.stderr || '(empty)'}</pre>
          </div>
        </section>
      )}
    </main>
  );
}
