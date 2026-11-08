"use client";

import posthog from "posthog-js";
import { useState, useSyncExternalStore } from "react";
import { download, github } from "./links";

type Platform = { kind: "mac" } | { kind: "intel" } | { kind: "desktop"; name: string } | { kind: "mobile"; name: string };
type UAData = { platform?: string; getHighEntropyValues?: (hints: string[]) => Promise<{ architecture?: string }> };

/** Which kind of device this is, from the browser. iPads ask for desktop pages and say "Mac", but have touch. */
function detect(): Platform {
  const ua = navigator.userAgent;
  const hint = (navigator as Navigator & { userAgentData?: UAData }).userAgentData?.platform ?? "";
  if (/Android/i.test(ua)) return { kind: "mobile", name: "Android" };
  if (/iPhone|iPod/.test(ua)) return { kind: "mobile", name: "iPhone" };
  if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return { kind: "mobile", name: "iPad" };
  if (/Windows/.test(ua)) return { kind: "desktop", name: "Windows" };
  if (/CrOS/.test(ua)) return { kind: "desktop", name: "ChromeOS" };
  if (/Macintosh|Mac OS X/.test(ua) || /Mac/i.test(hint)) return { kind: "mac" };
  if (/Windows/i.test(hint)) return { kind: "desktop", name: "Windows" };
  if (/Chrome OS/i.test(hint)) return { kind: "desktop", name: "ChromeOS" };
  if (/Linux/.test(ua) || /Linux/i.test(hint)) return { kind: "desktop", name: "Linux" };
  return { kind: "desktop", name: "your computer" };
}
/** Every Mac browser says "Intel Mac OS X", Apple silicon too, so the chip is read elsewhere: the graphics WebGL
 *  reports (Intel, AMD or NVIDIA graphics mean an Intel Mac), and in Chromium the CPU architecture. Where a browser
 *  hides both (some Safari versions), the Mac is taken as Apple silicon and the line under the button says what it needs. */
function intelGraphics(): boolean {
  try {
    const gl = document.createElement("canvas").getContext("webgl");
    const info = gl?.getExtension("WEBGL_debug_renderer_info");
    const name = gl && info ? String(gl.getParameter(info.UNMASKED_RENDERER_WEBGL)) : "";
    gl?.getExtension("WEBGL_lose_context")?.loseContext();
    return /Intel|AMD|Radeon|NVIDIA|GeForce/i.test(name);
  } catch {
    return false;
  }
}

const mac: Platform = { kind: "mac" };
let seen: Platform | null = null;
const listeners = new Set<() => void>();
function current(): Platform {
  if (seen) return seen;
  seen = detect();
  if (seen.kind === "mac") {
    if (intelGraphics()) seen = { kind: "intel" };
    else
      (navigator as Navigator & { userAgentData?: UAData }).userAgentData?.getHighEntropyValues?.(["architecture"])
        .then((v) => {
          if (v.architecture !== "x86") return;
          seen = { kind: "intel" };
          listeners.forEach((l) => l());
        })
        .catch(() => {});
  }
  return seen;
}
const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => { listeners.delete(l); };
};
// The page is static HTML, so the server render is the Mac button; the real platform takes over right after hydration.
const usePlatform = () => useSyncExternalStore(subscribe, current, () => mac);

// The newest release's .dmg, looked up once from GitHub's API when someone shows intent (hover, focus or click). If there
// is no release yet, or the API is unreachable, the button falls back to the releases page.
let lookup: Promise<string> | null = null;
const latestDmg = () =>
  (lookup ??= fetch(`${github.replace("https://github.com/", "https://api.github.com/repos/")}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
    .then((j: { assets?: { name: string; browser_download_url: string }[] }) => j.assets?.find((a) => a.name.endsWith(".dmg"))?.browser_download_url ?? download)
    .catch(() => download));

const apple = (
  <svg viewBox="0 0 17 20" className="size-4" fill="currentColor" aria-hidden>
    <path d="M14.04 10.62c-.02-2.3 1.88-3.4 1.96-3.46-1.07-1.56-2.73-1.77-3.32-1.8-1.41-.14-2.76.83-3.48.83-.72 0-1.82-.81-3-.79-1.54.02-2.97.9-3.76 2.27-1.6 2.78-.41 6.9 1.15 9.16.76 1.1 1.67 2.34 2.86 2.3 1.15-.05 1.58-.74 2.97-.74 1.38 0 1.78.74 2.99.72 1.24-.02 2.02-1.12 2.77-2.23.87-1.28 1.23-2.52 1.25-2.58-.03-.01-2.4-.92-2.42-3.66zM11.76 3.86c.63-.77 1.06-1.83.94-2.89-.91.04-2.02.61-2.67 1.37-.58.67-1.1 1.76-.96 2.8 1.02.08 2.06-.52 2.69-1.28z" />
  </svg>
);

/** The download button. On a Mac it downloads the newest release's disk image directly. On another computer it says
 *  EditMax is coming for that system (Intel Macs included), and on a phone or tablet it is disabled (DownloadNote says to use a Mac). */
export function DownloadButton({ compact = false, className = "" }: { compact?: boolean; className?: string }) {
  const p = usePlatform();
  const [href, setHref] = useState(download);
  const warm = () => { latestDmg().then(setHref); };

  if (p.kind !== "mac") {
    const os = p.kind === "intel" ? "Intel Macs" : p.kind === "desktop" ? p.name : null;
    const label = os ? (compact ? "Coming soon" : `We're coming for ${os}`) : compact ? "Download" : "Download for macOS";
    const why = p.kind === "mobile" ? "Open this page on a Mac to download EditMax" : p.kind === "intel" ? "EditMax needs a Mac with Apple silicon" : "EditMax is macOS only for now";
    return (
      <button type="button" disabled title={why} className={`btn btn-white ${className}`}>
        {label}
      </button>
    );
  }
  return (
    <a
      href={href}
      onPointerEnter={warm}
      onFocus={warm}
      onClick={(e) => {
        const buttonVariant = compact ? "compact" : "full";
        if (process.env.NEXT_PUBLIC_POSTHOG_PROJECT_TOKEN && process.env.NEXT_PUBLIC_POSTHOG_HOST) {
          posthog.capture("download_started", { button_variant: buttonVariant });
          posthog.logger.info("download started", { button_variant: buttonVariant });
        }
        if (href !== download) return; // already the .dmg: let the link download it
        e.preventDefault();
        latestDmg().then((url) => { setHref(url); window.location.assign(url); });
      }}
      className={`btn btn-white ${className}`}
    >
      {!compact && apple}
      {compact ? "Download" : "Download for macOS"}
    </a>
  );
}

/** The line under a download button: the requirements on a Mac, and on anything else where to go instead. With
 *  `macText` unset it says nothing on a Mac. */
export function DownloadNote({ macText, className = "" }: { macText?: string; className?: string }) {
  const p = usePlatform();
  const text =
    p.kind === "mac" ? macText
    : p.kind === "intel" ? "EditMax needs a Mac with Apple silicon (M1 or later). Intel Macs are not supported yet."
    : p.kind === "mobile" ? "Open this page on a Mac to download EditMax."
    : "EditMax is macOS only for now. Open this page on a Mac to download it.";
  return text ? <p className={className}>{text}</p> : null;
}
