"use client";

import { motion, useMotionValueEvent, useScroll } from "motion/react";
import Image from "next/image";
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { DownloadButton } from "./download";
import { docs, repo } from "./links";
import { trackGlassPointer, useLiquidGlass } from "./liquid-glass";
import { ScrollTimecode } from "./scroll-ruler";

const items = [
  { href: "#features", label: "Features" },
  { href: "#agents", label: "Agents" },
  { href: docs, label: "Docs" },
  { href: "#license", label: "License" },
];

/** Which section is under the middle of the screen. */
function useActiveSection(ids: string[]) {
  const [active, setActive] = useState<string | null>(null);
  useEffect(() => {
    const io = new IntersectionObserver(
      (es) => es.forEach((e) => { if (e.isIntersecting) setActive(`#${e.target.id}`); else if (`#${e.target.id}` === active) setActive(null); }),
      { rootMargin: "-45% 0px -50% 0px" },
    );
    ids.forEach((id) => { const el = document.querySelector(id); if (el) io.observe(el); });
    return () => io.disconnect();
  }, [ids, active]);
  return active;
}

const sections = ["#features", "#agents", "#license"];

/** The navbar: one floating pill of liquid glass. A lozenge slides to the link under the pointer, and rests on the
 *  section being read. */
export function Nav() {
  const ref = useRef<HTMLElement>(null);
  const glass = useLiquidGlass(ref);
  const active = useActiveSection(sections);
  const [hover, setHover] = useState<string | null>(null);
  const [scrolled, setScrolled] = useState(false);
  const { scrollY } = useScroll();
  useMotionValueEvent(scrollY, "change", (v) => setScrolled(v > 24));
  const lit = hover ?? active;

  return (
    <header
      ref={ref}
      style={glass.style}
      onPointerMove={trackGlassPointer}
      data-scrolled={scrolled || undefined}
      className="lg fixed inset-x-0 top-3 z-50 mx-auto flex h-14 w-fit max-w-[calc(100%-1.5rem)] items-center gap-2 rounded-full py-2 pr-2 pl-3 sm:top-4 sm:gap-5"
    >
      {glass.filter}
      <span aria-hidden className="lg-rim" />
      <span aria-hidden className="lg-spec" />

      <Link href="/" className="group relative flex shrink-0 items-center gap-2.5 pr-1 text-[15px] font-semibold tracking-tight">
        <Image src="/icon.png" alt="" width={26} height={26} className="rounded-[7px] transition-transform duration-500 group-hover:rotate-[-8deg] group-hover:scale-110" />
        EditMax
      </Link>

      <nav className="relative hidden items-center md:flex" onPointerLeave={() => setHover(null)}>
        {items.map((i) => (
          <a
            key={i.label}
            href={i.href}
            onPointerEnter={() => setHover(i.href)}
            onFocus={() => setHover(i.href)}
            onBlur={() => setHover(null)}
            className={`relative rounded-full px-3.5 py-1.5 text-[14px] transition-colors duration-200 ${lit === i.href ? "text-white" : "text-white/70"}`}
          >
            {lit === i.href && (
              <motion.span
                layoutId="nav-lozenge"
                transition={{ type: "spring", stiffness: 420, damping: 34, mass: 0.6 }}
                className="absolute inset-0 rounded-full bg-white/[0.13] shadow-[inset_0_1px_0_rgb(255_255_255/0.4),inset_0_0_0_1px_rgb(255_255_255/0.08),0_2px_10px_rgb(0_0_0/0.25)]"
              />
            )}
            <span className="relative">{i.label}</span>
          </a>
        ))}
      </nav>

      <div className="relative flex items-center gap-1.5 sm:gap-2">
        <span className="hidden items-center gap-1.5 px-1 font-mono text-[11px] text-white/60 lg:flex" title="Where you are on the page, as timecode">
          <span className="size-1.5 rounded-full bg-sky shadow-[0_0_8px_var(--sky)]" />
          <ScrollTimecode className="tabular-nums" />
        </span>
        <a href={repo} aria-label="EditMax on GitHub" className="press grid size-9 place-items-center rounded-full text-white/75 transition-colors hover:bg-white/10 hover:text-white">
          <svg viewBox="0 0 16 16" className="size-[18px]" fill="currentColor" aria-hidden>
            <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
          </svg>
        </a>
        <DownloadButton compact className="h-10 px-4 text-[14px] font-medium" />
      </div>

    </header>
  );
}
