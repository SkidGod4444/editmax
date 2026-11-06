import type { Metadata } from "next";
import { Analytics } from "@vercel/analytics/next";
import { GeistMono } from "geist/font/mono";
import { GeistSans } from "geist/font/sans";
import { GeistSerifRegular } from "geist/font/serif/regular";
import "./globals.css";

// Three faces of Vercel's Geist: Sans for reading and headlines, Serif for the one italic word in each headline, Mono for
// labels, timecodes and code.
const fonts = [GeistSans, GeistSerifRegular, GeistMono].map((f) => f.variable).join(" ");

export const metadata: Metadata = {
  title: "EditMax: the video editor your coding agent can drive",
  description:
    "A native macOS video editor. Cut, grade, caption and deliver by hand, by chat, or from Claude Code, Codex and Cursor over MCP.",
  icons: { icon: "/icon.png" },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`dark ${fonts} h-full scroll-smooth antialiased`}
    >
      <body className="grain min-h-full flex flex-col">
        {children}
        {/* Vercel Web Analytics: page views, sent only from the Vercel deployment (never in development). */}
        <Analytics />
      </body>
    </html>
  );
}
