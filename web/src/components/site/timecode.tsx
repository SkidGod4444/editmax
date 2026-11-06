"use client";

import { useEffect, useRef } from "react";
import { timecode } from "./tc";

/** A recording timecode that runs from page load at 24 fps. It only ticks while on screen, and only writes when the
 *  frame number changes. */
export function Timecode({ className }: { className?: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const t0 = performance.now();
    let raf = 0, shown = -1;
    const tick = (now: number) => {
      const f = Math.floor(((now - t0) / 1000) * 24);
      if (f !== shown) { shown = f; el.textContent = timecode(f); }
      raf = requestAnimationFrame(tick);
    };
    const io = new IntersectionObserver(([e]) => {
      cancelAnimationFrame(raf);
      if (e.isIntersecting) raf = requestAnimationFrame(tick);
    });
    io.observe(el);
    return () => { io.disconnect(); cancelAnimationFrame(raf); };
  }, []);
  return <span ref={ref} className={className}>00:00:00:00</span>;
}
