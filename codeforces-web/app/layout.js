import "./globals.css";

export const metadata = {
  title: "Codeforces Web",
  description: "Submit and watch Codeforces solutions locally",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
