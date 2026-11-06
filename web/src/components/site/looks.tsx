"use client";

import { useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { Reveal } from "./motion";
import { Timecode } from "./timecode";

// The same 6 s of a 4K surf clip (Pexels: a barrel ride), exported three times by EditMax, each with a different look.
const looks = [
  { id: "teal", label: "Teal & Orange" },
  { id: "original", label: "Original" },
  { id: "bw", label: "Black & White" },
] as const;
type Look = (typeof looks)[number]["id"];

/** One clip in a framed card with a look switcher on its right edge: switching crossfades to the same moment of another
 *  EditMax export, so the grade is the only thing that changes. */
export function Looks() {
  const [look, setLook] = useState<Look>("teal");
  const videos = useRef<Partial<Record<Look, HTMLVideoElement | null>>>({});
  const section = useRef<HTMLElement>(null);
  const reduce = useReducedMotion();

  // The shown look plays while the hero is on screen; the others rest once the crossfade is over.
  useEffect(() => {
    const el = section.current;
    if (!el || reduce) return;
    const io = new IntersectionObserver(([e]) => {
      const v = videos.current[look];
      if (e.isIntersecting) v?.play().catch(() => {});
      else v?.pause();
    });
    io.observe(el);
    const t = setTimeout(() => looks.forEach((l) => l.id !== look && videos.current[l.id]?.pause()), 800);
    return () => { io.disconnect(); clearTimeout(t); };
  }, [look, reduce]);

  const choose = (next: Look) => {
    if (next === look) return;
    const from = videos.current[look], to = videos.current[next];
    if (from && to) {
      to.currentTime = from.currentTime;
      if (!reduce) to.play().catch(() => {});
    }
    setLook(next);
  };

  return (
    <section id="looks" ref={section} className="relative mx-auto max-w-6xl scroll-mt-24 px-3 pt-24 sm:px-6 sm:pt-32">
      <div className="frame relative isolate h-[560px] rounded-3xl sm:h-[620px]">
        {looks.map((l) => (
          <video
            key={l.id}
            ref={(el) => { videos.current[l.id] = el; }}
            src={`/hero/${l.id}.mp4`}
            poster={`/hero/${l.id}.webp`}
            muted
            loop
            playsInline
            preload={l.id === "teal" ? "metadata" : "none"}
            aria-hidden
            className={`absolute inset-0 -z-10 size-full object-cover transition-opacity duration-700 ${look === l.id ? "opacity-100" : "opacity-0"}`}
          />
        ))}
        <div aria-hidden className="absolute inset-0 -z-10 bg-[linear-gradient(180deg,rgb(0_0_0/0.82),rgb(0_0_0/0.45)_42%,transparent_70%)] sm:bg-[linear-gradient(90deg,rgb(0_0_0/0.78),rgb(0_0_0/0.35)_45%,transparent_75%)]" />
        <div aria-hidden className="absolute inset-x-0 bottom-0 -z-10 h-48 bg-gradient-to-t from-black/80 to-transparent" />

        <div className="flex h-full flex-col justify-between p-6 sm:p-10">
          <Reveal>
            <p className="font-mono text-[12px] tracking-[0.16em] text-white/60 uppercase">Color, by hand or by chat</p>
            <h2 className="mt-4 max-w-md text-[40px] leading-[1] font-light tracking-[-0.04em] text-balance sm:text-[60px]">
              One clip. <span className="font-heading tracking-[-0.02em] italic">Every</span> look.
            </h2>
            <p className="mt-5 max-w-sm text-[15px] leading-relaxed text-pretty text-white/72">
              Six built-in looks, your own LUTs, a five-point curve and wheels. Or ask: &ldquo;make it teal and orange, keep the skin warm.&rdquo;
            </p>
          </Reveal>
          <div aria-hidden className="inline-flex w-fit items-center gap-2 rounded-full bg-black/35 px-3 py-1.5 font-mono text-[11px] tracking-wider text-white/75 shadow-[inset_0_0_0_1px_rgb(255_255_255/0.1)] backdrop-blur-md">
            <span className="blink size-1.5 rounded-full bg-sky shadow-[0_0_8px_var(--sky)]" /> <Timecode className="tabular-nums" />
            <span className="text-white/45">· 4K · graded in EditMax</span>
          </div>
        </div>

        <div role="radiogroup" aria-label="Look, graded in EditMax" className="absolute right-4 bottom-16 flex flex-col items-end gap-2 sm:top-1/2 sm:right-8 sm:bottom-auto sm:-translate-y-1/2">
          {looks.map((l) => (
            <button
              key={l.id}
              type="button"
              role="radio"
              aria-checked={look === l.id}
              onClick={() => choose(l.id)}
              onPointerEnter={() => { const v = videos.current[l.id]; if (v && v.preload !== "auto") v.preload = "auto"; }}
              className={`btn px-4 py-1.5 text-[13px] ${look === l.id ? "btn-white" : "btn-glass text-white/90 hover:text-white"}`}
            >
              {l.label}
            </button>
          ))}
        </div>
      </div>
    </section>
  );
}
