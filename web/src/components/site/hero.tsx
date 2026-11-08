import type { CSSProperties } from "react";
import { CurvedWall } from "./curved-wall";
import { DownloadButton, DownloadNote } from "./download";
import { repo } from "./links";
import { PromptDemo } from "./prompt-demo";

/** The overhead light on black and the pitch, then a curved wall of clips cut in EditMax and the prompt bar that could
 *  have asked for them. */
export function Hero() {
  return (
    <section className="relative isolate overflow-hidden pt-24 sm:pt-28">
      <div aria-hidden className="light-hero pointer-events-none absolute inset-x-0 top-0 -z-10 h-[1100px]" />
      <div className="mx-auto max-w-6xl px-5 text-center sm:px-6">
        <div className="rise flex justify-center">
          <a href="#features" className="btn btn-glass group gap-2.5 py-1 pr-3.5 pl-1 text-[13px] text-white/90">
            <span className="rounded-full bg-white px-2 py-0.5 text-[11px] font-semibold text-black">New</span>
            <span className="sm:hidden">0.2.0: color, effects, 115 tools</span>
            <span className="hidden sm:inline">0.2.0: color grading, effects, a mixer and 115 MCP tools</span>
            <span aria-hidden className="text-white/60 transition-transform duration-300 group-hover:translate-x-0.5">→</span>
          </a>
        </div>
        <div className="rise relative mt-8" style={{ "--d": "0.08s" } as CSSProperties}>
          <h1 className="mx-auto max-w-3xl text-[44px] leading-[1] font-light tracking-[-0.045em] text-balance sm:text-[80px]">
            The video editor your agent can <span className="font-heading tracking-[-0.02em] italic">drive</span>
          </h1>
          <p className="mx-auto mt-5 max-w-xl text-[16px] leading-relaxed text-pretty text-white/70 sm:text-[17px]">
            A native macOS editor. Cut, grade, caption and deliver by hand, by chat, or from Claude Code, Codex and Cursor over MCP.
          </p>
          <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
            <DownloadButton className="h-11 px-6 text-[15px] font-medium" />
            <a href={repo} className="btn btn-glass group h-11 px-6 text-[15px]">
              View the source <span aria-hidden className="transition-transform duration-300 group-hover:translate-x-0.5">→</span>
            </a>
          </div>
          <DownloadNote className="mt-4 text-[12px] text-white/50" macText="Needs macOS 15 or later on Apple silicon (M1 or later). Free for personal use." />
        </div>
      </div>
      <div className="rise mt-8 sm:mt-10" style={{ "--d": "0.18s" } as CSSProperties}>
        <CurvedWall />
      </div>
      <div className="rise mx-auto mt-6 max-w-xl px-5 sm:mt-8" style={{ "--d": "0.26s" } as CSSProperties}>
        <PromptDemo />
      </div>
    </section>
  );
}
