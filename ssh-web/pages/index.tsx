import { useEffect, useMemo, useState } from 'react'

const baseURL = process.env.NEXT_PUBLIC_API_BASE_URL || ''

type Conn = {
  id: number
  name: string
  host: string
  port: number
  username: string
  has_password: boolean
  has_private_key: boolean
}

export default function Home() {
  const [token, setToken] = useState('')
  const [sessionToken, setSessionToken] = useState('')
  const [email, setEmail] = useState('')
  const [otp, setOtp] = useState('')
  const [connections, setConnections] = useState<Conn[]>([])
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [live, setLive] = useState<{id:number; last_used:string; expires_at:string}[]>([])
  const [loading, setLoading] = useState(false)
  const [lastResult, setLastResult] = useState('')
  const authz = useMemo(() => token ? { Authorization: `Bearer ${token}` } : {}, [token])

  const parseJsonSafe = async (res: Response) => {
    const ct = (res.headers.get('content-type') || '').toLowerCase()
    if (ct.includes('application/json')) {
      try { return await res.json() } catch {}
    }
    const txt = await res.text().catch(() => '')
    return { error: res.ok ? undefined : res.statusText || 'request failed', text: txt }
  }

  const requestOtp = async () => {
    await fetch(`${baseURL}/api/request-otp`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email }) })
    setMessage('If the email exists, an OTP was sent')
  }
  const verifyOtp = async () => {
    try {
      const res = await fetch(`${baseURL}/api/verify-otp`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email, otp }) })
      const data = await parseJsonSafe(res)
      if (res.ok) {
        setToken(data.access_token)
        if (data.session_token) {
          setSessionToken(data.session_token)
          try { localStorage.setItem('ssh_session_token', data.session_token) } catch {}
        }
        await loadConnections(data.access_token)
        setMessage('Logged in')
      } else {
        setMessage(data.error || 'verify failed')
      }
    } catch (e:any) {
      setMessage(e?.message || 'verify failed')
    }
  }
  const refreshSession = async (st?: string) => {
    const bearer = st || sessionToken
    if (!bearer) return
    const res = await fetch(`${baseURL}/api/session`, { headers: { Authorization: `Bearer ${bearer}` } })
    const data = await parseJsonSafe(res)
    if (res.ok) {
      if (data.access_token) setToken(data.access_token)
      if (data.email) setEmail(data.email)
    }
  }
  const loadConnections = async (tkn?: string) => {
    setLoading(true)
    const res = await fetch(`${baseURL}/api/ssh/connections`, { headers: { ...authz, ...(tkn ? { Authorization: `Bearer ${tkn}` } : {}) } })
    const data = await parseJsonSafe(res)
    setLoading(false)
    if (res.ok) setConnections(data.connections || [])
    else setMessage(data.error || 'load failed')
  }

  const [newConn, setNewConn] = useState({ name: '', host: '', port: 22, username: '', password: '', private_key: '', passphrase: '' })
  const createConn = async () => {
    const res = await fetch(`${baseURL}/api/ssh/connections`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...authz }, body: JSON.stringify(newConn) })
    const data = await res.json()
    if (res.ok) { setNewConn({ name:'', host:'', port:22, username:'', password:'', private_key:'', passphrase:'' }); setMessage('Connection created'); await loadConnections() }
    else setMessage(data.error || 'create failed')
  }

  const [run, setRun] = useState({ id: 0, command: 'uname -a', keepalive: 300 })
  const runCommand = async () => {
    const id = selectedId ?? run.id
    setLastResult('')
    const url = new URL(`${baseURL.replace(/\/$/, '')}/api/ssh/stream`)
    url.searchParams.set('id', String(id))
    url.searchParams.set('cmd', run.command)
    url.searchParams.set('keepalive_seconds', String(run.keepalive))
    if (token) url.searchParams.set('access_token', token)
    const wsUrl = url.toString().replace('https://', 'wss://').replace('http://', 'ws://')
    const ws = new WebSocket(wsUrl)
    ws.onmessage = (ev) => {
      const msg = typeof ev.data === 'string' ? ev.data : ''
      if (msg === '__CMD_DONE__') { ws.close(); return }
      setLastResult(prev => prev + msg)
    }
    ws.onerror = () => setMessage('stream error')
    ws.onclose = () => setMessage('command finished')
  }

  const loadLive = async () => {
    const res = await fetch(`${baseURL}/api/ssh/live`, { headers: { ...authz } })
    const data = await parseJsonSafe(res)
    if (res.ok) setLive(data.live || [])
  }
  // Switch from polling to WebSocket live updates
  useEffect(() => {
    if (!token) return
    loadConnections()
    try {
      const url = new URL(`${baseURL.replace(/\/$/, '')}/api/ssh/live/ws`)
      url.searchParams.set('access_token', token)
      const wsUrl = url.toString().replace('https://', 'wss://').replace('http://', 'ws://')
      const ws = new WebSocket(wsUrl)
      ws.onmessage = (ev) => {
        try {
          const txt = typeof ev.data === 'string' ? ev.data : ''
          const msg = JSON.parse(txt)
          if (msg && msg.type === 'live' && Array.isArray(msg.live)) setLive(msg.live)
        } catch {}
      }
      ws.onerror = () => setMessage('live stream error')
      return () => ws.close()
    } catch {}
  }, [token])
  useEffect(() => {
    try {
      const st = localStorage.getItem('ssh_session_token') || ''
      if (st) { setSessionToken(st); refreshSession(st) }
    } catch {}
  }, [])

  const signOut = () => {
    setToken(''); setSessionToken(''); setEmail(''); setConnections([]); setSelectedId(null); setLive([]); setLastResult(''); setMessage('Signed out')
    try { localStorage.removeItem('ssh_session_token') } catch {}
  }

  return (
    <div style={{ maxWidth: 900, margin: '20px auto', fontFamily: 'system-ui, -apple-system, Segoe UI, Roboto, sans-serif' }}>
      <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
        <h1 style={{ margin: 0 }}>SSH Manager</h1>
        {token ? <button onClick={signOut}>Sign out</button> : null}
      </header>

      {!token && (
        <div style={{ padding: 16, border: '1px solid #ddd', borderRadius: 8, marginBottom: 16 }}>
          <h2>Login via Email OTP</h2>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <input placeholder="email" value={email} onChange={e => setEmail(e.target.value)} />
            <button onClick={requestOtp}>Request OTP</button>
          </div>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 8 }}>
            <input placeholder="otp" value={otp} onChange={e => setOtp(e.target.value)} />
            <button onClick={verifyOtp}>Verify</button>
          </div>
        </div>
      )}

      {message && (
        <div style={{ marginBottom: 12, padding: 10, background: '#f6f8fa', border: '1px solid #d0d7de', borderRadius: 6 }}>{message}</div>
      )}

      {token && (
        <div style={{ padding: 16, border: '1px solid #ddd', borderRadius: 8, marginBottom: 16 }}>
          <h2>New Connection</h2>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr', gap: 8 }}>
            <input placeholder="name" value={newConn.name} onChange={e => setNewConn({ ...newConn, name: e.target.value })} />
            <input placeholder="host" value={newConn.host} onChange={e => setNewConn({ ...newConn, host: e.target.value })} />
            <input placeholder="port" type="number" value={newConn.port} onChange={e => setNewConn({ ...newConn, port: Number(e.target.value) })} />
            <input placeholder="username" value={newConn.username} onChange={e => setNewConn({ ...newConn, username: e.target.value })} />
            <input placeholder="password" value={newConn.password} onChange={e => setNewConn({ ...newConn, password: e.target.value })} />
            <textarea placeholder="private key (PEM)" value={newConn.private_key} onChange={e => setNewConn({ ...newConn, private_key: e.target.value })} />
            <input placeholder="passphrase" value={newConn.passphrase} onChange={e => setNewConn({ ...newConn, passphrase: e.target.value })} />
          </div>
          <button onClick={createConn} style={{ marginTop: 8 }}>Create</button>
        </div>
      )}

      <div style={{ padding: 16, border: '1px solid #ddd', borderRadius: 8 }}>
        <h2>Connections</h2>
        <div style={{ display: 'flex', gap: 16 }}>
          <div style={{ flex: 1 }}>
            <button onClick={() => loadConnections()} disabled={loading}>Refresh</button>
            <ul style={{ listStyle: 'none', padding: 0 }}>
              {connections.map(c => (
                <li key={c.id} onClick={() => setSelectedId(c.id)} style={{ padding: 8, marginTop: 6, border: '1px solid #ddd', borderRadius: 6, cursor: 'pointer', background: selectedId === c.id ? '#e6f0ff' : 'white' }}>
                  <strong>{c.name || c.host}</strong> — {c.username}@{c.host}:{c.port} {c.has_private_key ? '🔑' : c.has_password ? '🔒' : ''}
                </li>
              ))}
            </ul>
          </div>
          <div style={{ width: 320 }}>
            <h3>Live</h3>
            <ul style={{ listStyle: 'none', padding: 0 }}>
              {live.map(l => (
                <li key={l.id} style={{ padding: 8, marginTop: 6, border: '1px solid #ddd', borderRadius: 6 }}>
                  #{l.id}
                  <div style={{ fontSize: 12, color: '#555' }}>expires {new Date(l.expires_at).toLocaleTimeString()}</div>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>

      {token && (
        <div style={{ padding: 16, border: '1px solid #ddd', borderRadius: 8, marginTop: 16 }}>
          <h2>Run Command</h2>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <input placeholder="connection id" type="number" value={selectedId ?? run.id} onChange={e => setRun({ ...run, id: Number(e.target.value) })} />
            <input placeholder="command" value={run.command} onChange={e => setRun({ ...run, command: e.target.value })} style={{ flex: 1 }} />
            <input placeholder="keepalive seconds" type="number" value={run.keepalive} onChange={e => setRun({ ...run, keepalive: Number(e.target.value) })} style={{ width: 140 }} />
            <button onClick={async () => { await runCommand(); if (message) setMessage(message) }}>Run</button>
          </div>
          {lastResult && (
            <pre style={{ marginTop: 12, padding: 12, background: '#0f172a', color: '#e2e8f0', borderRadius: 8, overflow: 'auto', whiteSpace: 'pre-wrap' }}>{lastResult}</pre>
          )}
        </div>
      )}
    </div>
  )
}
