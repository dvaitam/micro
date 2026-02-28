'use client';

import Link from 'next/link';
import { Suspense, useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import ModelLogo from '../components/ModelLogo';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

function ModelView() {
  const searchParams = useSearchParams();
  const name = searchParams.get('name') || '';

  const [evals, setEvals] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => { document.title = name ? `${name} | CF Web` : 'Model | CF Web'; }, [name]);

  useEffect(() => {
    if (name) loadModel(name);
  }, [name]);

  const loadModel = async (modelName) => {
    setLoading(true);
    setError('');
    try {
      const res = await fetch(`${apiBase}/model?name=${encodeURIComponent(modelName)}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`Failed to load model (${res.status})`);
      const data = await res.json();
      setEvals(Array.isArray(data?.evals) ? data.evals : []);
    } catch (err) {
      setError(err.message || 'Failed to load model');
      setEvals([]);
    } finally {
      setLoading(false);
    }
  };

  const title = useMemo(() => (name ? `Model: ${name}` : 'Model view'), [name]);

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1><ModelLogo model={name} />{title}</h1>
          <p className="muted">Recent evaluations for the selected model.</p>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/submissions">Recent submissions</Link>
          <Link href="/my/submissions">My submissions</Link>
          <Link href="/failed">Failed</Link>
          <a href="https://codeforces.com/" target="_blank" rel="noreferrer">
            Codeforces
          </a>
        </div>
      </header>

      {!name && <div className="notice">Provide a model name in the query (?name=)</div>}
      {error && <div className="notice error">{error}</div>}

      <section className="grid">
        <div className="card wide-card">
          <div className="card-header">
            <h2>Evaluations</h2>
            {loading && <span className="muted">Loading…</span>}
          </div>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Run</th>
                  <th>Problem</th>
                  <th>Rating</th>
                  <th>Lang</th>
                  <th>Success</th>
                  <th>Timestamp</th>
                </tr>
              </thead>
              <tbody>
                {evals.map((e) => (
                  <tr key={e.id}>
                    <td><Link href={`/evaluation/${e.id}/fix`}>#{e.id}</Link></td>
                    <td>{e.run_id || '—'}</td>
                    <td>
                      <Link href={`/contest/${e.contest_id}/problem/${e.index}`}>
                        {e.contest_id}
                        {e.index}
                      </Link>
                    </td>
                    <td>{e.rating && e.rating > 0 ? e.rating : '—'}</td>
                    <td>{e.lang}</td>
                    <td>{e.success ? 'yes' : 'no'}</td>
                    <td className="muted">{e.timestamp}</td>
                  </tr>
                ))}
                {evals.length === 0 && !loading && (
                  <tr>
                    <td colSpan={7} className="muted">
                      No evaluations for this model.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </main>
  );
}
export default function ModelPage() {
  return (
    <Suspense
      fallback={(
        <main className="page">
          <header className="header">
            <h1>Model view</h1>
          </header>
          <div className="notice">Loading model details…</div>
        </main>
      )}
    >
      <ModelView />
    </Suspense>
  );
}
