'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useState } from 'react';

const links = [
  { href: '/', label: 'Problems' },
  { href: '/leaderboard', label: 'Leaderboard' },
  { href: '/submissions', label: 'Submissions' },
  { href: '/my/submissions', label: 'My Submissions' },
  { href: '/failed', label: 'Failed' },
];

export default function Nav() {
  const pathname = usePathname();
  const [menuOpen, setMenuOpen] = useState(false);

  return (
    <nav className="site-nav">
      <div className="site-nav__inner">
        <Link href="/" className="site-nav__logo">CF Web</Link>
        <button
          className="site-nav__toggle"
          onClick={() => setMenuOpen(!menuOpen)}
          aria-label="Toggle menu"
        >
          <span className={`site-nav__hamburger ${menuOpen ? 'open' : ''}`} />
        </button>
        <ul className={`site-nav__links ${menuOpen ? 'site-nav__links--open' : ''}`}>
          {links.map(({ href, label }) => (
            <li key={href}>
              <Link
                href={href}
                className={`site-nav__link ${pathname === href ? 'site-nav__link--active' : ''}`}
                onClick={() => setMenuOpen(false)}
              >
                {label}
              </Link>
            </li>
          ))}
        </ul>
      </div>
    </nav>
  );
}
