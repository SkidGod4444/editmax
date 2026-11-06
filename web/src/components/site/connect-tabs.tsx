"use client";

import { AnimatePresence, motion } from "motion/react";
import { useState } from "react";
import { ease } from "./motion";

const url = "http://127.0.0.1:19790/mcp";
// The same three snippets EditMax's Agents tab shows, with the real token in place of <token>.
const tabs = [
  { id: "claude", label: "Claude Code", code: `claude mcp add --transport http editmax ${url} \\\n  --header "Authorization: Bearer <token>"`, shell: true },
  { id: "codex", label: "Codex", code: `codex mcp add editmax --url ${url} --bearer-token <token>`, shell: true },
  {
    id: "json",
    label: "Any MCP client",
    code: `{\n  "mcpServers": {\n    "editmax": {\n      "type": "http",\n      "url": "${url}",\n      "headers": { "Authorization": "Bearer <token>" }\n    }\n  }\n}`,
    shell: false,
  },
];

export function ConnectTabs() {
  const [tab, setTab] = useState(tabs[0].id);
  const [copied, setCopied] = useState(false);
  const t = tabs.find((x) => x.id === tab)!;
  const copy = async () => {
    try { await navigator.clipboard.writeText(t.code); setCopied(true); setTimeout(() => setCopied(false), 1600); } catch { /* no clipboard: nothing to show */ }
  };
  return (
    <div className="glass mx-auto mt-14 max-w-3xl overflow-hidden rounded-3xl">
      <div className="flex items-center gap-1 overflow-x-auto border-b border-hairline px-2 pt-2">
        {tabs.map((x) => (
          <button key={x.id} type="button" onClick={() => setTab(x.id)} className={`press relative shrink-0 rounded-t-md px-3 pt-1.5 pb-2.5 text-[12.5px] whitespace-nowrap transition-colors ${tab === x.id ? "text-foreground" : "text-muted-foreground hover:text-silver"}`}>
            {x.label}
            {tab === x.id && <motion.span layoutId="tab-underline" className="absolute inset-x-2 -bottom-px h-[2px] rounded-full bg-sky" transition={{ duration: 0.35, ease }} />}
          </button>
        ))}
        <button type="button" onClick={copy} aria-label="Copy the command" className="btn btn-glass mb-1.5 ml-auto h-7 shrink-0 gap-1.5 px-3 text-[12px] text-white/85 hover:text-white">
          <AnimatePresence mode="wait" initial={false}>
            {copied ? (
              <motion.span key="ok" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} className="inline-flex items-center gap-1.5 text-glow">
                <svg viewBox="0 0 12 12" className="size-3" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden><path d="m2.5 6.5 2.2 2L9.5 3.5" /></svg> Copied
              </motion.span>
            ) : (
              <motion.span key="copy" initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.6 }} className="inline-flex items-center gap-1.5">
                <svg viewBox="0 0 12 12" className="size-3" fill="none" stroke="currentColor" strokeWidth="1.4" aria-hidden><rect x="3.5" y="3.5" width="6.5" height="6.5" rx="1.2" /><path d="M8.5 3.5V2.5a1 1 0 0 0-1-1H2.5a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1h1" /></svg> Copy
              </motion.span>
            )}
          </AnimatePresence>
        </button>
      </div>
      <AnimatePresence mode="wait" initial={false}>
        <motion.pre key={t.id} initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.22, ease }} className="min-h-[92px] overflow-x-auto px-4 py-4 font-mono text-[13px] leading-relaxed text-silver">
          {t.shell && <span className="text-muted-foreground select-none">$ </span>}
          {t.code}
        </motion.pre>
      </AnimatePresence>
      <div className="border-t border-hairline px-4 py-2.5 text-[12px] text-muted-foreground">EditMax&apos;s Agents tab shows these with your token filled in. The server listens on this Mac only.</div>
    </div>
  );
}
