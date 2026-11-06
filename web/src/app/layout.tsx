import type { Metadata, Viewport } from "next";
import { Analytics } from "@vercel/analytics/next";
import { GeistMono } from "geist/font/mono";
import { GeistSans } from "geist/font/sans";
import { GeistSerifRegular } from "geist/font/serif/regular";
import { download, github, license } from "@/components/site/links";
import { description, site, title } from "./site";
import "./globals.css";

// Three faces of Vercel's Geist: Sans for reading and headlines, Serif for the one italic word in each headline, Mono for
// labels, timecodes and code.
const fonts = [GeistSans, GeistSerifRegular, GeistMono].map((f) => f.variable).join(" ");

// The share images (opengraph-image.jpg, twitter-image.jpg and their .alt.txt), icon.png and apple-icon.png sit next to
// this file, so Next adds their tags with sizes, types and alt text.
export const metadata: Metadata = {
  metadataBase: new URL(site),
  title,
  description,
  applicationName: "EditMax",
  authors: [{ name: "Saidev Dhal", url: github }],
  creator: "Saidev Dhal",
  keywords: [
    "EditMax", "video editor", "macOS video editor", "MCP", "Model Context Protocol", "Claude Code", "Codex", "Cursor",
    "AI video editing", "agent video editing", "color grading", "captions", "open source video editor",
  ],
  category: "technology",
  alternates: { canonical: "/" },
  openGraph: { type: "website", url: "/", siteName: "EditMax", title, description, locale: "en_US" },
  twitter: { card: "summary_large_image", title, description },
  robots: { index: true, follow: true },
};

export const viewport: Viewport = { themeColor: "#000000", colorScheme: "dark" };

// What search engines read about the app itself (schema.org SoftwareApplication).
const jsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "EditMax",
  description,
  url: `${site}/`,
  image: `${site}/opengraph-image.jpg`,
  applicationCategory: "MultimediaApplication",
  applicationSubCategory: "Video editor",
  operatingSystem: "macOS 15 or later on Apple silicon",
  downloadUrl: download,
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  license,
  author: { "@type": "Person", name: "Saidev Dhal" },
  sameAs: [github],
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`dark ${fonts} h-full scroll-smooth antialiased`}
    >
      <body className="grain min-h-full flex flex-col">
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd).replace(/</g, "\\u003c") }} />
        {children}
        {/* Vercel Web Analytics: page views, sent only from the Vercel deployment (never in development). */}
        <Analytics />
      </body>
    </html>
  );
}
