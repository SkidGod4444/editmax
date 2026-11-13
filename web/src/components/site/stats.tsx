"use client";

import { animate, useInView } from "motion/react";
import { useEffect, useRef } from "react";

function Count({ to, suffix = "" }: { to: number; suffix?: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const seen = useInView(ref, { once: true });
  useEffect(() => {
    if (!seen || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const c = animate(0, to, { duration: 1.4, ease: [0.2, 0.7, 0.2, 1], onUpdate: (v) => { if (ref.current) ref.current.textContent = `${Math.round(v)}${suffix}`; } });
    return () => c.stop();
  }, [seen, to, suffix]);
  return <span ref={ref}>{`${to}${suffix}`}</span>;
}

const stats = [
  { n: 118, label: "MCP tools your agent can call" },
  { n: 6, label: "built-in looks, or any .cube LUT" },
  { n: 6, label: "caption styles from the words spoken" },
  { n: 100, suffix: "%", label: "on-device transcription" },
];

export function Stats() {
  return (
    <div className="glass mx-auto grid max-w-5xl grid-cols-2 overflow-hidden rounded-3xl md:grid-cols-4">
      {stats.map((s, i) => (
        <div key={s.label} className={`px-6 py-8 text-center ${i % 2 ? "border-l border-hairline" : ""} ${i > 1 ? "border-t border-hairline md:border-t-0" : ""} ${i === 2 ? "md:border-l" : ""}`}>
          <div className="text-[48px] leading-none font-light tracking-[-0.04em] text-white tabular-nums"><Count to={s.n} suffix={s.suffix} /></div>
          <div className="mt-3 text-[13px] text-pretty text-white/65">{s.label}</div>
        </div>
      ))}
    </div>
  );
}
