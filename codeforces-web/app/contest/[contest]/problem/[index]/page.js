'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

export default function ProblemPage({ params }) {
  const contest = params.contest;
  const index = params.index;
  const [problem, setProblem] = useState(null);
  const [email, setEmail] = useState('');
  const [otp, setOtp] = useState('');
  const [stayLoggedIn, setStayLoggedIn] = useState(false);
  const [token, setToken] = useState('');
  const [userEmail, setUserEmail] = useState('');
  const [authMsg, setAuthMsg] = useState(null);
  const [mySubs, setMySubs] = useState([]);
  const [subsLoading, setSubsLoading] = useState(false);
  const [subsError, setSubsError] = useState('');
  const [allSubs, setAllSubs] = useState([]);
  const [allSubsLoading, setAllSubsLoading] = useState(false);
  const [allSubsError, setAllSubsError] = useState('');
  const [selectedSub, setSelectedSub] = useState(null);
  const [selectedLoading, setSelectedLoading] = useState(false);
  const [selectedError, setSelectedError] = useState('');
  const [evals, setEvals] = useState([]);
  const [evalsLoading, setEvalsLoading] = useState(false);
  const [evalsError, setEvalsError] = useState('');
  const [leaders, setLeaders] = useState([]);
  const [leadersLoading, setLeadersLoading] = useState(false);
  const [leadersError, setLeadersError] = useState('');
  const router = useRouter();

  useEffect(() => {
    const saved = typeof window !== 'undefined' ? localStorage.getItem('cf_token') : '';
    const savedEmail = typeof window !== 'undefined' ? localStorage.getItem('cf_email') : '';
    if (saved) {
      setToken(saved);
      // Verify session validity
      fetch(`${apiBase}/me/submissions?limit=1`, {
        headers: { Authorization: `Bearer ${saved}` }
      }).then(async (res) => {
        if (res.status === 401) {
          // Try refreshing
          const refreshed = await refreshSession();
          if (!refreshed) {
             handleLogout();
          }
        }
      }).catch(() => {});
    }
    if (savedEmail) setUserEmail(savedEmail);
  }, []);

  useEffect(() => {
    loadProblem();
    loadAllSubs();
    loadEvals();
    loadLeaders();
    loadMySubs(token);
    setSelectedSub(null);
  }, [contest, index, token]);

  const loadProblem = async () => {
    try {
      const res = await fetch(`${apiBase}/problems/${contest}/${index}`);
      if (!res.ok) return;
      const data = await res.json();
      setProblem(data);
    } catch (err) {
      console.error('failed to load problem', err);
      setProblem(null);
    }
  };

  const loadEvals = async () => {
    setEvalsLoading(true);
    setEvalsError('');
    try {
      const res = await fetch(`${apiBase}/evaluations?contest=${contest}&index=${index}`, { cache: 'no-store' });
      if (!res.ok) {
        throw new Error(`Failed to load evaluations (${res.status})`);
      }
      const data = await res.json();
      setEvals(Array.isArray(data) ? data : []);
    } catch (err) {
      setEvalsError(err.message || 'Failed to load evaluations');
      setEvals([]);
    } finally {
      setEvalsLoading(false);
    }
  };

  const loadLeaders = async () => {
    setLeadersLoading(true);
    setLeadersError('');
    try {
      const res = await fetch(`${apiBase}/leaderboard`, { cache: 'no-store' });
      if (!res.ok) {
        throw new Error(`Failed to load leaderboard (${res.status})`);
      }
      const data = await res.json();
      setLeaders(Array.isArray(data?.leaders) ? data.leaders : []);
    } catch (err) {
      setLeadersError(err.message || 'Failed to load leaderboard');
      setLeaders([]);
    } finally {
      setLeadersLoading(false);
    }
  };

  const requestOtp = async () => {
    setAuthMsg(null);
    try {
      const res = await fetch(`${apiBase}/auth/request-otp`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data?.error || 'failed to send code');
      }
      setAuthMsg({ type: 'success', text: 'OTP sent to your email' });
    } catch (err) {
      setAuthMsg({ type: 'error', text: err.message });
    }
  };

  const verifyOtp = async () => {
    setAuthMsg(null);
    try {
      const res = await fetch(`${apiBase}/auth/verify-otp`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, code: otp, stay_logged_in: stayLoggedIn }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || 'verification failed');
      
      // Support both old and new API responses
      const newToken = data.access_token || data.token;
      const refreshToken = data.refresh_token;

      setToken(newToken);
      setUserEmail(data.email || email);
      
      if (typeof window !== 'undefined') {
        localStorage.setItem('cf_token', newToken);
        localStorage.setItem('cf_email', data.email || email);
        if (refreshToken) {
          localStorage.setItem('cf_refresh_token', refreshToken);
        }
      }
      setAuthMsg({ type: 'success', text: 'Logged in' });
    } catch (err) {
      setAuthMsg({ type: 'error', text: err.message });
    }
  };

  const refreshSession = async () => {
    if (typeof window === 'undefined') return false;
    const rf = localStorage.getItem('cf_refresh_token');
    if (!rf) return false;

    try {
      const res = await fetch(`${apiBase}/auth/refresh`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: rf }),
      });
      if (res.ok) {
        const data = await res.json();
        setToken(data.access_token);
        localStorage.setItem('cf_token', data.access_token);
        return true;
      }
    } catch (e) {
      console.error("Refresh failed", e);
    }
    return false;
  };

  const handleLogout = () => {
    setToken('');
    setUserEmail('');
    setEmail('');
    setOtp('');
    if (typeof window !== 'undefined') {
      localStorage.removeItem('cf_token');
      localStorage.removeItem('cf_email');
      localStorage.removeItem('cf_refresh_token');
    }
    setAuthMsg({ type: 'info', text: 'Logged out' });
  };

  const loadMySubs = async (authToken) => {
    if (!authToken) {
      setMySubs([]);
      return;
    }
    setSubsLoading(true);
    setSubsError('');
    try {
      const res = await fetch(`${apiBase}/me/submissions?limit=100`, {
        headers: { Authorization: `Bearer ${authToken}` },
        cache: 'no-store',
      });
      if (!res.ok) {
        throw new Error(`Failed to load submissions (${res.status})`);
      }
      const data = await res.json();
      const filtered = (data || []).filter(
        (s) => String(s.contest_id) === String(contest) && String(s.index) === String(index)
      );
      setMySubs(filtered);
    } catch (err) {
      setSubsError(err.message || 'Failed to load submissions');
    } finally {
      setSubsLoading(false);
    }
  };

  const loadAllSubs = async () => {
    setAllSubsLoading(true);
    setAllSubsError('');
    try {
      const res = await fetch(`${apiBase}/submissions?contest=${contest}&index=${index}&limit=100`, {
        cache: 'no-store',
      });
      if (!res.ok) {
        throw new Error(`Failed to load submissions (${res.status})`);
      }
      const data = await res.json();
      setAllSubs(data || []);
    } catch (err) {
      setAllSubsError(err.message || 'Failed to load submissions');
    } finally {
      setAllSubsLoading(false);
    }
  };

  const goToSubmit = (payload) => {
    if (typeof window === 'undefined') return;
    localStorage.setItem('cf_prefill', JSON.stringify(payload));
    router.push(`/contest/${contest}/problem/${index}/submit`);
  };

  const loadSubmissionForSubmit = (sub) => {
    if (!sub?.code) return;
    goToSubmit({
      contest: String(contest),
      index: String(index),
      code: sub.code,
      lang: sub.lang || 'go',
    });
  };

  const loadEvaluationForSubmit = async (id, fallbackLang) => {
    try {
      const res = await fetch(`${apiBase}/evaluations?id=${id}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`Failed to load evaluation (${res.status})`);
      const data = await res.json();
      goToSubmit({
        contest: String(contest),
        index: String(index),
        code: data.response || '',
        lang: data.lang || fallbackLang || 'go',
      });
    } catch (err) {
      setEvalsError(err.message || 'Failed to load evaluation');
    }
  };

  const fetchSubmissionDetail = async (id) => {
    setSelectedLoading(true);
    setSelectedError('');
    try {
      const res = await fetch(`${apiBase}/submissions?id=${id}`, { cache: 'no-store' });
      if (!res.ok) {
        throw new Error(`Failed to load submission (${res.status})`);
      }
      const data = await res.json();
      setSelectedSub(data);
    } catch (err) {
      setSelectedError(err.message || 'Failed to load submission');
    } finally {
      setSelectedLoading(false);
    }
  };

  const loggedIn = !!token;
  const statementUrl = `https://cdn.manchik.co.uk/contest/${contest}/problem/${index}`;
  const submitUrl = `/contest/${contest}/problem/${index}/submit`;

  const ratingColor = (r) => {
    if (!r || r <= 0) return 'none';
    if (r < 1200) return 'gray';
    if (r < 1400) return 'green';
    if (r < 1600) return 'cyan';
    if (r < 1900) return 'blue';
    if (r < 2100) return 'violet';
    if (r < 2400) return 'orange';
    return 'red';
  };

  const verdictDot = (s) => {
    const v = (s.verdict || s.status || '').toLowerCase();
    if (v.includes('accepted') || v.includes('ok') || v === 'success') return 'accepted';
    if (v.includes('wrong') || v.includes('error') || v.includes('fail') || v.includes('time') || v.includes('runtime') || v.includes('memory')) return 'failed';
    if (v.includes('pending') || v.includes('running') || v.includes('queue')) return 'pending';
    return 'unknown';
  };

  return (
    <main className="page">
      <nav className="breadcrumb">
        <Link href="/">Home</Link>
        <span className="breadcrumb__sep">/</span>
        <Link href={`/contest/${contest}`}>Contest {contest}</Link>
        <span className="breadcrumb__sep">/</span>
        <span>Problem {index}</span>
      </nav>

      <header className="header">
        <div>
          <h1>
            {contest} {index}
            {problem?.title && <span className="header__title-name"> &mdash; {problem.title}</span>}
          </h1>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/submissions">Recent submissions</Link>
          <Link href="/my/submissions">My submissions</Link>
          {loggedIn && (
            <>
              <span className="muted">{userEmail || 'user'}</span>
              <button onClick={handleLogout}>Logout</button>
            </>
          )}
        </div>
      </header>

      <section className="problem-layout">
        {/* Left column: Statement */}
        <div className="problem-layout__main">
          <div className="card card--primary">
            <div className="card-header">
              <h2>Statement</h2>
              <a href={statementUrl} target="_blank" rel="noreferrer" className="muted">
                Open in new tab ↗
              </a>
            </div>
            <iframe
              className="statement-frame"
              src={statementUrl}
              title={`Statement ${contest}${index}`}
            />
          </div>
        </div>

        {/* Right column: Metadata + Login */}
        <div className="problem-layout__sidebar">
          <div className="card card--compact">
            <div className="card-header">
              <h2>Problem Info</h2>
            </div>
            <div className="meta-row">
              <span className="meta-label">Rating</span>
              <span className={`rating-badge rating-badge--${ratingColor(problem?.rating)}`}>
                {problem?.rating > 0 ? problem.rating : '---'}
              </span>
            </div>
            <div className="meta-row">
              <span className="meta-label">Tags</span>
              <div className="tag-pills">
                {Array.isArray(problem?.tags) && problem.tags.length > 0
                  ? problem.tags.map((t) => (
                      <span key={t} className="pill">{t}</span>
                    ))
                  : <span className="muted">None</span>
                }
              </div>
            </div>
            <div className="sidebar-actions">
              <Link href={submitUrl} className="btn btn--primary btn--block">
                Submit solution
              </Link>
              <Link
                href={`https://codeforces.com/contest/${contest}/problem/${index}`}
                target="_blank"
                rel="noreferrer"
                className="btn btn--outline btn--block"
              >
                View on Codeforces ↗
              </Link>
              <Link href={`/contest/${contest}/problem/${index}/reference`} className="btn btn--outline btn--block">
                Reference solution
              </Link>
            </div>
          </div>

          {!loggedIn && (
            <div className="card card--compact">
              <div className="card-header">
                <h2>Login</h2>
                <span className="muted">OTP via email</span>
              </div>
              <div className="form">
                <label>
                  Email
                  <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
                </label>
                <div className="row">
                  <button onClick={requestOtp} disabled={!email}>
                    Send OTP
                  </button>
                </div>
                <label>
                  Code
                  <input value={otp} onChange={(e) => setOtp(e.target.value)} placeholder="123456" />
                </label>
                <label className="row gap-8" style={{ justifyContent: 'flex-start', alignItems: 'center' }}>
                  <input
                    type="checkbox"
                    checked={stayLoggedIn}
                    onChange={(e) => setStayLoggedIn(e.target.checked)}
                    style={{ width: 'auto' }}
                  />
                  <span>Stay logged in</span>
                </label>
                <button className="primary" onClick={verifyOtp} disabled={!email || !otp}>
                  Verify &amp; Login
                </button>
                {authMsg && <div className={`notice ${authMsg.type}`}>{authMsg.text}</div>}
              </div>
            </div>
          )}
        </div>

        {/* Full-width: Evaluations */}
        <div className="problem-layout__full">
          <div className="card">
            <div className="card-header">
              <h2>Evaluations</h2>
              {evalsLoading && <span className="muted">Loading...</span>}
              <button onClick={loadEvals}>Refresh</button>
            </div>
            {evalsError && <div className="notice error">{evalsError}</div>}
            {!evalsLoading && !evalsError && evals.length === 0 && (
              <div className="muted">No evaluations recorded for this problem.</div>
            )}
            {evals.length > 0 && (
              <div className="table-wrap">
                <table className="table">
                  <thead>
                    <tr>
                      <th>ID</th>
                      <th className="hide-mobile">Run</th>
                      <th>Model</th>
                      <th>Lang</th>
                      <th>Success</th>
                      <th className="hide-mobile">Timestamp</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {evals.map((e) => (
                      <tr key={e.id}>
                        <td>
                          <Link href={`/evaluation/${e.id}/fix`}>#{e.id}</Link>
                        </td>
                        <td className="hide-mobile">{e.run_id || '—'}</td>
                        <td>{e.model}</td>
                        <td>{e.lang}</td>
                        <td>
                          <span
                            className={`status-dot ${e.success ? 'status-dot--accepted' : 'status-dot--failed'}`}
                            style={{ verticalAlign: 'middle', marginRight: 6 }}
                          />
                          {e.success ? 'Passed' : 'Failed'}
                        </td>
                        <td className="hide-mobile muted">{e.timestamp}</td>
                        <td className="row gap-8">
                          <button className="primary" onClick={() => loadEvaluationForSubmit(e.id, e.lang)}>
                            Load &amp; retry
                          </button>
                          <Link href={`/evaluation/${e.id}/fix`}>Fix prompt</Link>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>

        {/* Full-width: My Submissions */}
        <div className="problem-layout__full">
          <div className="card">
            <div className="card-header">
              <h2>My Submissions</h2>
              {subsLoading && <span className="muted">Loading...</span>}
            </div>
            {subsError && <div className="notice error">{subsError}</div>}
            {!subsLoading && !subsError && mySubs.length === 0 && (
              <div className="muted">No submissions yet for this problem.</div>
            )}
            <ul className="list">
              {mySubs.map((s) => (
                <li key={s.id} className="submission-item">
                  <div className="submission-item__info">
                    <span className={`status-dot status-dot--${verdictDot(s)}`} title={s.verdict || s.status} />
                    <div>
                      <div>
                        <span className="label">#{s.id}</span>
                        <span className="muted" style={{ marginLeft: 8 }}>{s.lang}</span>
                      </div>
                      <div style={{ marginTop: 2 }}>
                        <span>{s.status}</span>
                        {s.verdict && <span className="muted"> &mdash; {s.verdict}</span>}
                        {s.exit_code !== undefined && <span className="muted"> (exit {s.exit_code})</span>}
                      </div>
                      <div className="muted" style={{ fontSize: 12 }}>{s.timestamp}</div>
                    </div>
                  </div>
                  <div className="submission-item__actions">
                    <button onClick={() => loadSubmissionForSubmit(s)}>Load &amp; Retry</button>
                  </div>
                </li>
              ))}
            </ul>
          </div>
        </div>

        {/* Full-width: All Submissions (with inline selected detail) */}
        <div className="problem-layout__full">
          <div className="card">
            <div className="card-header">
              <h2>All Submissions</h2>
              {allSubsLoading && <span className="muted">Loading...</span>}
            </div>

            {selectedSub && (
              <div className="selected-detail">
                <div className="selected-detail__header">
                  <h3>Submission #{selectedSub.id}</h3>
                  <button className="btn--close" onClick={() => setSelectedSub(null)} title="Close">&times;</button>
                </div>
                {selectedLoading && <span className="muted">Loading...</span>}
                {selectedError && <div className="notice error">{selectedError}</div>}
                <div className="selected-detail__meta">
                  <span className={`status-dot status-dot--${verdictDot(selectedSub)}`} />
                  <span>Status: {selectedSub.status}</span>
                  <span className="muted">|</span>
                  <span>Verdict: {selectedSub.verdict || '—'}</span>
                  <span className="muted">|</span>
                  <span>Lang: {selectedSub.lang || 'unknown'}</span>
                  <span className="muted">{selectedSub.timestamp}</span>
                </div>
                <div className="row gap-8" style={{ marginTop: 8 }}>
                  <button onClick={() => loadSubmissionForSubmit(selectedSub)}>Load &amp; Retry</button>
                </div>
                <details open>
                  <summary>Code</summary>
                  <pre className="code-block">{selectedSub.code || '(empty)'}</pre>
                </details>
                <details>
                  <summary>Stdout</summary>
                  <pre className="code-block">{selectedSub.stdout || '(empty)'}</pre>
                </details>
                <details>
                  <summary>Stderr</summary>
                  <pre className="code-block">{selectedSub.stderr || '(empty)'}</pre>
                </details>
                <details>
                  <summary>Response</summary>
                  <pre className="code-block">{selectedSub.response || '(empty)'}</pre>
                </details>
              </div>
            )}

            {allSubsError && <div className="notice error">{allSubsError}</div>}
            {!allSubsLoading && !allSubsError && allSubs.length === 0 && (
              <div className="muted">No submissions yet for this problem.</div>
            )}
            <ul className="list">
              {allSubs.map((s) => (
                <li key={s.id} className={`submission-item${selectedSub?.id === s.id ? ' submission-item--active' : ''}`}>
                  <div className="submission-item__info">
                    <span className={`status-dot status-dot--${verdictDot(s)}`} title={s.verdict || s.status} />
                    <div>
                      <div>
                        <button className="link" onClick={() => fetchSubmissionDetail(s.id)} style={{ padding: 0, border: 'none', background: 'none', boxShadow: 'none', cursor: 'pointer' }}>
                          <span className="label">#{s.id}</span>
                        </button>
                        <span className="muted" style={{ marginLeft: 8 }}>{s.lang}</span>
                      </div>
                      <div style={{ marginTop: 2 }}>
                        <span>{s.status}</span>
                        {s.verdict && <span className="muted"> &mdash; {s.verdict}</span>}
                        {s.exit_code !== undefined && <span className="muted"> (exit {s.exit_code})</span>}
                      </div>
                      <div className="muted" style={{ fontSize: 12 }}>{s.timestamp}</div>
                    </div>
                  </div>
                  <div className="submission-item__actions">
                    <button onClick={() => fetchSubmissionDetail(s.id)}>View</button>
                    <Link href={`/submission/${s.id}/fix`}>Fix prompt</Link>
                  </div>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </section>
    </main>
  );
}
