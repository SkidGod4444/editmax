import { API_PROVIDERS, ApiEngine, apiProviderStatus, type ApiSettings } from "./engine.ts";
import { errorFields, log, type EngineEvent, type McpServer, type PermissionRequest, type StopReason } from "./types.ts";

/**
 * EditMax's API-key chat, as a process: NDJSON requests on stdin, events and answers on stdout.
 * The same lines `codemax serve` uses, so EditMax drives both with one runner:
 *
 *   {"id":1,"method":"configure","params":{"cwd","instructions","mcp":[…],"api":{"provider","model","keys"}}}
 *   {"id":2,"method":"prompt","params":{"text":"…"}}      → text_delta / tool_call / tool_update / usage / turn_end lines, then the answer
 *   {"method":"cancel"} · {"id":3,"method":"switch","params":{"api":{…}}} · {"id":4,"method":"providers","params":{"keys"}} · {"method":"close"}
 *
 * `mcp` is EditMax's own server first, then the servers of the plugins the person turned on (HTTP, SSE or a
 * command on this Mac).
 *
 * Permission policy: tools of the MCP servers the host named are allowed, everything else is refused
 * (the Claude Agent SDK is started without built-in tools, so nothing else is ever asked for).
 */
export const VERSION = "0.2.0";

type Line = Record<string, unknown>;

export interface ServerOptions {
  write: (line: Line) => void;
  engineFactory?: (settings: ApiSettings) => ApiEngine;
}

interface Setup {
  cwd: string;
  instructions?: string;
  mcp: McpServer[];
  api: ApiSettings;
}

function apiSettingsOf(p: any): ApiSettings {
  const provider = String(p?.provider ?? "");
  if (!API_PROVIDERS.some((x) => x.id === provider)) throw new Error(`unknown API provider "${provider}". Known: ${API_PROVIDERS.map((x) => x.id).join(", ")}`);
  const keys: ApiSettings["keys"] = {};
  for (const slot of ["anthropic", "openai", "google", "xai"] as const) if (typeof p?.keys?.[slot] === "string" && p.keys[slot]) keys[slot] = p.keys[slot];
  return { provider: provider as ApiSettings["provider"], model: p?.model ? String(p.model) : undefined, keys, maxSteps: typeof p?.maxSteps === "number" ? p.maxSteps : undefined };
}

function mcpServersOf(list: any): McpServer[] {
  if (!Array.isArray(list)) return [];
  const out: McpServer[] = [];
  for (const s of list as any[]) {
    const t = s?.transport;
    if (!s?.name || !t) continue;
    if (t.type === "http" || t.type === "sse") out.push({ name: String(s.name), transport: { type: t.type, url: String(t.url), headers: t.headers ?? {} } });
    else if (t.type === "stdio") out.push({ name: String(s.name), transport: { type: "stdio", command: String(t.command), args: t.args ?? [], env: t.env, cwd: t.cwd ? String(t.cwd) : undefined } });
  }
  return out;
}

export class Server {
  private setup: Setup | null = null;
  private engine: ApiEngine | null = null;
  private off: (() => void) | null = null;
  private closed = false;
  private resolveClosed!: () => void;
  readonly done = new Promise<void>((r) => (this.resolveClosed = r));

  constructor(private opts: ServerOptions) {}

  private write(line: Line) {
    this.opts.write(line);
  }

  /** Reads request lines until `close` or the end of input. */
  async run(lines: AsyncIterable<string>): Promise<void> {
    this.write({ event: "ready", version: VERSION });
    for await (const raw of lines) {
      const text = raw.trim();
      if (!text) continue;
      let msg: any;
      try {
        msg = JSON.parse(text);
      } catch {
        this.write({ event: "error", kind: "protocol", message: "not JSON" });
        continue;
      }
      if (msg.method === "close") break;
      // Requests run one after another, as the host sends them; only `cancel` jumps the queue.
      if (msg.method === "cancel") void this.handle(msg);
      else this.chain = this.chain.then(() => this.handle(msg));
    }
    await this.close();
  }
  private chain: Promise<void> = Promise.resolve();

  private async handle(msg: any) {
    const id = msg.id;
    const reply = (result: unknown) => id !== undefined && this.write({ id, result });
    const fail = (e: unknown) => {
      log("request-failed", { method: msg.method, ...errorFields(e) });
      if (id !== undefined) this.write({ id, error: String((e as Error)?.message ?? e) });
    };
    try {
      switch (msg.method) {
        case "configure":
          reply(await this.configure(msg.params ?? {}));
          break;
        case "prompt": {
          if (!this.engine) throw new Error("configure first");
          const text = String(msg.params?.text ?? "");
          let stop: StopReason;
          let error: string | undefined;
          const offErr = this.engine.onEvent((e) => {
            if (e.type === "error") error = e.message;
          });
          try {
            stop = await this.engine.prompt(text);
          } finally {
            offErr();
          }
          reply({ stopReason: stop, error: stop === "error" ? (error ?? "the turn failed") : undefined, agent: "api" });
          break;
        }
        case "cancel":
          await this.engine?.cancel();
          reply({ ok: true });
          break;
        case "switch": {
          if (!this.setup) throw new Error("configure first");
          if (msg.params?.api) this.setup.api = apiSettingsOf(msg.params.api);
          reply(await this.startEngine());
          break;
        }
        case "providers":
          reply(apiProviderStatus(this.setup?.api?.keys ?? (msg.params?.keys ? apiSettingsOf({ provider: "anthropic", keys: msg.params.keys }).keys : undefined)));
          break;
        default:
          fail(new Error(`unknown method "${msg.method}"`));
      }
    } catch (e) {
      fail(e);
    }
  }

  private async configure(p: any) {
    if (!p.api) throw new Error("params.api is required: { provider, model?, keys? }");
    this.setup = { cwd: p.cwd ? String(p.cwd) : process.cwd(), instructions: p.instructions ? String(p.instructions) : undefined, mcp: mcpServersOf(p.mcp), api: apiSettingsOf(p.api) };
    return this.startEngine();
  }

  private async startEngine() {
    const s = this.setup!;
    await this.stopEngine();
    const engine = this.opts.engineFactory ? this.opts.engineFactory(s.api) : new ApiEngine(s.api);
    this.engine = engine;
    this.off = engine.onEvent((e) => this.onEvent(engine, e));
    const t0 = Date.now();
    const info = await engine.start({ cwd: s.cwd, instructions: s.instructions, mcpServers: s.mcp });
    log("engine-start", { provider: s.api.provider, model: info.currentModel, ms: Date.now() - t0, mcp: s.mcp.map((m) => m.name) });
    return { agent: "api", name: info.name, version: info.version, model: info.currentModel, models: info.models, provider: s.api.provider, session: engine.session ?? undefined };
  }

  private async stopEngine() {
    const e = this.engine;
    this.engine = null;
    this.off?.();
    this.off = null;
    if (e) await e.close().catch(() => {});
  }

  /** Allowed: a tool of one of the host's MCP servers (`mcp__<server>__*`, `<server>/*`). */
  private allowed(r: PermissionRequest): boolean {
    const names = this.setup?.mcp.map((m) => m.name) ?? [];
    return names.some((n) => r.title.startsWith(`mcp__${n}__`) || r.title.startsWith(`${n}/`));
  }

  private onEvent(engine: ApiEngine, e: EngineEvent) {
    if (e.type === "permission_request") {
      const ok = this.allowed(e.request);
      const opt = e.request.options.find((o) => (ok ? o.kind.startsWith("allow") : o.kind.startsWith("reject")));
      this.write({ event: "permission_auto", id: e.request.id, title: e.request.title, kind: e.request.kind, decision: ok ? "allow" : "reject" });
      engine.answerPermission(e.request.id, opt?.id ?? "deny");
      return;
    }
    const { type, ...rest } = e as any;
    this.write({ event: type, ...rest });
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    // A turn still running is cancelled, then its answer goes out before the engine stops.
    await this.engine?.cancel().catch(() => {});
    await this.chain.catch(() => {});
    await this.stopEngine();
    this.resolveClosed();
  }
}

async function* stdinLines(): AsyncIterable<string> {
  const decoder = new TextDecoder();
  let buf = "";
  for await (const chunk of Bun.stdin.stream()) {
    buf += decoder.decode(chunk, { stream: true });
    let i: number;
    while ((i = buf.indexOf("\n")) >= 0) {
      yield buf.slice(0, i);
      buf = buf.slice(i + 1);
    }
  }
  if (buf.trim()) yield buf;
}

if (import.meta.main) {
  if (process.argv.includes("--version")) {
    console.log(VERSION);
    process.exit(0);
  }
  const server = new Server({ write: (l) => process.stdout.write(JSON.stringify(l) + "\n") });
  process.on("SIGTERM", () => void server.close().then(() => process.exit(0)));
  await server.run(stdinLines());
  process.exit(0);
}
