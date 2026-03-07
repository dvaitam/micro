import "./globals.css";
import Nav from "./components/Nav";
import Footer from "./components/Footer";

export const metadata = {
  title: {
    default: "CF Web",
    template: "%s | CF Web",
  },
  description: "Submit and watch Codeforces solutions locally",
  icons: {
    icon: '/icon.svg',
  },
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <Nav />
        <main className="site-main">{children}</main>
        <Footer />
      </body>
    </html>
  );
}
