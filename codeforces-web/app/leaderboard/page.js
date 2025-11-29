'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

export default function LeaderboardPage() {
  const [leaders, setLeaders] = useState([]);
  const [evals, setEvals] = useState([]);
  const [runFilter, setRunFilter] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    loadLeaders();
  }, []);

  const loadLeaders = async () => {
    setLoading(true);
    setError('');
    try {
      const res = await fetch(`${apiBase}/leaderboard`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`Failed to load leaderboard (${res.status})`);
      const data = await res.json();
      setLeaders(Array.isArray(data?.leaders) ? data.leaders : []);
      setEvals(Array.isArray(data?.evals) ? data.evals : []);
      setRunFilter(data?.run || '');
    } catch (err) {
      setError(err.message || 'Failed to load leaderboard');
      setLeaders([]);
      setEvals([]);
    } finally {
      setLoading(false);
    }
  };

  const loadRun = async (runId) => {
    setRunFilter(runId);
    setLoading(true);
    setError('');
    try {
      const res = await fetch(`${apiBase}/leaderboard?run=${encodeURIComponent(runId)}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`Failed to load run (${res.status})`);
      const data = await res.json();
      setEvals(Array.isArray(data?.evals) ? data.evals : []);
    } catch (err) {
      setError(err.message || 'Failed to load run history');
      setEvals([]);
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Leaderboard</h1>
          <p className="muted">Model runs ranked by rating.</p>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
          <Link href="/submissions">My submissions</Link>
        </div>
      </header>

      {error && <div className="notice error">{error}</div>}

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Top runs</h2>
            {loading && <span className="muted">Loading…</span>}
          </div>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Run ID</th>
                  <th>Model</th>
                  <th>Lang</th>
                  <th>Rating</th>
                  <th>Timestamp</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {leaders.map((l) => (
                  <tr key={l.run_id}>
                    <td>{l.run_id}</td>
                    <td>{l.model}</td>
                    <td>{l.lang}</td>
                    <td>{l.rating}</td>
                    <td className="muted">{l.timestamp}</td>
                    <td>
                      <button onClick={() => loadRun(l.run_id)}>View evals</button>
                    </td>
                  </tr>
                ))}
                {leaders.length === 0 && !loading && (
                  <tr>
                    <td colSpan={6} className="muted">
                      No leaderboard entries.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <h2>{runFilter ? `Evaluations for ${runFilter}` : 'Evaluation history'}</h2>
            {loading && <span className="muted">Loading…</span>}
          </div>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Run</th>
                  <th>Model</th>
                  <th>Lang</th>
                  <th>Problem</th>
                  <th>Success</th>
                  <th>Timestamp</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {evals.map((e) => (
                  <tr key={e.id}>
                    <td>#{e.id}</td>
                    <td>{e.run_id}</td>
                    <td>{e.model}</td>
                    <td>{e.lang}</td>
                    <td>
                      <Link href={`/contest/${e.contest_id}/problem/${e.index}`}>
                        {e.contest_id}
                        {e.index}
                      </Link>
                    </td>
                    <td>{e.success ? 'yes' : 'no'}</td>
                    <td className="muted">{e.timestamp}</td>
                    <td className="row gap-8">
                      <Link href={`/evaluation/${e.id}/fix`}>Fix prompt</Link>
                    </td>
                  </tr>
                ))}
                {evals.length === 0 && !loading && (
                  <tr>
                    <td colSpan={8} className="muted">
                      No evaluations yet.
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
