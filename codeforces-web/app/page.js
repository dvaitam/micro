'use client';

import { useEffect, useMemo, useRef, useState } from 'react';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';
const wsBase = process.env.NEXT_PUBLIC_WS_URL || 'wss://codeforces-api.manchik.co.uk/ws';
const pageSize = 15;

export default function Home() {
  const [problems, setProblems] = useState([]);
  const [selected, setSelected] = useState(null);
  const [code, setCode] = useState('');
  const [lang, setLang] = useState('go');
  const [statusLog, setStatusLog] = useState([]);
  const [email, setEmail] = useState('');
  const [otp, setOtp] = useState('');
  const [token, setToken] = useState('');
  const [authMsg, setAuthMsg] = useState(null);
  const [page, setPage] = useState(0);
  const [mySubs, setMySubs] = useState([]);
  const socketRef = useRef(null);

  useEffect(() => {
    const saved = typeof window !== 'undefined' ? localStorage.getItem('cf_token') : '';
    if (saved) {
      setToken(saved);
    }
  }, []);

  useEffect(() => {
    fetchProblems();
    return () => {
      if (socketRef.current) socketRef.current.close();
    };
  }, [page, token]);

  useEffect(() => {
    if (token) fetchMySubs();
  }, [token]);

  const fetchProblems = async () => {
    const offset = page * pageSize;
    try {
      const res = await fetch(`${apiBase}/problems?limit=${pageSize}&offset=${offset}`);
      const data = await res.json();
      const list = Array.isArray(data) ? data : [];
      setProblems(list);
      if (list.length > 0) setSelected(list[0]);
      else setSelected(null);
    } catch (err) {
      console.error('failed to load problems', err);
      setProblems([]);
      setSelected(null);
    }
  };

  const fetchMySubs = async () => {
    try {
      const res = await fetch(`${apiBase}/me/submissions?limit=20`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (!res.ok) return;
      const data = await res.json();
      setMySubs(Array.isArray(data) ? data : []);
    } catch (err) {
      console.error('failed to load submissions', err);
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
      if (typeof window !== 'undefined') {
        localStorage.setItem('cf_token', data.token);
      }
      setAuthMsg({ type: 'success', text: 'Logged in' });
      fetchMySubs();
    } catch (err) {
      setAuthMsg({ type: 'error', text: err.message });
    }
  };

  const handleSubmit = async () => {
    if (!selected || !token) {
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
          contest_id: selected.contest_id,
          index: selected.index,
          lang,
          code,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data?.error || 'submission failed');
      }
      setStatusLog([{ ts: new Date().toISOString(), status: data.status, detail: `Submission #${data.submission_id}` }]);
      if (socketRef.current) socketRef.current.close();
      const ws = new WebSocket(`${wsBase}?submissionId=${data.submission_id}`);
      socketRef.current = ws;
      ws.onmessage = (evt) => {
        try {
          const msg = JSON.parse(evt.data);
          setStatusLog((prev) => [...prev, { ts: new Date().toISOString(), status: msg.status, detail: msg.verdict || msg.stdout || '' }]);
        } catch (e) {
          console.error('ws parse error', e);
        }
      };
      ws.onerror = (err) => console.error('ws error', err);
      fetchMySubs();
    } catch (err) {
      alert(err.message);
    }
  };

  const selectedStatement = useMemo(() => (selected ? selected.statement || '' : ''), [selected]);

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Codeforces Web</h1>
          <p>Submit solutions backed by the API microservice.</p>
        </div>
        <div className="pill">API: {apiBase}</div>
      </header>

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Problems</h2>
            <span className="muted">from database</span>
          </div>
          <div className="problem-list">
            {(problems || []).map((p) => (
              <button
                key={`${p.contest_id}-${p.index}`}
                className={`problem ${selected?.id === p.id ? 'active' : ''}`}
                onClick={() => setSelected(p)}
              >
                <span className="label">
                  {p.contest_id}
                  {p.index}
                </span>
                <span>{p.title}</span>
              </button>
            ))}
            {problems.length === 0 && <div className="muted">No problems available.</div>}
          </div>
          <div className="pagination">
            <button onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0}>
              Prev
            </button>
            <span className="muted">Page {page + 1}</span>
            <button onClick={() => setPage((p) => p + 1)}>Next</button>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <h2>Statement</h2>
            <span className="muted">{selected ? `${selected.contest_id}${selected.index}` : ''}</span>
          </div>
          <pre className="statement">{selectedStatement}</pre>
        </div>

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
            <button className="primary" onClick={handleSubmit} disabled={!selected || !code || !token}>
              Submit
            </button>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <h2>Status</h2>
            <span className="muted">websocket updates</span>
          </div>
          <ul className="status">
            {(statusLog || []).map((s, idx) => (
              <li key={idx}>
                <span className="label">{s.status}</span>
                <span className="muted">{s.ts}</span>
                <div>{s.detail}</div>
              </li>
            ))}
            {statusLog.length === 0 && <li className="muted">No submissions yet.</li>}
          </ul>
        </div>

        <div className="card">
          <div className="card-header">
            <h2>My submissions</h2>
            <span className="muted">latest</span>
          </div>
          <ul className="status">
            {(mySubs || []).map((s) => (
              <li key={s.id}>
                <span className="label">
                  {s.contest_id}
                  {s.index}
                </span>
                <span className="muted">{s.timestamp}</span>
                <div>{s.status}</div>
                {s.verdict && <div className="muted">{s.verdict}</div>}
              </li>
            ))}
            {mySubs.length === 0 && <li className="muted">No submissions</li>}
          </ul>
        </div>
      </section>
    </main>
  );
}
