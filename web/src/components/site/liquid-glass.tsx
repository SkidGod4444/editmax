"use client";

import { type CSSProperties, type PointerEvent, type RefObject, useEffect, useId, useState } from "react";

/** A lens displacement map for a rounded rectangle: neutral grey inside, and in a band along the rim red and green
 *  push the sample toward the centre, so what sits behind the edge bends like it would under a thick glass. */
function lensMap(w: number, h: number, r: number, band: number) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const ctx = c.getContext("2d")!;
  const img = ctx.createImageData(w, h);
  const d = img.data;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const px = x + 0.5 - w / 2, py = y + 0.5 - h / 2;
      const qx = Math.abs(px) - (w / 2 - r), qy = Math.abs(py) - (h / 2 - r);
      const depth = r - (Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0)); // into the shape
      let dx = 0, dy = 0;
      if (depth < band) {
        let nx: number, ny: number;
        if (qx > 0 && qy > 0) { const l = Math.hypot(qx, qy) || 1; nx = (qx / l) * Math.sign(px); ny = (qy / l) * Math.sign(py); }
        else if (qx > qy) { nx = Math.sign(px); ny = 0; }
        else { nx = 0; ny = Math.sign(py); }
        const m = (1 - Math.max(depth, 0) / band) ** 2;
        dx = -nx * m; dy = -ny * m;
      }
      const i = (y * w + x) * 4;
      d[i] = 128 + dx * 127; d[i + 1] = 128 + dy * 127; d[i + 2] = 128; d[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  return c.toDataURL();
}

/** Liquid glass for one element. Every browser gets the blur, saturation and lit rim from the `.lg` class; Chromium,
 *  the only engine that runs an SVG filter as a backdrop-filter, also gets the rim refraction. Safari is told apart by
 *  navigator.userAgentData (Chromium only), set on <html> after hydration so the server render is the plain glass.
 *  `?glass=plain` forces the plain path, to check what Safari shows. */
export function useLiquidGlass(ref: RefObject<HTMLElement | null>, { band = 24, scale = 70, blur = 3 } = {}) {
  const id = "lg" + useId().replace(/[^a-zA-Z0-9_-]/g, "");
  const [map, setMap] = useState<{ w: number; h: number; src: string } | null>(null);

  useEffect(() => {
    const html = document.documentElement;
    const plain = new URLSearchParams(location.search).get("glass") === "plain";
    if (plain || !("userAgentData" in navigator)) { html.dataset.glass = "plain"; return; }
    html.dataset.glass = "refract";
    const el = ref.current;
    if (!el) return;
    let last = "";
    const ro = new ResizeObserver(() => {
      const w = Math.round(el.offsetWidth), h = Math.round(el.offsetHeight);
      if (!w || !h || `${w}x${h}` === last) return;
      last = `${w}x${h}`;
      const r = Math.min(h / 2, w / 2, parseFloat(getComputedStyle(el).borderTopLeftRadius) || h / 2);
      setMap({ w, h, src: lensMap(w, h, r, band) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [band, ref]);

  const filter = map && (
    <svg aria-hidden width="0" height="0" className="pointer-events-none absolute">
      <filter id={id} x="0" y="0" width={map.w} height={map.h} filterUnits="userSpaceOnUse" colorInterpolationFilters="sRGB">
        <feImage href={map.src} x="0" y="0" width={map.w} height={map.h} preserveAspectRatio="none" result="lens" />
        <feDisplacementMap in="SourceGraphic" in2="lens" scale={scale} xChannelSelector="R" yChannelSelector="G" />
      </filter>
    </svg>
  );
  const style = (map ? { "--lg-filter": `url(#${id}) blur(${blur}px) saturate(190%) brightness(1.06)` } : {}) as CSSProperties;
  return { filter, style };
}

/** Moves the glass's highlight (.lg-spec) to the pointer. */
export function trackGlassPointer(e: PointerEvent<HTMLElement>) {
  const b = e.currentTarget.getBoundingClientRect();
  e.currentTarget.style.setProperty("--px", `${e.clientX - b.left}px`);
  e.currentTarget.style.setProperty("--py", `${e.clientY - b.top}px`);
}
