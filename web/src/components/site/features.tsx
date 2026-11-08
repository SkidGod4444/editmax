import type { ReactNode } from "react";
import { LoopVideo } from "./loop-video";
import { AssetsArt, EffectsArt, ExportArt, HistoryArt } from "./features-art";
import { Reveal, RevealGroup, RevealItem } from "./motion";
import { OnScreen } from "./on-screen";
import { Stats } from "./stats";

function Card({ title, body, className = "", children }: { title: string; body: string; className?: string; children?: ReactNode }) {
  return (
    <RevealItem className={`glass spot group flex flex-col rounded-3xl ${className}`}>
      {children && <div className="relative flex min-h-[170px] flex-1 items-center justify-center overflow-hidden rounded-t-2xl p-5 pb-0">{children}</div>}
      <div className="p-6">
        <h3 className="text-[15px] font-medium text-foreground">{title}</h3>
        <p className="mt-1.5 text-[14px] leading-relaxed text-pretty text-muted-foreground">{body}</p>
      </div>
    </RevealItem>
  );
}

/** A caption read out word by word in the highlight colour over the clip, and below it the transcript losing its filler words. */
function CaptionArt() {
  const words = ["one", "more", "jump", "and", "we're", "done"];
  return (
    <div className="w-full">
      <div className="frame relative flex aspect-[16/8] items-end justify-center rounded-xl pb-6 sm:pb-8">
        <LoopVideo src="/reel/parkour.mp4" poster="/reel/parkour.webp" className="absolute inset-0 size-full object-cover" />
        <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-black/10 to-transparent" />
        <span className="karaoke relative rounded-lg bg-black/70 px-3 py-1.5 text-[15px] font-semibold sm:text-[20px]">
          {words.map((w, i) => <span key={w} style={{ ["--i" as string]: i }}>{w}{i < words.length - 1 ? " " : ""}</span>)}
        </span>
      </div>
      <p className="mt-3 px-1 font-mono text-[12px] leading-relaxed text-muted-foreground">
        transcript: okay <span className="strike">um</span> one more jump and <span className="strike">like</span> we&apos;re done
      </p>
    </div>
  );
}

/** Three tracks under a moving playhead. Hovered, the middle clip ripple-deletes: it closes and the next one slides in. */
function TimelineArt() {
  const clip = "absolute top-0 h-full rounded-[5px] shadow-[inset_0_1px_0_rgb(255_255_255/0.25)] transition-all duration-500 ease-[cubic-bezier(0.2,0.7,0.2,1)]";
  return (
    <div className="relative w-full max-w-[280px] py-2">
      <span className="glass-sm absolute -top-3 right-0 rounded-full px-2 py-0.5 font-mono text-[10px] text-white/80 opacity-0 transition-opacity duration-300 group-hover:opacity-100">ripple_delete</span>
      <div className="space-y-1.5">
        <div className="relative h-6 rounded-md bg-white/[0.03]">
          <div className={`${clip} left-0 w-[38%] bg-white/25`} />
          <div className={`${clip} left-[40%] w-[34%] origin-left bg-sky/85 group-hover:scale-x-0 group-hover:opacity-0`} />
          <div className={`${clip} left-[76%] w-[24%] bg-white/25 group-hover:left-[40%]`} />
        </div>
        <div className="relative h-6 rounded-md bg-white/[0.03]"><div className={`${clip} left-[12%] w-[30%] bg-white/15`} /></div>
        <div className="relative h-6 rounded-md bg-white/[0.03]"><div className={`${clip} left-0 w-full bg-white/[0.09] group-hover:w-[64%]`} /></div>
      </div>
      {/* The playhead rides a full-width layer that slides by transform, so it never re-lays the card out. */}
      <div className="playhead pointer-events-none absolute inset-0">
        <div className="absolute inset-y-0 left-0 w-px bg-white shadow-[0_0_8px_var(--glow)]">
          <div className="absolute -top-1 -left-[4px] size-[9px] rotate-45 rounded-[2px] bg-white" />
        </div>
      </div>
      {["22%", "68%"].map((l) => <div key={l} className="absolute -bottom-1 h-1.5 w-1.5 rounded-full bg-white/70" style={{ left: l }} />)}
    </div>
  );
}

/** Voice above the line, music below it, scrolling past together: the music dips wherever the voice is loud. */
function SoundArt() {
  const voice = [2, 3, 2, 9, 12, 10, 13, 8, 11, 3, 2, 2, 10, 13, 9, 12, 4, 2, 2, 3];
  const strip = (k: string) => (
    <div key={k} className="flex w-1/2 shrink-0 gap-[5px] pr-[5px]">
      {voice.map((v, i) => (
        <div key={i} className="flex flex-1 flex-col">
          <div className="flex h-12 items-end"><div className="w-full rounded-full bg-white/85" style={{ height: v * 3.4 }} /></div>
          <div className="h-[17px]" />
          <div className="flex h-8 items-start"><div className="w-full rounded-full bg-white/30" style={{ height: v > 6 ? 6 : 26 }} /></div>
        </div>
      ))}
    </div>
  );
  return (
    <div className="w-full max-w-[280px]">
      <div className="relative overflow-hidden [mask-image:linear-gradient(90deg,transparent,#000_12%,#000_88%,transparent)]">
        <div className="drift flex w-[200%]">{[strip("a"), strip("b")]}</div>
        <div className="absolute inset-x-0 top-[56px] h-px bg-hairline-strong" />
      </div>
      <div className="mt-2 flex justify-between text-[11px] text-muted-foreground"><span>Voice</span><span>Music, ducked</span></div>
    </div>
  );
}

/** A speed ramp drawn as a keyframed curve, with a dot riding it. */
function MotionArt() {
  const path = "M 10 75 C 60 75, 80 20, 130 20 L 170 20 C 210 20, 220 75, 270 75";
  return (
    <svg viewBox="0 0 280 100" className="w-full max-w-[280px] overflow-visible" aria-hidden>
      {[25, 50, 75].map((y) => <line key={y} x1="0" x2="280" y1={y} y2={y} stroke="white" strokeOpacity="0.05" />)}
      <text x="276" y="16" textAnchor="end" fontSize="9" fill="rgb(255 255 255 / 0.55)" style={{ fontFamily: "var(--font-geist-mono)" }}>2.5×</text>
      <text x="276" y="92" textAnchor="end" fontSize="9" fill="rgb(255 255 255 / 0.55)" style={{ fontFamily: "var(--font-geist-mono)" }}>1×</text>
      <path d={path} fill="none" stroke="rgb(255 255 255 / 0.85)" strokeWidth="2" />
      <path d={path} fill="none" stroke="rgb(255 255 255 / 0.35)" strokeWidth="2" strokeDasharray="4 6" className="opacity-0 transition-opacity duration-300 group-hover:opacity-100" />
      {[[10, 75], [130, 20], [170, 20], [270, 75]].map(([x, y]) => (
        <rect key={x} x={x - 5} y={y - 5} width="10" height="10" rx="2" transform={`rotate(45 ${x} ${y})`} fill="#000" stroke="#fff" strokeWidth="2" className="transition-all duration-300 group-hover:fill-[#5a9bf0] group-hover:stroke-[#5a9bf0]" />
      ))}
      <circle className="signal" r="4" fill="#fff">
        <animateMotion dur="3.2s" repeatCount="indefinite" path={path} keyPoints="0;1" keyTimes="0;1" calcMode="spline" keySplines="0.45 0 0.55 1" />
      </circle>
    </svg>
  );
}

export function Features() {
  return (
    <section id="features" className="relative isolate scroll-mt-24">
      <div className="mx-auto max-w-6xl px-4 py-24 sm:px-6 sm:py-32">
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="font-mono text-[12px] tracking-[0.16em] text-white/50 uppercase">Features</p>
          <h2 className="mt-3 text-[36px] leading-[1.04] font-light tracking-[-0.035em] text-balance sm:text-[56px]">A whole editor, not a <span className="font-heading font-normal tracking-[-0.02em] italic">demo</span></h2>
          <p className="mt-5 text-[17px] leading-relaxed text-pretty text-muted-foreground">
            Everything below works by hand, and every part of it is also a tool your agent can call.
          </p>
        </Reveal>

        <Reveal className="mt-14" delay={0.1}>
          <Stats />
        </Reveal>

        <OnScreen>
        <RevealGroup spotlight className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-6">
          <RevealItem className="glass spot flex flex-col rounded-3xl md:col-span-4">
            <div className="p-3 pb-0">
              <CaptionArt />
            </div>
            <div className="p-6 pt-3">
              <h3 className="text-[15px] font-medium">Captions from the words spoken</h3>
              <p className="mt-1.5 text-[14px] leading-relaxed text-pretty text-muted-foreground">
                On-device transcription, captions in six styles, and cuts by word: remove silences and filler words, or search the
                transcript and cut there.
              </p>
            </div>
          </RevealItem>
          <Card className="md:col-span-2" title="A real timeline" body="Video and audio tracks, ripple edits across every track, roll, slip and slide trims, J and L cuts, insert and overwrite from a source viewer, scene detection, multicam synced by audio, nested sequences and proxies.">
            <TimelineArt />
          </Card>
          <Card className="md:col-span-3" title="Keyframes and speed ramps" body="Keyframes on every transform, color, opacity, volume and speed value, freeze frames, smooth slow motion, auto-reframe for vertical cuts and stabilization.">
            <MotionArt />
          </Card>
          <Card className="md:col-span-3" title="Sound that sits right" body="EQ, compressor, limiter, de-esser, hum removal, voice isolation, a mixer with buses, one-click loudness for YouTube, and music that ducks under speech by itself.">
            <SoundArt />
          </Card>
          <Card className="md:col-span-3" title="Deliver for every format" body="H.264 MP4, ProRes and 10-bit HEVC masters in SDR or HDR, FCPXML and EDL to hand the cut to Resolve or Final Cut, templates for every social format, YouTube chapters from markers.">
            <ExportArt />
          </Card>
          <Card className="md:col-span-3" title="Every agent edit can be undone" body="Each change lands in History with who made it. Point at an older step to see what going back to it would undo.">
            <HistoryArt />
          </Card>
          <Card className="md:col-span-3" title="Titles, keys and effects" body="Animated titles and lower thirds, a green-screen key, 19 blend modes, face blur that follows faces, and transitions from dissolves to iris wipes.">
            <EffectsArt />
          </Card>
          <Card className="md:col-span-3" title="Assets, fonts and the notch" body="Drag a file to the notch at the top of your screen and it lands in Assets, ready for any project. All of Google Fonts for titles, and deleted files wait in the Archive.">
            <AssetsArt />
          </Card>
        </RevealGroup>
        </OnScreen>
      </div>
    </section>
  );
}
