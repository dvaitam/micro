'use client';

import Link from 'next/link';
import { Suspense, useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'next/navigation';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

function extractCodeBlock(text) {
  if (!text) return '';
  const match = text.match(/```(?:[\w.+-]*\n)?([\s\S]*?)```/m);
  if (match) return match[1].trim();
  return text.trim();
}

function stripComments(code) {
  if (!code) return '';
  let cleaned = code.replace(/\/\*[\s\S]*?\*\//g, '');
  cleaned = cleaned.replace(/(^|\s)#.*$/gm, '$1');
  cleaned = cleaned.replace(/\/\/.*$/gm, '');
  cleaned = cleaned.replace(/--.*$/gm, '');
  return cleaned.trim();
}

function cleanedResponse(response) {
  const code = extractCodeBlock(response || '');
  return stripComments(code);
}

function ModelView() {
  const searchParams = useSearchParams();
  const name = searchParams.get('name') || '';

  const [evals, setEvals] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [copiedId, setCopiedId] = useState(null);

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

  const copyCleaned = async (resText, id) => {
    const snippet = cleanedResponse(resText);
    try {
      await navigator.clipboard.writeText(snippet);
      setCopiedId(id);
      setTimeout(() => setCopiedId(null), 1500);
    } catch (err) {
      console.error('copy failed', err);
    }
  };

  const title = useMemo(() => (name ? `Model: ${name}` : 'Model view'), [name]);

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>{title}</h1>
          <p className="muted">Recent evaluations for the selected model.</p>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/submissions">My submissions</Link>
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
                  <th>Lang</th>
                  <th>Success</th>
                  <th>Timestamp</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {evals.map((e) => (
                  <tr key={e.id}>
                    <td>#{e.id}</td>
                    <td>{e.run_id || '—'}</td>
                    <td>
                      <Link href={`/contest/${e.contest_id}/problem/${e.index}`}>
                        {e.contest_id}
                        {e.index}
                      </Link>
                    </td>
                    <td>{e.lang}</td>
                    <td>{e.success ? 'yes' : 'no'}</td>
                    <td className="muted">{e.timestamp}</td>
                    <td className="row gap-8">
                      <Link href={`/evaluation/${e.id}/fix`}>Fix prompt</Link>
                      <button onClick={() => copyCleaned(e.response, e.id)}>
                        {copiedId === e.id ? 'Copied' : 'Cleaned up response'}
                      </button>
                    </td>
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
