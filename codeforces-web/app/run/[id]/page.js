'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import ModelLogo from '../../components/ModelLogo';

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
  cleaned = cleaned.replace(/\/\/.*$/gm, '');
  return cleaned.trim();
}

function cleanedResponse(response) {
  const code = extractCodeBlock(response || '');
  return stripComments(code);
}

export default function RunPage({ params }) {
  const runId = decodeURIComponent(params.id);
  const [evals, setEvals] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [copiedId, setCopiedId] = useState(null);

  useEffect(() => {
    loadRun();
  }, [runId]);

  const loadRun = async () => {
    setLoading(true);
    setError('');
    try {
      const res = await fetch(`${apiBase}/leaderboard?run=${encodeURIComponent(runId)}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`Failed to load run (${res.status})`);
      const data = await res.json();
      setEvals(Array.isArray(data?.evals) ? data.evals : []);
    } catch (err) {
      setError(err.message || 'Failed to load run');
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

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Run: {runId}</h1>
          <p className="muted">Evaluations for this run.</p>
        </div>
        <div className="nav-links">
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/">Problems</Link>
          <Link href="/submissions">Recent submissions</Link>
          <Link href="/my/submissions">My submissions</Link>
        </div>
      </header>

      {error && <div className="notice error">{error}</div>}

      <section style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div className="card">
          <div className="card-header">
            <h2>Evaluations</h2>
            {loading && <span className="muted">Loading…</span>}
          </div>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Model</th>
                  <th>Lang</th>
                  <th>Problem</th>
                  <th>Rating</th>
                  <th>Success</th>
                  <th>Timestamp</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {evals.map((e) => (
                  <tr key={e.id}>
                    <td><Link href={`/evaluation/${e.id}/fix`}>#{e.id}</Link></td>
                    <td><ModelLogo model={e.model} /><Link href={`/model?name=${encodeURIComponent(e.model)}`}>{e.model}</Link></td>
                    <td>{e.lang}</td>
                    <td>
                      <Link href={`/contest/${e.contest_id}/problem/${e.index}`}>
                        {e.contest_id}
                        {e.index}
                      </Link>
                    </td>
                    <td>{e.rating && e.rating > 0 ? e.rating : '—'}</td>
                    <td>{e.success ? 'yes' : 'no'}</td>
                    <td className="muted">{e.timestamp}</td>
                    <td className="row gap-8">
                      <button onClick={() => copyCleaned(e.response, e.id)}>
                        {copiedId === e.id ? 'Copied' : 'Cleaned up response'}
                      </button>
                    </td>
                  </tr>
                ))}
                {evals.length === 0 && !loading && (
                  <tr>
                    <td colSpan={8} className="muted">
                      No evaluations found for this run.
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
