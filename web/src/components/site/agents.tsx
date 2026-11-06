import { AgentsDiagram, ConnectTabs } from "./lazy";
import { Reveal } from "./motion";
import { OnScreen } from "./on-screen";

export function Agents() {
  return (
    <section id="agents" className="relative isolate scroll-mt-24">
      <div className="mx-auto max-w-6xl px-4 py-24 sm:px-6 sm:py-32">
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="font-mono text-[12px] tracking-[0.16em] text-white/50 uppercase">Agents</p>
          <h2 className="mt-3 text-[36px] leading-[1.04] font-light tracking-[-0.035em] text-balance sm:text-[56px]">Bring your agent. It already knows how to <span className="font-heading font-normal tracking-[-0.02em] italic">edit</span>.</h2>
          <p className="mt-5 text-[17px] leading-relaxed text-pretty text-muted-foreground">
            EditMax runs an MCP server on your Mac with 63 tools: everything you can do by hand, plus the window itself. Connect
            the agent you already use, or chat inside the app.
          </p>
        </Reveal>
        <Reveal><OnScreen><AgentsDiagram /></OnScreen></Reveal>
        <Reveal><ConnectTabs /></Reveal>
      </div>
    </section>
  );
}
