"use client";

import { useMotionValueEvent, useScroll } from "motion/react";
import { useRef } from "react";
import { timecode } from "./tc";

/** Where you are on the page, as a timecode: the whole page is one minute at 24 fps. */
export function ScrollTimecode({ className }: { className?: string }) {
  const { scrollYProgress } = useScroll();
  const ref = useRef<HTMLSpanElement>(null);
  // Written only when the shown frame changes, so a scroll does not re-lay the nav out on every event.
  useMotionValueEvent(scrollYProgress, "change", (v) => {
    const t = timecode(v * 60 * 24);
    if (ref.current && ref.current.textContent !== t) ref.current.textContent = t;
  });
  return <span ref={ref} className={className}>00:00:00:00</span>;
}
