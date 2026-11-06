/** Frames as HH:MM:SS:FF at 24 fps. Plain module, so server and client components can both use it. */
export const timecode = (frames: number, fps = 24) => {
  const f = Math.max(0, Math.floor(frames));
  const s = Math.floor(f / fps);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(Math.floor(s / 3600))}:${p(Math.floor(s / 60) % 60)}:${p(s % 60)}:${p(f % fps)}`;
};
