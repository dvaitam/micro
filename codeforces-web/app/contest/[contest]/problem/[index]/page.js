'use client';

import Link from 'next/link';
import { useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';
const wsBase = process.env.NEXT_PUBLIC_WS_URL || 'wss://codeforces-api.manchik.co.uk/ws';

export default function ProblemPage({ params }) {
  const contest = params.contest;
  const index = params.index;
  const [problem, setProblem] = useState(null);
  const [code, setCode] = useState('');
  const [lang, setLang] = useState('go');
  const [statusLog, setStatusLog] = useState([]);
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
  const socketRef = useRef(null);
  const prefillRef = useRef(false);

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
    return () => {
      if (socketRef.current) socketRef.current.close();
    };
  }, [contest, index, token]);

  // Load any prefill code dropped by the reference solution page.
  useEffect(() => {
    if (prefillRef.current) return;
    if (typeof window === 'undefined') return;
    const raw = localStorage.getItem('cf_prefill');
    if (!raw) return;
    try {
      const payload = JSON.parse(raw);
      if (payload.contest === String(contest) && payload.index === String(index)) {
        if (payload.code) setCode(payload.code);
        if (payload.lang) setLang(payload.lang);
        setStatusLog((prev) => [
          { ts: new Date().toISOString(), status: 'info', detail: 'Loaded prefill into editor' },
          ...prev,
        ]);
      }
    } catch {
      // ignore bad payload
    } finally {
      localStorage.removeItem('cf_prefill');
      prefillRef.current = true;
    }
  }, [contest, index]);

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

  const handleSubmit = async () => {
    if (!problem || !token) {
      setStatusLog((prev) => [...prev, { ts: new Date().toISOString(), status: 'error', detail: 'Login required' }]);
      return;
    }

    const doSubmit = async (authToken) => {
      return fetch(`${apiBase}/submissions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${authToken}`,
        },
        body: JSON.stringify({
          contest_id: problem.contest_id,
          index: problem.index,
          lang,
          code,
        }),
      });
    };

    try {
      let res = await doSubmit(token);

      if (res.status === 401) {
        // Attempt refresh
        const refreshed = await refreshSession();
        if (refreshed) {
           // Retry with new token (state update might lag, so fetch from storage or variable)
           // setToken updates state asynchronously, so we rely on what we just put in localStorage or the fact we know it succeeded
           const newToken = localStorage.getItem('cf_token'); 
           res = await doSubmit(newToken);
        } else {
           handleLogout();
           throw new Error('Session expired. Please login again.');
        }
      }

      const data = await res.json();
      if (!res.ok) {
        throw new Error(data?.error || 'submission failed');
      }
      setStatusLog([{ ts: new Date().toISOString(), status: data.status, detail: `Submission #${data.submission_id}` }]);
      // Redirect to submissions page to watch live status.
      router.push('/submissions');
      // Refresh submissions for this problem.
      loadMySubs(token);
      loadAllSubs();
    } catch (err) {
      setStatusLog((prev) => [...prev, { ts: new Date().toISOString(), status: 'error', detail: err.message }]);
    }
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

  const loadSubmissionIntoEditor = (sub) => {
    if (!sub?.code) return;
    setCode(sub.code);
    if (sub.lang) setLang(sub.lang);
    setStatusLog((prev) => [
      { ts: new Date().toISOString(), status: 'info', detail: `Loaded submission #${sub.id} into editor` },
      ...prev,
    ]);
  };

  const loadEvaluationIntoEditor = async (id, fallbackLang) => {
    try {
      const res = await fetch(`${apiBase}/evaluations?id=${id}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`Failed to load evaluation (${res.status})`);
      const data = await res.json();
      if (data.response) setCode(data.response);
      if (data.lang || fallbackLang) setLang(data.lang || fallbackLang);
      setStatusLog((prev) => [
        { ts: new Date().toISOString(), status: 'info', detail: `Loaded evaluation #${id} into editor` },
        ...prev,
      ]);
    } catch (err) {
      setStatusLog((prev) => [
        { ts: new Date().toISOString(), status: 'error', detail: err.message || 'Failed to load evaluation' },
        ...prev,
      ]);
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

  const statement = useMemo(() => (problem ? problem.statement || '' : ''), [problem]);
  const loggedIn = !!token;

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>
            {contest}
            {index}
          </h1>
          <div className="row gap-8">
            <p>{problem?.title || 'Problem'}</p>
            <Link
              href={`https://codeforces.com/contest/${contest}/problem/${index}`}
              target="_blank"
              rel="noreferrer"
              className="muted"
            >
              View on Codeforces.com ↗
            </Link>
            <Link href={`/contest/${contest}/problem/${index}/reference`} className="muted">
              Reference solution ↗
            </Link>
          </div>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <Link href="/submissions">My submissions</Link>
          {loggedIn && (
            <>
              <span className="muted">{userEmail || 'user'}</span>
              <button onClick={handleLogout}>Logout</button>
            </>
          )}
        </div>
      </header>

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Statement</h2>
            <span className="muted">
              {contest}
              {index}
            </span>
          </div>
          <pre className="statement">{statement}</pre>
        </div>

        {!loggedIn && (
          <div className="card">
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
                Verify & Login
              </button>
              {authMsg && <div className={`notice ${authMsg.type}`}>{authMsg.text}</div>}
            </div>
          </div>
        )}

        <div className="card">
          <div className="card-header">
            <h2>Submit</h2>
            <span className="muted">requires login</span>
          </div>
          <div className="form">
            <label>
              Language
              <select value={lang} onChange={(e) => setLang(e.target.value)}>
                <option value="go">Go</option>
                <option value="cpp">C++</option>
                <option value="py">Python</option>
                <option value="rs">Rust</option>
              </select>
            </label>
            <label>
              Code
              <textarea value={code} onChange={(e) => setCode(e.target.value)} placeholder="Paste your solution here..." rows={12} />
            </label>
            <button className="primary" onClick={handleSubmit} disabled={!problem || !code || !token}>
              Submit & View status
            </button>
            <ul className="status">
              {(statusLog || []).map((s, idx) => (
                <li key={idx}>
                  <span className="label">{s.status}</span>
                  <span className="muted">{s.ts}</span>
                  <div>{s.detail}</div>
                </li>
              ))}
            </ul>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <h2>{`All submissions for ${contest}${index}`}</h2>
            {allSubsLoading && <span className="muted">Loading…</span>}
          </div>
          {allSubsError && <div className="notice error">{allSubsError}</div>}
          {!allSubsLoading && !allSubsError && allSubs.length === 0 && (
            <div className="muted">No submissions yet for this problem.</div>
          )}
          <ul className="list">
            {allSubs.map((s) => (
              <li key={s.id} className="row space-between">
                <div>
                  <button className="link" onClick={() => fetchSubmissionDetail(s.id)} style={{ padding: 0, border: 'none', background: 'none', cursor: 'pointer' }}>
                    <div className="label">#{s.id}</div>
                  </button>
                  <div className="muted">{s.timestamp}</div>
                  <div>
                    {s.status} {s.verdict && `- ${s.verdict}`} {s.exit_code !== undefined && `(exit ${s.exit_code})`}
                  </div>
                  <div className="muted">{s.lang}</div>
                </div>
                <div className="row gap-8">
                  <button onClick={() => fetchSubmissionDetail(s.id)}>View</button>
                  <Link href={`/submission/${s.id}/fix`}>Fix prompt</Link>
                </div>
              </li>
            ))}
          </ul>
        </div>

        <div className="card wide-card">
          <div className="card-header">
            <h2>{`Evaluations for ${contest}${index}`}</h2>
            {evalsLoading && <span className="muted">Loading…</span>}
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
                    <th>Run</th>
                    <th>Model</th>
                    <th>Lang</th>
                    <th>Success</th>
                    <th>Timestamp</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {evals.map((e) => (
                    <tr key={e.id}>
                      <td>
                        <Link href={`/evaluation/${e.id}/fix`}>#{e.id}</Link>
                      </td>
                      <td>{e.run_id || '—'}</td>
                      <td>{e.model}</td>
                      <td>{e.lang}</td>
                      <td>{e.success ? 'yes' : 'no'}</td>
                      <td className="muted">{e.timestamp}</td>
                      <td className="row gap-8">
                        <button className="primary" onClick={() => loadEvaluationIntoEditor(e.id, e.lang)}>
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

        <div className="card">
            <div className="card-header">
              <h2>{`My submissions for ${contest}${index}`}</h2>
              {subsLoading && <span className="muted">Loading…</span>}
            </div>
          {subsError && <div className="notice error">{subsError}</div>}
          {!subsLoading && !subsError && mySubs.length === 0 && (
            <div className="muted">No submissions yet for this problem.</div>
          )}
          <ul className="list">
            {mySubs.map((s) => (
              <li key={s.id} className="row space-between">
                <div>
                  <div className="label">#{s.id}</div>
                  <div className="muted">{s.timestamp}</div>
                  <div>
                    {s.status} {s.verdict && `- ${s.verdict}`} {s.exit_code !== undefined && `(exit ${s.exit_code})`}
                  </div>
                  <div className="muted">{s.lang}</div>
                </div>
                <button onClick={() => loadSubmissionIntoEditor(s)}>Load & Retry</button>
              </li>
            ))}
          </ul>
        </div>

        {selectedSub && (
          <div className="card">
            <div className="card-header">
              <h2>{`Submission #${selectedSub.id}`}</h2>
              {selectedLoading && <span className="muted">Loading…</span>}
            </div>
            {selectedError && <div className="notice error">{selectedError}</div>}
            <div className="row gap-8">
              <div>Status: {selectedSub.status}</div>
              <div>Verdict: {selectedSub.verdict || '—'}</div>
              <div>Lang: {selectedSub.lang || 'unknown'}</div>
              <div className="muted">{selectedSub.timestamp}</div>
            </div>
            <div className="row gap-8">
              <button onClick={() => loadSubmissionIntoEditor(selectedSub)}>Load & Retry</button>
              <button onClick={() => setSelectedSub(null)}>Clear</button>
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
      </section>
    </main>
  );
}
