import { commercial } from "./links";
import { Reveal } from "./motion";

type Faq = { q: string; a: string; link?: { href: string; label: string } };

/** What people ask before they hand an agent their timeline. Every answer is checked against the app: change one only
 *  when the app changes. */
const faqs: Faq[] = [
  {
    q: "What if a source file is missing or has moved?",
    a: "Export won't start. It names the missing files, or the drive to plug back in, and points you to File\u00a0▸\u00a0Relink Media, so nothing renders with a gap or a placeholder. The preview keeps playing with a gap where those clips are, and your agent can relink them too.",
  },
  {
    q: "Can I see and undo what the agent did?",
    a: "Yes. Every change, yours or the agent's, lands in History with a line saying what changed and who made it. Point at an older version to see what going back would undo, then restore it. Restoring is itself an edit, so you can undo that too.",
  },
  {
    q: "Does it lock a clip while the agent is cutting it?",
    a: "No. You and the agent edit the same timeline, and each change it makes is its own step. If it changes something you wanted, undo it, or restore an earlier version from History.",
  },
  {
    q: "Does the agent really cut, or just queue edits?",
    a: "It makes real edits on the timeline you're looking at, as it goes. Follow the agent shows each one land: the clip is selected, the playhead moves onto it and the inspector scrolls to the setting that changes.",
  },
  {
    q: "Does the agent know when a cut feels off?",
    a: "It works from what it can measure: word timings in the transcript, silences, scene changes and loudness, and it renders frames to check its own cuts. It doesn't watch the cut play in real time, so for feel, play it back and nudge or undo what's off.",
  },
  {
    q: "Which agents work with it? Do I need an API key?",
    a: "Claude Code, Codex, Cursor or any MCP client, through the server EditMax runs on your Mac. The Chat inside the app uses an agent already installed on your Mac with its own login, so there's nothing to sign up for, or your own API key for Claude, OpenAI, Gemini or Grok.",
  },
  {
    q: "Is it free?",
    a: "Free for personal use, noncommercial organizations and noncommercial open source, under the PolyForm Noncommercial license. Using it at a company, or for videos that are paid or earn money, needs a commercial license.",
    link: { href: commercial, label: "How to get a commercial license" },
  },
  {
    q: "Does my footage leave my Mac?",
    a: "Editing, rendering and transcription run on your Mac, and the MCP server only listens on this Mac. What your agent asks to read, like the timeline, the transcript or a frame, goes to that agent's provider, as with any agent. Crash reports and feature counts never include your footage, your words or file names.",
  },
  {
    q: "Which Macs does it run on, and how do updates work?",
    a: "macOS 15 or later on Apple silicon (M1 or later); Liquid Glass and SpeechAnalyzer captions need macOS 26. From 0.2.0 on, EditMax updates itself. If you have 0.1.1, download the new version once.",
  },
];

const structured = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: faqs.map((f) => ({ "@type": "Question", name: f.q, acceptedAnswer: { "@type": "Answer", text: f.a } })),
};

/** Questions as rows of one glass panel; each opens in place (native details, so it works without JavaScript). */
export function Faq() {
  return (
    <section id="faq" className="relative isolate scroll-mt-24">
      <div className="mx-auto max-w-3xl px-4 py-24 sm:px-6 sm:py-32">
        <Reveal className="text-center">
          <p className="font-mono text-[12px] tracking-[0.16em] text-white/50 uppercase">FAQ</p>
          <h2 className="mt-3 text-[36px] leading-[1.04] font-light tracking-[-0.035em] text-balance sm:text-[56px]">
            Questions, <span className="font-heading font-normal tracking-[-0.02em] italic">answered</span>
          </h2>
          <p className="mt-5 text-[17px] leading-relaxed text-pretty text-muted-foreground">What people ask before they hand an agent their timeline.</p>
        </Reveal>
        <Reveal className="mt-12" delay={0.1}>
          <div className="glass divide-y divide-hairline rounded-3xl">
            {faqs.map((f) => (
              <details key={f.q} className="faq group px-5 sm:px-7">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-5 py-5 text-left text-[15px] font-medium text-white sm:text-[16px] [&::-webkit-details-marker]:hidden">
                  {f.q}
                  <span aria-hidden className="grid size-7 shrink-0 place-items-center rounded-full border border-white/15 text-[16px] leading-none text-white/70 transition-transform duration-300 group-open:rotate-45">+</span>
                </summary>
                <p className="pb-6 text-[15px] leading-relaxed text-pretty text-muted-foreground">
                  {f.a}
                  {f.link && <> <a href={f.link.href} className="text-white underline decoration-white/30 underline-offset-4 hover:decoration-white">{f.link.label}</a></>}
                </p>
              </details>
            ))}
          </div>
        </Reveal>
      </div>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(structured) }} />
    </section>
  );
}
