import { useCallback, useEffect, useMemo, useState } from 'react';
import AuthView from './components/AuthView';
import ChatView from './components/ChatView';
import './App.css';

const DEFAULT_API_BASE = (import.meta.env.VITE_API_BASE_URL || window.location.origin).replace(/\/$/, '');

const createApiFetcher = (baseURL, accessToken) => {
  const normalizedBase = baseURL.replace(/\/$/, '');
  return async function apiFetch(path, options = {}) {
    const url = path.startsWith('http') ? path : `${normalizedBase}${path.startsWith('/') ? path : `/${path}`}`;
    const headers = new Headers(options.headers || {});
    const isFormData = options.body instanceof FormData;
    if (!isFormData && options.body && !headers.has('Content-Type')) {
      headers.set('Content-Type', 'application/json');
    }
    if (accessToken) {
      headers.set('Authorization', `Bearer ${accessToken}`);
    }
    const response = await fetch(url, {
      credentials: 'include',
      ...options,
      headers,
    });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || response.statusText);
    }
    const contentType = response.headers.get('Content-Type') || '';
    if (contentType.includes('application/json')) {
      return response.json();
    }
    return response;
  };
};

function App() {
  const [apiBase] = useState(DEFAULT_API_BASE);
  const [accessToken, setAccessToken] = useState(() => localStorage.getItem('chat_access_token') || '');
  const [session, setSession] = useState(null);
  const [view, setView] = useState('loading');
  const [status, setStatus] = useState('');

  const apiFetch = useMemo(() => createApiFetcher(apiBase, accessToken), [apiBase, accessToken]);

  const refreshSession = useCallback(async () => {
    if (!accessToken) {
      setSession(null);
      setView('auth');
      return;
    }
    try {
      setStatus('Restoring session…');
      const data = await apiFetch('/api/session', {
        method: 'GET',
      });
      setSession({
        email: data.email,
        token: data.token,
        accessToken: data.access_token || accessToken,
      });
      if (data.access_token && data.access_token !== accessToken) {
        localStorage.setItem('chat_access_token', data.access_token);
        setAccessToken(data.access_token);
      }
      setView('chat');
      setStatus('');
    } catch (err) {
      console.error('Session restore failed', err);
      setSession(null);
      setView('auth');
      setStatus('');
    }
  }, [accessToken, apiFetch]);

  useEffect(() => {
    if (!accessToken) {
      setView('auth');
      return;
    }
    refreshSession();
  }, [accessToken, refreshSession]);

  const handleAuthSuccess = useCallback((token) => {
    localStorage.setItem('chat_access_token', token);
    setAccessToken(token);
  }, []);

  const handleLogout = useCallback(() => {
    localStorage.removeItem('chat_access_token');
    setAccessToken('');
    setSession(null);
    setView('auth');
  }, []);

  return (
    <div className="app-shell">
      {view === 'loading' && (
        <div className="loader">Restoring session…</div>
      )}
      {view === 'auth' && (
        <AuthView
          apiBase={apiBase}
          onAuthenticated={(token) => handleAuthSuccess(token)}
        />
      )}
      {view === 'chat' && session && (
        <ChatView
          apiBase={apiBase}
          accessToken={accessToken}
          session={session}
          onLogout={handleLogout}
          refreshSession={refreshSession}
        />
      )}
      {status && <div className="status-toast">{status}</div>}
    </div>
  );
}

export default App;
