"use client";

import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { useEffect, useState } from "react";
import { ease } from "./motion";

// What you would ask, and the EditMax tools an agent calls for it (names from the MCP tool list).
const demos = [
  { prompt: "cut the silences, warm up the dusk shot, then caption it", tools: ["detect_silence", "remove_silence", "set_clip_color", "add_captions"] },
  { prompt: "make a vertical cut for Shorts and keep me in frame", tools: ["apply_template", "auto_reframe", "export_video"] },
  { prompt: "duck the music under my voice and add chapters", tools: ["set_ducking", "add_marker", "export_chapters"] },
];

/** The demo in one line: a prompt types itself, then the agent's tool calls run one by one and tick off.
 *  The first one starts complete (that is what renders without script), then they cycle. */
export function PromptDemo() {
  const reduce = useReducedMotion();
  const [n, setN] = useState(0);
  const [chars, setChars] = useState(demos[0].prompt.length);
  const [ran, setRan] = useState(demos[0].tools.length);
  const d = demos[n];

  useEffect(() => {
    if (reduce) return;
    let t: ReturnType<typeof setTimeout>;
    const typing = chars < d.prompt.length;
    if (typing) t = setTimeout(() => setChars((c) => c + 1), 28 + Math.random() * 30);
    else if (ran < d.tools.length) t = setTimeout(() => setRan((r) => r + 1), ran === 0 ? 500 : 650);
    else t = setTimeout(() => { setN((n + 1) % demos.length); setChars(0); setRan(0); }, 2600);
    return () => clearTimeout(t);
  }, [reduce, n, chars, ran, d]);

  const done = ran === d.tools.length;
  return (
    <div className="mx-auto flex w-full max-w-[640px] flex-col items-center gap-3">
      <div className="glass inline-flex max-w-full items-center gap-3 rounded-full py-2 pr-5 pl-2 font-mono text-[13px] text-white">
        <span className="glass-sm rounded-full px-2.5 py-1 font-sans text-[11px] font-medium tracking-wide text-white/75 uppercase">You</span>
        <span className="min-w-0 truncate" style={{ maxWidth: "calc(100vw - 9rem)" }}>{d.prompt.slice(0, chars)}</span>
        <span className={`caret -ml-2 inline-block h-4 w-[7px] shrink-0 rounded-[1px] bg-glow shadow-[0_0_8px_var(--glow)] ${chars < d.prompt.length ? "" : "blink"}`} />
      </div>
      <div className="flex min-h-[30px] flex-wrap justify-center gap-1.5" aria-live="polite">
        <AnimatePresence mode="popLayout">
          {d.tools.slice(0, Math.min(ran + 1, d.tools.length)).map((t, i) =>
            chars < d.prompt.length ? null : (
              <motion.span
                key={`${n}-${t}`}
                layout
                initial={{ opacity: 0, y: 6, scale: 0.96 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                exit={{ opacity: 0, transition: { duration: 0.15 } }}
                transition={{ duration: 0.35, ease }}
                className="glass-sm inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 font-mono text-[11.5px] text-white/90 backdrop-blur-md"
              >
                {i < ran ? (
                  <svg viewBox="0 0 12 12" className="size-3 text-glow" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden><path d="m2.5 6.5 2.2 2L9.5 3.5" /></svg>
                ) : (
                  <span className="size-3 animate-spin rounded-full border-[1.5px] border-glow border-t-transparent" />
                )}
                {t}
              </motion.span>
            ),
          )}
          {done && chars === d.prompt.length && (
            <motion.span key={`${n}-done`} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="px-1 py-1 text-[12px] text-white/65">
              {d.tools.length} edits in History
            </motion.span>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}
