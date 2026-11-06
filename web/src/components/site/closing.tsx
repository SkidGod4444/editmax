import Image from "next/image";
import { DownloadButton, DownloadNote } from "./download";
import { commercial, license, repo } from "./links";
import { Reveal } from "./motion";

const readme = (anchor: string) => `${repo}#${anchor}`;
const columns: [string, [string, string][]][] = [
  ["Product", [["Features", "#features"], ["Looks", "#looks"], ["Agents", "#agents"], ["Release notes", `${repo}/releases`]]],
  ["Docs", [["Install", readme("install")], ["Editing guide", readme("editing-guide")], ["Work with an agent", readme("work-with-an-agent")], ["MCP tools", readme("the-tools")]]],
  ["Open source", [["Source code", repo], ["Report an issue", `${repo}/issues`], ["Contributing", readme("contributing")], ["Build it yourself", readme("build")]]],
  ["Legal", [["License", license], ["Commercial license", commercial], ["Third-party notices", `${repo}/blob/main/THIRD-PARTY-NOTICES.md`]]],
];

export function Closing() {
  return (
    <section id="license" className="relative isolate scroll-mt-24 overflow-hidden">
      {/* The hero's overhead light once more, faded in at the top so it has no edge. */}
      <div aria-hidden className="light-hero pointer-events-none absolute inset-x-0 top-0 -z-10 h-[900px]" style={{ maskImage: "linear-gradient(transparent, #000 30%, #000 55%, transparent)", WebkitMaskImage: "linear-gradient(transparent, #000 30%, #000 55%, transparent)" }} />
      <div className="mx-auto max-w-6xl px-4 py-24 text-center sm:px-6 sm:py-32">
        <Reveal className="mx-auto max-w-2xl">
          <p className="font-mono text-[12px] tracking-[0.16em] text-white/50 uppercase">Let&apos;s start</p>
          <h2 className="mt-3 text-[44px] leading-[1] font-light tracking-[-0.04em] text-balance sm:text-[72px]">
            Cut your <span className="font-heading tracking-[-0.02em] italic">next</span> video
          </h2>
          <p className="mx-auto mt-6 max-w-xl text-[16px] leading-relaxed text-pretty text-white/65 sm:text-[17px]">
            Source-available under the PolyForm Noncommercial license: free for personal use, charities, schools, public research
            and noncommercial open source. Using it to make money needs a{" "}
            <a href={commercial} className="text-white underline decoration-white/30 underline-offset-4 transition-colors hover:decoration-white">commercial license</a>.
          </p>
          <div className="mt-9 flex flex-wrap justify-center gap-3">
            <DownloadButton className="h-11 px-6 text-[15px] font-medium" />
            <a href={repo} className="btn btn-glass group h-11 px-6 text-[15px]">
              View the source <span aria-hidden className="transition-transform duration-300 group-hover:translate-x-0.5">→</span>
            </a>
          </div>
          <DownloadNote className="mt-4 text-[13px] text-white/55" macText="Needs macOS 15 or later on Apple silicon (M1 or later)." />
        </Reveal>
      </div>

      <footer className="glass @container relative mx-3 mb-3 overflow-hidden rounded-3xl sm:mx-6 sm:mb-6 lg:mx-auto lg:max-w-6xl">
        <div className="grid gap-10 p-6 sm:p-10 lg:grid-cols-[1.5fr_repeat(4,1fr)] lg:gap-8">
          <div className="max-w-xs">
            <a href="#top" className="inline-flex items-center gap-2.5 text-[17px] font-medium">
              <Image src="/icon.png" alt="" width={30} height={30} className="rounded-[8px]" />
              EditMax
            </a>
            <p className="mt-3 text-[14px] leading-relaxed text-balance text-white/60">The native macOS video editor your agent can drive.</p>
            <p className="mt-4 font-mono text-[11px] tracking-[0.08em] text-white/40">macOS 15+ · Apple silicon</p>
            <a href={repo} className="btn btn-glass mt-6 h-9 gap-2 px-4 text-[13px]">
              <svg viewBox="0 0 16 16" className="size-4" fill="currentColor" aria-hidden><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" /></svg>
              Star on GitHub
            </a>
          </div>
          <nav aria-label="Footer" className="grid grid-cols-2 gap-x-6 gap-y-9 sm:grid-cols-4 lg:contents">
            {columns.map(([title, links]) => (
              <div key={title}>
                <p className="font-mono text-[11px] tracking-[0.16em] text-white/45 uppercase">{title}</p>
                <ul className="mt-4 space-y-3">
                  {links.map(([label, href]) => (
                    <li key={label}>
                      <a href={href} className="group inline-flex items-center gap-1 text-[14px] text-white/65 transition-colors hover:text-white">
                        {label}
                        {!href.startsWith("#") && (
                          <span aria-hidden className="text-[11px] opacity-0 transition-opacity group-hover:opacity-60">↗</span>
                        )}
                      </a>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </nav>
        </div>

        {/* The name, as wide as the panel (sized in container units), lit from above like everything else on the page. */}
        <p aria-hidden className="pointer-events-none px-4 text-center text-[28cqw] leading-[0.82] font-light tracking-[-0.065em] select-none sm:px-8">
          <span className="bg-gradient-to-b from-white/45 via-white/15 to-white/[0.02] bg-clip-text text-transparent">EditMax</span>
        </p>

        <div className="flex flex-col gap-4 border-t border-white/[0.08] px-6 py-5 text-[12px] text-white/45 sm:flex-row sm:items-center sm:justify-between sm:px-10">
          <p>
            © 2026 Saidev Dhal. Source-available under the{" "}
            <a href={license} className="underline decoration-white/20 underline-offset-4 transition-colors hover:text-white hover:decoration-white/60">PolyForm Noncommercial License 1.0.0</a>.
          </p>
          <a href="#top" className="btn btn-glass h-8 gap-1.5 self-start px-3.5 text-[12px] text-white/80 hover:text-white sm:self-auto">
            Back to top <span aria-hidden>↑</span>
          </a>
        </div>
      </footer>
    </section>
  );
}
