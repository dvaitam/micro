'use client';

import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

function formatLocalPaths(contestId, index) {
  const c = parseInt(contestId, 10);
  if (Number.isNaN(c)) return { stmt: `${contestId}${index}`, verifier: 'verifier not found' };
  const idx = (index || '').toUpperCase();
  const top = Math.floor(c / 1000) * 1000;
  const second = Math.floor(c / 100) * 100;
  const third = Math.floor(c / 10) * 10;
  const topSeg = `${top}-${top + 999}`;
  const secondSeg = `${second}-${second + 99}`;
  const thirdSeg = `${third}-${third + 9}`;
  const contestSeg = `${c}`;
  const base = `${topSeg}/${secondSeg}/${thirdSeg}/${contestSeg}`;
  return {
    stmt: `${base}/problem${idx}.txt`,
    verifier: `${base}/verifier${idx}.go`,
  };
}

export default function SubmissionFixPage({ params }) {
  const subId = params.id;
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);

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
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      setCopied(false);
    }
  };

  const fixPrompt = useMemo(() => {
    if (!data) return '';
    const paths = formatLocalPaths(data.contest_id, data.index);
    const endingText = `${data.stdout || ''}\n${data.stderr || ''}`.trim() || '(no output)';
    return `For problem statement at ${paths.stmt} this is a correct solution, but verifier at ${paths.verifier} ends with ${endingText} can you fix the verifier? ${data.code || '(empty)'}`;
  }, [data]);

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
              <h2>Fix prompt</h2>
              <button onClick={() => copy(fixPrompt)} className={copied ? 'copied' : ''}>
                {copied ? 'Copied' : 'Copy'}
              </button>
            </div>
            <pre className="code-block" style={{ whiteSpace: 'pre-wrap' }}>
              {fixPrompt}
            </pre>
          </div>

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
            <div className="row gap-8" style={{ marginTop: 8 }}>
              <button onClick={() => copy(data.code)}>Copy code</button>
              <button onClick={() => copy(data.stdout)}>Copy stdout</button>
              <button onClick={() => copy(data.stderr)}>Copy stderr</button>
            </div>
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
