"use client";

import { useReducedMotion } from "motion/react";
import { useEffect, useRef } from "react";

/** A short muted loop that only loads and plays while it is on screen. Under reduced motion it stays on its poster. */
export function LoopVideo({ src, poster, className }: { src: string; poster: string; className?: string }) {
  const ref = useRef<HTMLVideoElement>(null);
  const reduce = useReducedMotion();
  useEffect(() => {
    const v = ref.current;
    if (!v || reduce) return;
    const io = new IntersectionObserver(([e]) => { if (e.isIntersecting) v.play().catch(() => {}); else v.pause(); }, { rootMargin: "200px" });
    io.observe(v);
    return () => io.disconnect();
  }, [reduce]);
  return <video ref={ref} src={src} poster={poster} muted loop playsInline preload="none" aria-hidden className={className} />;
}
