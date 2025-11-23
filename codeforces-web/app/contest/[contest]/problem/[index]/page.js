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
  const [token, setToken] = useState('');
  const [userEmail, setUserEmail] = useState('');
  const [authMsg, setAuthMsg] = useState(null);
  const router = useRouter();
  const socketRef = useRef(null);

  useEffect(() => {
    const saved = typeof window !== 'undefined' ? localStorage.getItem('cf_token') : '';
    const savedEmail = typeof window !== 'undefined' ? localStorage.getItem('cf_email') : '';
    if (saved) setToken(saved);
    if (savedEmail) setUserEmail(savedEmail);
  }, []);

  useEffect(() => {
    loadProblem();
    return () => {
      if (socketRef.current) socketRef.current.close();
    };
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
        body: JSON.stringify({ email, code: otp }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || 'verification failed');
      setToken(data.token);
      setUserEmail(data.email || email);
      if (typeof window !== 'undefined') {
        localStorage.setItem('cf_token', data.token);
        localStorage.setItem('cf_email', data.email || email);
      }
      setAuthMsg({ type: 'success', text: 'Logged in' });
    } catch (err) {
      setAuthMsg({ type: 'error', text: err.message });
    }
  };

  const handleLogout = () => {
    setToken('');
    setUserEmail('');
    setEmail('');
    setOtp('');
    if (typeof window !== 'undefined') {
      localStorage.removeItem('cf_token');
      localStorage.removeItem('cf_email');
    }
    setAuthMsg({ type: 'info', text: 'Logged out' });
  };

  const handleSubmit = async () => {
    if (!problem || !token) {
      setStatusLog((prev) => [...prev, { ts: new Date().toISOString(), status: 'error', detail: 'Login required' }]);
      return;
    }
    try {
      const res = await fetch(`${apiBase}/submissions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({
          contest_id: problem.contest_id,
          index: problem.index,
          lang,
          code,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data?.error || 'submission failed');
      }
      setStatusLog([{ ts: new Date().toISOString(), status: data.status, detail: `Submission #${data.submission_id}` }]);
      // Redirect to submissions page to watch live status.
      router.push('/submissions');
    } catch (err) {
      setStatusLog((prev) => [...prev, { ts: new Date().toISOString(), status: 'error', detail: err.message }]);
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
          <p>{problem?.title || 'Problem'}</p>
        </div>
        <div className="nav-links">
          <Link href="/">Problems</Link>
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
      </section>
    </main>
  );
}
