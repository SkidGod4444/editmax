"use client";

import { MotionConfig, motion, type Variants } from "motion/react";
import { useRef, type ReactNode } from "react";

export const ease = [0.2, 0.7, 0.2, 1] as const;

/** Reduced motion, when the viewer asks for it: transforms off, fades kept. */
export function MotionRoot({ children }: { children: ReactNode }) {
  return <MotionConfig reducedMotion="user">{children}</MotionConfig>;
}

// Opacity and position only: a blur on enter would redraw the whole section (videos and all) every frame of the rise.
const rise = { opacity: 0, y: 18 };
const rest = { opacity: 1, y: 0 };
const view = { once: true, margin: "0px 0px -10% 0px" };

/** Rises into place the first time it scrolls into view. */
export function Reveal({ children, className, delay = 0 }: { children: ReactNode; className?: string; delay?: number }) {
  return (
    <motion.div className={className} initial={rise} whileInView={rest} viewport={view} transition={{ duration: 0.8, ease, delay }}>
      {children}
    </motion.div>
  );
}

const group: Variants = { hidden: {}, show: { transition: { staggerChildren: 0.08 } } };
const item: Variants = { hidden: rise, show: { ...rest, transition: { duration: 0.8, ease } } };

/** Children marked RevealItem arrive one after another. With `spotlight`, every `.spot` inside lights where the pointer is. */
export function RevealGroup({ children, className, spotlight }: { children: ReactNode; className?: string; spotlight?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const move = (e: React.PointerEvent) => {
    if (!spotlight || !ref.current) return;
    for (const el of ref.current.querySelectorAll<HTMLElement>(".spot")) {
      const r = el.getBoundingClientRect();
      el.style.setProperty("--mx", `${e.clientX - r.left}px`);
      el.style.setProperty("--my", `${e.clientY - r.top}px`);
    }
  };
  return (
    <motion.div ref={ref} onPointerMove={move} className={className} variants={group} initial="hidden" whileInView="show" viewport={view}>
      {children}
    </motion.div>
  );
}
export function RevealItem({ children, className }: { children: ReactNode; className?: string }) {
  return <motion.div className={className} variants={item}>{children}</motion.div>;
}
