'use client';

import Link from 'next/link';
import { Suspense, useEffect, useState, useCallback } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';

const apiBase = process.env.NEXT_PUBLIC_API_URL || 'https://codeforces-api.manchik.co.uk';
const pageSize = 15;

export default function Home() {
  return (
    <Suspense>
      <HomeContent />
    </Suspense>
  );
}

function HomeContent() {
  const router = useRouter();
  const searchParams = useSearchParams();

  useEffect(() => { document.title = 'Problems | CF Web'; }, []);

  // Initialize state from URL search params 
  const [problems, setProblems] = useState([]);
  const [selected, setSelected] = useState(null);
  const [totalCount, setTotalCount] = useState(0);
  const [page, setPage] = useState(() => {
    const p = parseInt(searchParams.get('page'), 10);
    return p > 0 ? p - 1 : 0; // URL is 1-indexed, state is 0-indexed
  });
  const [allTags, setAllTags] = useState([]);
  const [selectedTags, setSelectedTags] = useState(() => {
    const t = searchParams.get('tags');
    return t ? t.split(',').filter(Boolean) : [];
  });
  const [tagsMode, setTagsMode] = useState(() => searchParams.get('tags_mode') || 'any');
  const [sort, setSort] = useState(() => searchParams.get('sort') || '');
  const [goToPage, setGoToPage] = useState('');

  const totalPages = Math.max(1, Math.ceil(totalCount / pageSize));

  // Sync state to URL
  const syncURL = useCallback((p, tags, mode, s) => {
    const params = new URLSearchParams();
    if (p > 0) params.set('page', p + 1); // 1-indexed in URL
    if (tags.length > 0) params.set('tags', tags.join(','));
    if (tags.length > 0 && mode !== 'any') params.set('tags_mode', mode);
    if (s) params.set('sort', s);
    const qs = params.toString();
    router.replace(qs ? `?${qs}` : '/', { scroll: false });
  }, [router]);

  useEffect(() => {
    // load tags once
    (async () => {
      try {
        const res = await fetch(`${apiBase}/tags`, { cache: 'no-store' });
        const data = await res.json();
        if (Array.isArray(data)) setAllTags(data);
      } catch (e) {
        console.error('failed to load tags', e);
      }
    })();
  }, []);

  useEffect(() => {
    fetchProblems();
    syncURL(page, selectedTags, tagsMode, sort);
  }, [page, selectedTags, tagsMode, sort]);

  const fetchProblems = async () => {
    const offset = page * pageSize;
    try {
      const qs = new URLSearchParams();
      qs.set('limit', pageSize);
      qs.set('offset', offset);
      if (selectedTags.length > 0) {
        qs.set('tags', selectedTags.join(','));
        qs.set('tags_mode', tagsMode);
      }
      if (sort) {
        qs.set('sort', sort);
      }
      const res = await fetch(`${apiBase}/problems?${qs.toString()}`);
      const data = await res.json();
      const list = Array.isArray(data.problems) ? data.problems : [];
      const total = data.total || 0;
      setProblems(list);
      setTotalCount(total);
      if (list.length > 0) setSelected(list[0]);
      else setSelected(null);
    } catch (err) {
      console.error('failed to load problems', err);
      setProblems([]);
      setSelected(null);
      setTotalCount(0);
    }
  };

  const handleGoToPage = () => {
    const p = parseInt(goToPage, 10);
    if (p >= 1 && p <= totalPages) {
      setPage(p - 1); // convert 1-indexed input to 0-indexed state
      setGoToPage('');
    }
  };

  return (
    <main className="page">
      <header className="header">
        <div>
          <h1>Codeforces Web</h1>
          <p>Browse problems, open a statement to submit.</p>
        </div>
      </header>

      <section className="grid">
        <div className="card">
          <div className="card-header">
            <h2>Problems</h2>
            <span className="muted">{totalCount} total</span>
          </div>
          <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start' }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="problem-list">
                {(problems || []).map((p) => (
                  <Link key={`${p.contest_id}-${p.index}`} href={`/contest/${p.contest_id}/problem/${p.index}`} className={`problem ${selected?.id === p.id ? 'active' : ''}`}>
                    <span className="label">
                      {p.contest_id}
                      {p.index}
                    </span>
                    <span>
                      {p.title}
                      <div className="muted" style={{ fontSize: '0.85em', marginTop: 2 }}>
                        {p.rating > 0 ? `rating ${p.rating}` : 'rating —'}
                        {Array.isArray(p.tags) && p.tags.length > 0 && (
                          <>
                            {' '}• tags: {p.tags.slice(0, 4).join(', ')}{p.tags.length > 4 ? '…' : ''}
                          </>
                        )}
                      </div>
                    </span>
                  </Link>
                ))}
                {problems.length === 0 && <div className="muted">No problems available.</div>}
              </div>
              <div className="pagination">
                <button onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0}>
                  Prev
                </button>
                <span className="muted">Page {page + 1} of {totalPages}</span>
                <button onClick={() => setPage((p) => p + 1)} disabled={page + 1 >= totalPages}>
                  Next
                </button>
                <span className="pagination-goto">
                  <input
                    type="number"
                    min="1"
                    max={totalPages}
                    value={goToPage}
                    onChange={(e) => setGoToPage(e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Enter') handleGoToPage(); }}
                    placeholder="#"
                    className="page-input"
                  />
                  <button onClick={handleGoToPage} disabled={!goToPage}>Go</button>
                </span>
              </div>
            </div>
            <aside style={{ width: 300 }}>
              <div className="muted" style={{ marginBottom: 4 }}>Sort by</div>
              <select
                value={sort}
                onChange={(e) => { setSort(e.target.value); setPage(0); }}
                style={{ width: '100%', marginBottom: 12 }}
              >
                <option value="">Default (Contest)</option>
                <option value="rating_asc">Rating (Low to High)</option>
                <option value="rating_desc">Rating (High to Low)</option>
              </select>
              <div className="muted" style={{ marginBottom: 4 }}>Filter by tags</div>
              <div className="tag-filter-list" style={{ marginBottom: 12 }}>
                {allTags.length === 0 && <div className="muted">No tags available</div>}
                {allTags.map((t) => (
                  <label key={t} className="tag-filter-item">
                    <input
                      type="checkbox"
                      checked={selectedTags.includes(t)}
                      onChange={(e) => {
                        const on = e.target.checked;
                        setPage(0);
                        setSelectedTags((prev) => (on ? [...prev, t] : prev.filter((x) => x !== t)));
                      }}
                    />
                    <span>{t}</span>
                  </label>
                ))}
              </div>
              <div>
                <div className="muted" style={{ marginBottom: 4 }}>Match</div>
                <select value={tagsMode} onChange={(e) => { setTagsMode(e.target.value); setPage(0); }}>
                  <option value="any">Any</option>
                  <option value="all">All</option>
                </select>
              </div>
            </aside>
          </div>
        </div>
      </section>
    </main>
  );
}
