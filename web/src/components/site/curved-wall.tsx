"use client";

import { useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";

// Clips and stills from the EditMax projects behind this page (4K Pexels footage, cut and graded in EditMax), as
// 640 px tiles. Seven sports-and-looks repeat every seven cards, so the same one is never on screen twice (about six
// cards show at once), and clips alternate with stills so motion is spread round the whole wall.
const tiles: ({ video: string } | { still: number })[] = [
  { video: "surf" }, { still: 2 }, { video: "parkour" }, { still: 18 }, { video: "motocross" }, { still: 8 }, { still: 13 },
  { still: 15 }, { video: "mtb" }, { still: 6 }, { video: "ski" }, { still: 3 }, { video: "snowboard" }, { still: 11 },
]

type Dims = { R: number; d: number; P: number; w: number; h: number; step: number; max: number };
// Sized for a 1440 px page and scaled down with it. The eye sits a quarter radius in front of the cylinder's axis, so the
// far cards in the middle are about half the size of the near ones at the edges.
const dimsFor = (width: number): Dims => {
  const f = width < 640 ? 0.7 : Math.min(1, Math.max(0.6, width / 1440));
  return { R: 900 * f, d: 375 * f, P: 600 * f, w: 320 * f, h: 420 * f, step: width < 640 ? 24 : 21, max: 66 };
};
// Only the clips near the middle play; the rest show their first frame. At most three decode at once.
const PLAY_WITHIN = 32;

/** The inside of a slowly turning cylinder of clips, seen from near its centre: the far ones in the middle are small, the
 *  near ones at the edges large and turned toward you. Drag to spin it. It only animates while on screen, and stands
 *  still under reduced motion. */
export function CurvedWall() {
  const stage = useRef<HTMLDivElement>(null);
  const cards = useRef<(HTMLDivElement | null)[]>([]);
  const videos = useRef<(HTMLVideoElement | null)[]>([]);
  const angle = useRef(0);
  const drag = useRef<{ x: number; a: number } | null>(null);
  const [dims, setDims] = useState<Dims>(dimsFor(1440));
  const reduce = useReducedMotion();

  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setDims(dimsFor(el.offsetWidth)));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const { R, d, step, max } = dims, span = tiles.length * step;
    let raf = 0, visible = false, last = 0;
    const place = () => {
      cards.current.forEach((c, i) => {
        if (!c) return;
        const th = ((((i - tiles.length / 2) * step + angle.current) % span) + span * 1.5) % span - span / 2;
        const off = Math.abs(th) - (max - 10);
        c.style.opacity = Math.abs(th) > max ? "0" : off > 0 ? String(1 - off / 10) : "1";
        c.style.transform = `translate(-50%, -50%) translateZ(${d}px) rotateY(${th}deg) translateZ(${-R}px)`;
        const v = videos.current[i];
        if (!v) return;
        const want = visible && !reduce && Math.abs(th) < PLAY_WITHIN;
        if (want && v.paused) v.play().catch(() => {});
        else if (!want && !v.paused) v.pause();
      });
    };
    const frame = (now: number) => {
      const dt = Math.min(now - (last || now), 50);
      last = now;
      if (!drag.current && !reduce) angle.current += dt * 0.0035;
      place();
      raf = requestAnimationFrame(frame);
    };
    const run = () => {
      cancelAnimationFrame(raf);
      last = 0;
      if (visible && !document.hidden) raf = requestAnimationFrame(frame);
      else place();
    };
    const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting; run(); });
    io.observe(el);
    document.addEventListener("visibilitychange", run);
    place();
    return () => { io.disconnect(); document.removeEventListener("visibilitychange", run); cancelAnimationFrame(raf); };
  }, [dims, reduce]);

  return (
    <div
      ref={stage}
      className="relative h-[310px] cursor-grab touch-pan-y overflow-hidden select-none active:cursor-grabbing sm:h-[360px] lg:h-[440px] [mask-image:linear-gradient(90deg,transparent,#000_6%,#000_94%,transparent)]"
      style={{ perspective: `${dims.P}px` }}
      onPointerDown={(e) => { drag.current = { x: e.clientX, a: angle.current }; e.currentTarget.setPointerCapture(e.pointerId); }}
      onPointerMove={(e) => { if (drag.current) angle.current = drag.current.a - (e.clientX - drag.current.x) * 0.09; }}
      onPointerUp={() => { drag.current = null; }}
      onPointerCancel={() => { drag.current = null; }}
      aria-label="Clips cut and graded in EditMax; drag to turn"
      role="img"
    >
      {tiles.map((t, i) => (
        <div
          key={i}
          ref={(el) => { cards.current[i] = el; }}
          className="frame absolute top-1/2 left-1/2 rounded-[20px] will-change-transform"
          style={{ width: dims.w, height: dims.h, opacity: 0 }}
        >
          {"video" in t ? (
            <video
              ref={(el) => { videos.current[i] = el; }}
              src={`/tiles/${t.video}.mp4`}
              poster={`/tiles/${t.video}.webp`}
              muted
              loop
              playsInline
              preload="none"
              aria-hidden
              className="pointer-events-none size-full object-cover"
            />
          ) : (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={`/stills/s${t.still}.webp`} alt="" width={520} height={292} draggable={false} decoding="async" className="pointer-events-none size-full object-cover" />
          )}
        </div>
      ))}
    </div>
  );
}
