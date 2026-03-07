import Link from 'next/link';

export default function Footer() {
  return (
    <footer className="site-footer">
      <div className="site-footer__inner">
        <div className="site-footer__grid">
          <div className="site-footer__col">
            <h4 className="site-footer__heading">Browse</h4>
            <ul className="site-footer__list">
              <li><Link href="/">Problems</Link></li>
              <li><Link href="/leaderboard">Leaderboard</Link></li>
              <li><Link href="/submissions">Recent Submissions</Link></li>
            </ul>
          </div>
          <div className="site-footer__col">
            <h4 className="site-footer__heading">Account</h4>
            <ul className="site-footer__list">
              <li><Link href="/my/submissions">My Submissions</Link></li>
              <li><Link href="/failed">Failed Evaluations</Link></li>
            </ul>
          </div>
          <div className="site-footer__col">
            <h4 className="site-footer__heading">About</h4>
            <ul className="site-footer__list">
              <li><span>Built with Next.js</span></li>
              <li><span>Powered by Codeforces</span></li>
            </ul>
          </div>
        </div>
        <div className="site-footer__bottom">
          <p>CF Web</p>
        </div>
      </div>
    </footer>
  );
}
