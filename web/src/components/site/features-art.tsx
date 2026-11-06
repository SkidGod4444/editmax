"use client";

import { animate, motion, useInView } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { ease } from "./motion";

const formats = ["H.264 MP4", "10-bit HEVC", "9:16 Shorts", "1:1 Feed", "YouTube chapters", "Batch export"];

/** A batch export: the bar fills, and each format ticks off as the bar passes it. Loops while on screen. */
export function ExportArt() {
  const ref = useRef<HTMLDivElement>(null);
  const seen = useInView(ref, { margin: "-15% 0px" });
  const [p, setP] = useState(1);
  useEffect(() => {
    if (!seen || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const c = animate(0, 1, { duration: 4.2, ease: "linear", repeat: Infinity, repeatDelay: 1.2, onUpdate: setP });
    return () => c.stop();
  }, [seen]);
  return (
    <div ref={ref} className="w-full max-w-[320px]">
      <div className="flex flex-wrap justify-center gap-2">
        {formats.map((f, i) => {
          const ok = p >= (i + 1) / formats.length;
          return (
            <span key={f} className={`inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1.5 font-mono text-[12px] transition-colors duration-300 ${ok ? "border-white/25 bg-white/10 text-white" : "border-white/10 bg-white/[0.03] text-white/50"}`}>
              <svg viewBox="0 0 12 12" className={`size-3 transition-all duration-300 ${ok ? "scale-100 text-white opacity-100" : "scale-50 opacity-0"}`} fill="none" stroke="currentColor" strokeWidth="2" aria-hidden><path d="m2.5 6.5 2.2 2L9.5 3.5" /></svg>
              {f}
            </span>
          );
        })}
      </div>
      <div className="mt-4 flex items-center gap-3 font-mono text-[11px] text-muted-foreground">
        <div className="h-1 flex-1 overflow-hidden rounded-full bg-white/[0.06]">
          <div className="h-full rounded-full bg-sky shadow-[0_0_10px_var(--sky)]" style={{ width: `${p * 100}%` }} />
        </div>
        <span className="w-9 text-right tabular-nums">{Math.round(p * 100)}%</span>
      </div>
    </div>
  );
}

const history = [
  ["Agent", "Add captions"],
  ["You", "Trim DJI_0797.MP4"],
  ["Agent", "Apply look: Golden"],
  ["Agent", "Remove 14 filler words"],
] as const;

/** History, newest first. Point at an older row: the newer ones dim and strike through, which is what restoring
 *  that snapshot would undo. */
export function HistoryArt() {
  const [at, setAt] = useState<number | null>(null);
  return (
    <ul className="w-full max-w-[320px] space-y-1.5" onPointerLeave={() => setAt(null)}>
      {history.map(([who, what], i) => {
        const undone = at !== null && i < at;
        return (
          <motion.li
            key={what}
            initial={{ opacity: 0, x: -12 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.5, ease, delay: 0.15 + (history.length - i) * 0.12 }}
            onPointerEnter={() => setAt(i)}
            className={`flex cursor-default items-center gap-2.5 rounded-lg border px-3 py-2 text-[12px] transition-all duration-300 ${undone ? "border-white/8 opacity-35" : at === i ? "border-white/25 bg-white/10" : "border-white/10 bg-white/[0.05] shadow-[inset_0_1px_0_rgb(255_255_255/0.12)]"}`}
          >
            <span className={`rounded px-1.5 py-0.5 text-[11px] font-medium uppercase ${who === "Agent" ? "bg-sky/25 text-white" : "bg-white/12 text-white/80"}`}>{who}</span>
            <span className={`truncate text-silver ${undone ? "line-through" : ""}`}>{what}</span>
            <span className={`ml-auto inline-flex items-center gap-1 text-[11px] text-white/80 transition-opacity duration-200 ${at === i && i > 0 ? "opacity-100" : "opacity-0"}`}>
              <svg viewBox="0 0 12 12" className="size-3" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden><path d="M2.5 6a3.5 3.5 0 1 0 1-2.5M2.5 2v2h2" /></svg>
              Restore
            </span>
          </motion.li>
        );
      })}
    </ul>
  );
}
