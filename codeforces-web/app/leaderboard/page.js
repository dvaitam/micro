'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import ModelLogo from '../components/ModelLogo';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

export default function LeaderboardPage() {
  const [leaders, setLeaders] = useState([]);
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
    } catch (err) {
      setError(err.message || 'Failed to load leaderboard');
      setLeaders([]);
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
          <Link href="/submissions">Recent submissions</Link>
          <Link href="/my/submissions">My submissions</Link>
        </div>
      </header>

      {error && <div className="notice error">{error}</div>}

      <section style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
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
                </tr>
              </thead>
              <tbody>
                {leaders.map((l) => (
                  <tr key={l.run_id}>
                    <td><Link href={`/run/${encodeURIComponent(l.run_id)}`}>{l.run_id}</Link></td>
                    <td><ModelLogo model={l.model} /><Link href={`/model?name=${encodeURIComponent(l.model)}`}>{l.model}</Link></td>
                    <td>{l.lang}</td>
                    <td>{l.rating}</td>
                    <td className="muted">{l.timestamp}</td>
                  </tr>
                ))}
                {leaders.length === 0 && !loading && (
                  <tr>
                    <td colSpan={5} className="muted">
                      No leaderboard entries.
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
