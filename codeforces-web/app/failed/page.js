'use client';

import Link from 'next/link';
import { Suspense, useEffect, useState } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';

function extractCodeBlock(text) {
  if (!text) return '';
  const match = text.match(/```(?:[\w.+-]*\n)?([\s\S]*?)```/m);
  if (match) return match[1].trim();
  return text.trim();
}

function stripComments(code) {
  if (!code) return '';
  let cleaned = code.replace(/\/\*[\s\S]*?\*\//g, '');
  cleaned = cleaned.replace(/(^|\s)#.*$/gm, '$1');
  cleaned = cleaned.replace(/\/\/.*$/gm, '');
  //  Only strip SQL-style comments that start a line; keep decrement operators intact.
  cleaned = cleaned.replace(/^[ \t]*--.*$/gm, '');
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
        <div className="nav-links">
          <Link href="/">Home</Link>
          <Link href="/submissions">Recent submissions</Link>
          <Link href="/my/submissions">My submissions</Link>
          <Link href="/leaderboard">Leaderboard</Link>
          <a href="https://codeforces.com/" target="_blank" rel="noreferrer">
            Codeforces
          </a>
          <Link href="/failed" className="active">
            Failed
          </Link>
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
              <th>Run</th>
              <th>Reviewed?</th>
              <th>Timestamp</th>
              <th>Cleaned response</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>#{r.id}</td>
                <td>{r.model ? <Link href={`/model?name=${encodeURIComponent(r.model)}`}>{r.model}</Link> : '—'}</td>
                <td>
                  <Link href={`/contest/${r.contest_id}/problem/${r.index}`}>
                    {r.contest_id}
                    {r.index}
                  </Link>
                  {' '}
                  <a
                    href={`https://codeforces.com/problemset/problem/${r.contest_id}/${r.index}`}
                    target="_blank"
                    rel="noreferrer"
                    className="muted"
                    style={{ marginLeft: 4 }}
                  >
                    (CF)
                  </a>
                </td>
                <td className="muted">{r.run_id || '—'}</td>
                <td>{isReviewed(r) ? 'Yes' : 'No'}</td>
                <td className="muted">{r.timestamp}</td>
                <td>
                  <a
                    href={`https://codeforces.com/problemset/problem/${r.contest_id}/${r.index}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Problem
                  </a>
                </td>
                <td>
                  <div className="row gap-8" style={{ alignItems: 'center' }}>
                    <div className="muted" style={{ maxWidth: 220, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      {cleanedResponse(r.response) || '—'}
                    </div>
                    <button
                      onClick={async () => {
                        try {
                          await navigator.clipboard.writeText(cleanedResponse(r.response));
                          setCopiedId(r.id);
                          setTimeout(() => setCopiedId(null), 1200);
                        } catch (e) {
                          console.error('copy failed', e);
                        }
                      }}
                    >
                      {copiedId === r.id ? 'Copied' : 'Copy'}
                    </button>
                  </div>
                </td>
                <td className="row gap-8">
                  <Link href={`/evaluation/${r.id}`}>View</Link>
                  <Link href={`/evaluation/${r.id}/fix`}>Fix prompt</Link>
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
