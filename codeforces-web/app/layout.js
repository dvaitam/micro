import "./globals.css";

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
      <body>{children}</body>
    </html>
  );
}
