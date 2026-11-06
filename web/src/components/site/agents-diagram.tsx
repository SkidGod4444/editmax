"use client";

import Image from "next/image";
import { useState } from "react";

const agents = ["Claude Code", "Codex", "Cursor", "OpenCode", "Grok", "Antigravity"];
const abilities = ["Cut and trim", "Color and looks", "Captions", "Sound", "Export", "The window itself"];

// Geometry in the 1000×420 box the container keeps: chips at a 66-unit pitch, wires into pins on the hub's sides.
const W = 1000, H = 420, hub = { x: 500, y: 210, r: 48 };
const ys = agents.map((_, i) => 45 + i * 66);
const pin = (i: number) => hub.y + (i - 2.5) * 9;
const leftWire = (i: number) => `M 232 ${ys[i]} C 340 ${ys[i]}, 360 ${pin(i)}, ${hub.x - hub.r - 6} ${pin(i)}`;
const rightWire = (i: number) => `M ${hub.x + hub.r + 6} ${pin(i)} C 640 ${pin(i)}, 660 ${ys[i]}, 768 ${ys[i]}`;
const pct = (v: number, of: number) => `${(v / of) * 100}%`;

/** Every agent wired into EditMax, and EditMax wired into every kind of edit. Point at a chip: its wire lights,
 *  the others fade, and a faster signal runs down it. */
export function AgentsDiagram() {
  const [hot, setHot] = useState<{ side: "l" | "r"; i: number } | null>(null);
  const lit = (side: "l" | "r", i: number) => hot === null || (hot.side === side && hot.i === i);

  const wire = (side: "l" | "r", i: number) => {
    const d = side === "l" ? leftWire(i) : rightWire(i);
    const on = hot?.side === side && hot.i === i;
    return (
      <g key={side + i} style={{ opacity: lit(side, i) ? 1 : 0.25, transition: "opacity 300ms" }}>
        <path d={d} fill="none" stroke={on ? "#5a9bf0" : `url(#wire-${side})`} strokeWidth={on ? 1.75 : 1.25} style={{ transition: "stroke 300ms" }} />
        <circle className="signal" r={on ? 3 : 2.4} fill="#fff">
          <animateMotion dur={on ? "1.1s" : "2.8s"} begin={`-${(side === "l" ? 0 : 1.4) + i * 0.45}s`} repeatCount="indefinite" path={d} />
        </circle>
      </g>
    );
  };

  const chip = (label: string, i: number, side: "l" | "r") => (
    <div
      key={label}
      onPointerEnter={() => setHot({ side, i })}
      onPointerLeave={() => setHot(null)}
      className={`glass absolute! flex h-9 -translate-y-1/2 cursor-default items-center rounded-full px-4 text-[13px] transition-all duration-300 ${hot?.side === side && hot.i === i ? "text-white shadow-[0_0_24px_rgb(255_255_255/0.18)]" : "text-white/80"} ${lit(side, i) ? "" : "opacity-40"}`}
      style={{ top: pct(ys[i], H), ...(side === "l" ? { right: pct(W - 232, W) } : { left: pct(768, W) }) }}
    >
      {label}
    </div>
  );

  return (
    <>
      <div className="relative mx-auto mt-16 hidden aspect-[1000/420] max-w-5xl sm:block">
        <svg viewBox={`0 0 ${W} ${H}`} className="absolute inset-0 size-full" aria-hidden>
          <defs>
            <linearGradient id="wire-l" x1="0" x2="1"><stop offset="0" stopColor="white" stopOpacity="0.06" /><stop offset="1" stopColor="white" stopOpacity="0.22" /></linearGradient>
            <linearGradient id="wire-r" x1="0" x2="1"><stop offset="0" stopColor="white" stopOpacity="0.22" /><stop offset="1" stopColor="white" stopOpacity="0.06" /></linearGradient>
          </defs>
          {agents.map((_, i) => wire("l", i))}
          {abilities.map((_, i) => wire("r", i))}
          {agents.map((_, i) => (
            <g key={`p${i}`} fill="rgb(255 255 255 / 0.25)">
              <rect x={hub.x - hub.r - 8} y={pin(i) - 2} width="8" height="4" rx="1" />
              <rect x={hub.x + hub.r} y={pin(i) - 2} width="8" height="4" rx="1" />
            </g>
          ))}
        </svg>
        {agents.map((a, i) => chip(a, i, "l"))}
        {abilities.map((a, i) => chip(a, i, "r"))}
        <div
          className={`glass absolute! flex -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-[26px] transition-transform duration-300 ${hot ? "scale-105" : ""}`}
          style={{ left: "50%", top: "50%", width: pct(hub.r * 2, W), aspectRatio: "1" }}
        >
          <Image src="/icon.png" alt="EditMax" width={64} height={64} className="w-[62%] rounded-[14px]" />
        </div>
        <span className="absolute text-[12px] text-white/60" style={{ left: pct(310, W), top: pct(398, H) }}>Your agent</span>
        <span className="absolute text-[12px] text-white/60" style={{ right: pct(310, W), top: pct(398, H) }}>Every edit</span>
      </div>

      {/* Phones: the same facts as two lists. */}
      <div className="mt-12 grid grid-cols-2 gap-6 sm:hidden">
        {([["Your agent", agents], ["Every edit", abilities]] as const).map(([title, list]) => (
          <div key={title}>
            <p className="mb-3 text-[12px] text-muted-foreground">{title}</p>
            <ul className="space-y-2">
              {list.map((l) => <li key={l} className="glass rounded-full px-3.5 py-2 text-[13px] text-white/85">{l}</li>)}
            </ul>
          </div>
        ))}
      </div>
    </>
  );
}
