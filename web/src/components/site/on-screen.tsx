"use client";

import { type ReactNode, useEffect, useRef } from "react";

/** Holds every looping animation inside it (CSS and SVG) while it is off screen, so nothing below the fold keeps
 *  repainting while you read something else. */
export function OnScreen({ children, className }: { children: ReactNode; className?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => {
      el.toggleAttribute("data-off", !e.isIntersecting);
      el.querySelectorAll("svg").forEach((s) => (e.isIntersecting ? s.unpauseAnimations() : s.pauseAnimations()));
    }, { rootMargin: "120px" });
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return <div ref={ref} className={className}>{children}</div>;
}
