import { useState } from 'react';

const postJSON = async (url, body) => {
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    credentials: 'include',
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || 'Request failed');
  }
  return response.json();
};

function AuthView({ apiBase, onAuthenticated }) {
  const [email, setEmail] = useState('');
  const [otp, setOtp] = useState('');
  const [status, setStatus] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const handleRequestOTP = async (event) => {
    event.preventDefault();
    setError('');
    setSuccess('');
    if (!email.trim()) {
      setError('Enter your email.');
      return;
    }
    try {
      setStatus('Sending OTP…');
      await postJSON(`${apiBase}/api/request-otp`, { email: email.trim() });
      setStatus('');
      setSuccess('OTP sent if the email exists. Check your inbox.');
    } catch (err) {
      console.error(err);
      setStatus('');
      setError('Unable to request OTP.');
    }
  };

  const handleVerifyOTP = async (event) => {
    event.preventDefault();
    setError('');
    setSuccess('');
    if (!email.trim() || !otp.trim()) {
      setError('Enter email and OTP.');
      return;
    }
    try {
      setStatus('Verifying…');
      const data = await postJSON(`${apiBase}/api/verify-otp`, {
        email: email.trim(),
        otp: otp.trim(),
      });
      if (!data.access_token) {
        throw new Error('Missing access token');
      }
      setStatus('');
      setSuccess('Authenticated! Loading chats…');
      onAuthenticated(data.access_token);
    } catch (err) {
      console.error(err);
      setStatus('');
      setError('Unable to verify OTP.');
    }
  };

  return (
    <div className="auth-view">
      <div className="auth-panel">
        <h1>Sign in to Messages</h1>
        <p className="auth-subtitle">Use your email to receive a one-time password.</p>
        <form className="auth-form" onSubmit={handleRequestOTP}>
          <label>
            Email
            <input
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="you@example.com"
              required
            />
          </label>
          <button type="submit">Send OTP</button>
        </form>
        <form className="auth-form" onSubmit={handleVerifyOTP}>
          <label>
            OTP Code
            <input
              type="text"
              value={otp}
              onChange={(event) => setOtp(event.target.value)}
              placeholder="123456"
              required
            />
          </label>
          <button type="submit">Verify &amp; Continue</button>
        </form>
        {status && <p className="auth-status">{status}</p>}
        {error && <p className="auth-error">{error}</p>}
        {success && <p className="auth-success">{success}</p>}
      </div>
    </div>
  );
}

export default AuthView;
