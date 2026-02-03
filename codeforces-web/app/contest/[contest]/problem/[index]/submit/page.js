'use client';

import Link from 'next/link';
import dynamic from 'next/dynamic';
import { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { cpp, c } from '@codemirror/lang-cpp';
import { go } from '@codemirror/lang-go';
import { python } from '@codemirror/lang-python';
import { rust } from '@codemirror/lang-rust';
import { java } from '@codemirror/lang-java';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';
const CodeMirror = dynamic(() => import('@uiw/react-codemirror'), { ssr: false });

export default function SubmitPage({ params }) {
  const contest = params.contest;
  const index = params.index;
  const [problem, setProblem] = useState(null);
  const [problemError, setProblemError] = useState('');
  const [code, setCode] = useState('');
  const [lang, setLang] = useState('go');
  const [statusLog, setStatusLog] = useState([]);
  const [email, setEmail] = useState('');
  const [otp, setOtp] = useState('');
  const [stayLoggedIn, setStayLoggedIn] = useState(false);
  const [token, setToken] = useState('');
  const [userEmail, setUserEmail] = useState('');
  const [authMsg, setAuthMsg] = useState(null);
  const router = useRouter();
  const editorExtensions = useMemo(() => {
    switch (lang) {
      case 'go':
        return [go()];
      case 'c':
        return [c()];
      case 'cpp':
        return [cpp()];
      case 'py':
        return [python()];
      case 'rs':
        return [rust()];
      case 'java':
        return [java()];
      default:
        return [];
    }
  }, [lang]);

  useEffect(() => {
    const saved = typeof window !== 'undefined' ? localStorage.getItem('cf_token') : '';
    const savedEmail = typeof window !== 'undefined' ? localStorage.getItem('cf_email') : '';
    if (saved) {
      setToken(saved);
      fetch(`${apiBase}/me/submissions?limit=1`, {
        headers: { Authorization: `Bearer ${saved}` }
      }).then(async (res) => {
        if (res.status === 401) {
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
    let cancelled = false;
    const load = async () => {
      setProblemError('');
      try {
        const res = await fetch(`${apiBase}/problems/${contest}/${index}`);
        if (!res.ok) {
          throw new Error(`Failed to load problem (${res.status})`);
        }
        const data = await res.json();
        if (!cancelled) setProblem(data);
      } catch (err) {
        if (!cancelled) setProblemError(err.message || 'Failed to load problem');
      }
    };
    load();
    return () => {
      cancelled = true;
    };
  }, [contest, index]);

  useEffect(() => {
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
    }
  }, [contest, index]);

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
      console.error('Refresh failed', e);
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
    if (!token) {
      setStatusLog((prev) => [...prev, { ts: new Date().toISOString(), status: 'error', detail: 'Login required' }]);
      return;
    }

    const contestId = problem?.contest_id || contest;
    const problemIndex = problem?.index || index;

    const doSubmit = async (authToken) => {
      return fetch(`${apiBase}/submissions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${authToken}`,
        },
        body: JSON.stringify({
          contest_id: contestId,
          index: problemIndex,
          lang,
          code,
        }),
      });
    };

    try {
      let res = await doSubmit(token);

      if (res.status === 401) {
        const refreshed = await refreshSession();
        if (refreshed) {
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
      router.push('/submissions');
    } catch (err) {
      setStatusLog((prev) => [...prev, { ts: new Date().toISOString(), status: 'error', detail: err.message }]);
    }
  };

  const loggedIn = !!token;
  const statementUrl = `https://cdn.manchik.co.uk/contest/${contest}/problem/${index}`;

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>
            Submit {contest}
            {index}
          </h1>
          <div className="row gap-8">
            <p>{problem?.title || 'Problem'}</p>
            <Link href={`/contest/${contest}/problem/${index}`} className="muted">
              Back to statement ↗
            </Link>
            <a href={statementUrl} target="_blank" rel="noreferrer" className="muted">
              Open statement ↗
            </a>
          </div>
          {problemError && <div className="notice error">{problemError}</div>}
          {problem && (
            <div className="muted" style={{ marginTop: 4 }}>
              {problem.rating > 0 ? `rating ${problem.rating}` : 'rating —'}
              {Array.isArray(problem.tags) && problem.tags.length > 0 && (
                <>
                  {' '}• tags: {problem.tags.join(', ')}
                </>
              )}
            </div>
          )}
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
            <h2>Submit</h2>
            <span className="muted">requires login</span>
          </div>
          <div className="form">
            <label>
              Language
              <select value={lang} onChange={(e) => setLang(e.target.value)}>
                <option value="go">Go</option>
                <option value="c">C</option>
                <option value="cpp">C++</option>
                <option value="py">Python</option>
                <option value="rs">Rust</option>
                <option value="java">Java</option>
                <option value="kotlin">Kotlin</option>
              </select>
            </label>
            <label>
              Code
              <div className="code-editor">
                <CodeMirror
                  value={code}
                  height="520px"
                  extensions={editorExtensions}
                  onChange={(value) => setCode(value)}
                  placeholder="Paste your solution here..."
                  basicSetup={{
                    lineNumbers: true,
                    foldGutter: true,
                    highlightActiveLine: true,
                    autocompletion: true,
                  }}
                />
              </div>
            </label>
            <button className="primary" onClick={handleSubmit} disabled={!code || !token}>
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
      </section>
    </main>
  );
}
