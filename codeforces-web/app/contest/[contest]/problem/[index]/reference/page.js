'use client';

import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

export default function ReferenceSolutionPage({ params }) {
  const contest = params.contest;
  const index = params.index;
  const [problem, setProblem] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [copyState, setCopyState] = useState('idle');
  const router = useRouter();

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      setLoading(true);
      setError('');
      try {
        const res = await fetch(`${apiBase}/problems/${contest}/${index}`);
        if (!res.ok) {
          throw new Error(`Failed to load problem (${res.status})`);
        }
        const data = await res.json();
        if (!cancelled) setProblem(data);
      } catch (err) {
        if (!cancelled) setError(err.message || 'Failed to load problem');
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    load();
    return () => {
      cancelled = true;
    };
  }, [contest, index]);

  const referenceSolution = useMemo(() => (problem?.reference_solution || '').trim(), [problem]);

  const copy = async () => {
    if (!referenceSolution) return;
    if (typeof navigator === 'undefined' || !navigator.clipboard) {
      setCopyState('error');
      return;
    }
    try {
      await navigator.clipboard.writeText(referenceSolution);
      setCopyState('copied');
      setTimeout(() => setCopyState('idle'), 1500);
    } catch {
      setCopyState('error');
    }
  };

  const loadIntoEditor = () => {
    if (typeof window === 'undefined' || !referenceSolution) return;
    const payload = {
      contest: String(contest),
      index: String(index),
      code: referenceSolution,
      lang: 'go',
    };
    localStorage.setItem('cf_prefill', JSON.stringify(payload));
    router.push(`/contest/${contest}/problem/${index}`);
  };

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>
            Reference solution {contest}
            {index}
          </h1>
          <p className="muted">{problem?.title || 'Problem'}</p>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/submissions">My submissions</Link>
        </div>
      </header>

      <section className="card">
        <div className="card-header">
          <h2>Reference solution</h2>
          {referenceSolution && (
            <div className="row gap-8">
              <button onClick={copy} className={copyState === 'copied' ? 'copied' : ''}>
                {copyState === 'copied' ? 'Copied' : 'Copy'}
              </button>
              <button onClick={loadIntoEditor}>Load into editor</button>
            </div>
          )}
        </div>
        {loading && <div className="muted">Loading…</div>}
        {error && <div className="notice error">{error}</div>}
        {!loading && !error && !referenceSolution && <div className="muted">No reference solution available.</div>}
        {referenceSolution && <pre className="code-block">{referenceSolution}</pre>}
      </section>
    </main>
  );
}
