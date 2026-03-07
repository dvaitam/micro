'use client';

import Link from 'next/link';
import { Suspense, useEffect, useState } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import ModelLogo from '../components/ModelLogo';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

function timeAgo(timestamp) {
  if (!timestamp) return '—';
  const now = Date.now();
  const then = new Date(timestamp).getTime();
  if (isNaN(then)) return timestamp;
  const seconds = Math.floor((now - then) / 1000);
  if (seconds < 60) return 'just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  const weeks = Math.floor(days / 7);
  if (weeks < 5) return `${weeks}w ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months}mo ago`;
  const years = Math.floor(days / 365);
  return `${years}y ago`;
}

function extractCodeBlock(text) {
  if (!text) return '';
  const match = text.match(/```(?:[\w.+-]*\n)?([\s\S]*?)```/m);
  if (match) return match[1].trim();
  return text.trim();
}

function stripComments(code) {
  if (!code) return '';
  let cleaned = code.replace(/\/\*[\s\S]*?\*\//g, '');
  cleaned = cleaned.replace(/\/\/.*$/gm, '');
  return cleaned.trim();
}

function cleanedResponse(response) {
  const code = extractCodeBlock(response || '');
  return stripComments(code);
}

function isReviewed(entry) {
  return Number(entry?.reviewied || 0) > 0;
}

function FailedContent({ params }) {
  const searchParams = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();
  const modelFromPath = params?.model ? decodeURIComponent(params.model) : '';

  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [page, setPage] = useState(0);
  const [onlyUnreviewed, setOnlyUnreviewed] = useState(true);
  const [hasMore, setHasMore] = useState(false);
  const [copiedId, setCopiedId] = useState(null);
  const [model, setModel] = useState(modelFromPath);

  useEffect(() => {
    document.title = modelFromPath ? `Failed - ${modelFromPath} | CF Web` : 'Failed | CF Web';
  }, [modelFromPath]);

  useEffect(() => {
    const fromQuery = searchParams?.get('unreviewed') === '1';
    if (searchParams?.has('unreviewed')) {
      setOnlyUnreviewed(fromQuery);
    }
  }, [searchParams]);

  useEffect(() => {
    setModel(modelFromPath);
  }, [modelFromPath]);

  useEffect(() => {
    load(page, onlyUnreviewed, model);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, onlyUnreviewed, model]);

  const load = async (pageNum, unreviewed, modelFilter) => {
    setLoading(true);
    setError('');
    const limit = 30;
    const offset = pageNum * limit;
    const qs = new URLSearchParams({ limit: String(limit), offset: String(offset) });
    if (unreviewed) qs.set('unreviewed', '1');
    if (modelFilter) qs.set('model', modelFilter);
    try {
      const res = await fetch(`${apiBase}/failed?${qs.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`Failed to load failed list (${res.status})`);
      const data = await res.json();
      let evals = Array.isArray(data?.evals) ? data.evals : [];
      if (unreviewed) {
        evals = evals.filter((e) => !isReviewed(e));
      }
      setRows(evals);
      setHasMore(evals.length === limit);
    } catch (err) {
      setError(err.message || 'Failed to load failed list');
      setRows([]);
      setHasMore(false);
    } finally {
      setLoading(false);
    }
  };

  const syncUrl = (nextModel, nextUnreviewed) => {
    const base = nextModel ? `/failed/${encodeURIComponent(nextModel)}` : '/failed';
    const sp = new URLSearchParams();
    if (nextUnreviewed) sp.set('unreviewed', '1');
    const url = sp.toString() ? `${base}?${sp.toString()}` : base;
    if (url !== pathname + (searchParams?.toString() ? `?${searchParams.toString()}` : '')) {
      router.push(url);
    }
  };

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Failed evaluations</h1>
          <p className="muted">
            Filter for unreviewed items to triage quickly{model ? ` · Model: ${model}` : ''}.
          </p>
        </div>
      </header>

      {error && <div className="notice error">{error}</div>}

      <section className="grid">
        <div className="card wide-card">
          <div className="card-header">
            <h2>Latest failures</h2>
            <div className="row gap-8" style={{ alignItems: 'center' }}>
              <label className="muted" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <input
                  type="checkbox"
                  checked={onlyUnreviewed}
                  onChange={(e) => {
                    const next = e.target.checked;
                    setPage(0);
                    setOnlyUnreviewed(next);
                    syncUrl(model, next);
                  }}
                />
                Only unreviewed
              </label>
              <div className="row gap-8" style={{ alignItems: 'center' }}>
                <input
                  value={model}
                  onChange={(e) => setModel(e.target.value)}
                  placeholder="Filter by model"
                  style={{ minWidth: 180 }}
                />
                <button
                  onClick={() => {
                    const trimmed = model.trim();
                    setPage(0);
                    syncUrl(trimmed, onlyUnreviewed);
                    setModel(trimmed);
                    load(0, onlyUnreviewed, trimmed);
                  }}
                >
                  Apply
                </button>
              </div>
              {loading && <span className="muted">Loading…</span>}
            </div>
          </div>

          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>ID</th>
              <th>Model</th>
              <th>Problem</th>
              <th>Rating</th>
              <th>Run</th>
              <th>Reviewed?</th>
              <th>Time</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td><Link href={`/evaluation/${r.id}/fix`}>#{r.id}</Link></td>
                <td>{r.model ? <><ModelLogo model={r.model} /><Link href={`/model?name=${encodeURIComponent(r.model)}`}>{r.model}</Link></> : '—'}</td>
                <td>
                  <Link href={`/contest/${r.contest_id}/problem/${r.index}`}>
                    {r.contest_id}{r.index}
                  </Link>
                  {' '}
                  <a
                    href={`https://codeforces.com/problemset/submit/${r.contest_id}/${r.index}`}
                    target="_blank"
                    rel="noreferrer"
                    className="muted"
                    style={{ marginLeft: 4 }}
                  >
                    (CF)
                  </a>
                </td>
                <td>{r.rating && r.rating > 0 ? r.rating : '—'}</td>
                <td className="muted">{r.run_id ? <Link href={`/run/${encodeURIComponent(r.run_id)}`}>{r.run_id}</Link> : '—'}</td>
                <td>{isReviewed(r) ? 'Yes' : 'No'}</td>
                <td className="muted" title={r.timestamp}>{timeAgo(r.timestamp)}</td>
                <td>
                  <button onClick={async () => {
                    try {
                      await navigator.clipboard.writeText(cleanedResponse(r.response));
                      setCopiedId(r.id);
                      setTimeout(() => setCopiedId(null), 1500);
                    } catch (e) {
                      console.error('copy failed', e);
                    }
                  }}>
                    {copiedId === r.id ? 'Copied' : 'Cleaned up response'}
                  </button>
                </td>
              </tr>
            ))}
            {rows.length === 0 && !loading && (
              <tr>
                <td colSpan={8} className="muted">
                  Nothing to show.
                </td>
              </tr>
            )}
              </tbody>
            </table>
          </div>

          <div className="pagination">
            <button onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0 || loading}>
              Prev
            </button>
            <span className="muted">Page {page + 1}</span>
            <button onClick={() => setPage((p) => p + 1)} disabled={!hasMore || loading}>
              Next
            </button>
          </div>
        </div>
      </section>
    </main>
  );
}

export default function FailedPage(props) {
  return (
    <Suspense
      fallback={(
        <main className="page">
          <header className="header">
            <h1>Failed evaluations</h1>
          </header>
          <div className="notice">Loading failed evaluations…</div>
        </main>
      )}
    >
      <FailedContent {...props} />
    </Suspense>
  );
}
