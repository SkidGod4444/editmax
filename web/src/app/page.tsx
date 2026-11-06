import { Agents } from "@/components/site/agents";
import { Closing } from "@/components/site/closing";
import { Features } from "@/components/site/features";
import { Hero } from "@/components/site/hero";
import { Looks } from "@/components/site/lazy";
import { MotionRoot } from "@/components/site/motion";
import { Nav } from "@/components/site/nav";

export default function Home() {
  return (
    <MotionRoot>
      <div id="top" className="flex flex-1 flex-col bg-background text-foreground">
        <Nav />
        <main className="flex-1">
          <Hero />
          <Looks />
          <Features />
          <Agents />
        </main>
        <Closing />
      </div>
    </MotionRoot>
  );
}
