import { query, type Options as AgentOptions, type Query, type SDKMessage, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { streamText, stepCountIs, type LanguageModel, type ModelMessage, type ToolSet } from "ai";
import { createMCPClient, type MCPClient } from "@ai-sdk/mcp";
import { Experimental_StdioMCPTransport } from "@ai-sdk/mcp/mcp-stdio";
import { createAnthropic } from "@ai-sdk/anthropic";
import { createOpenAI } from "@ai-sdk/openai";
import { createGoogle } from "@ai-sdk/google";
import { createXai } from "@ai-sdk/xai";
import { randomUUID } from "node:crypto";
import { errorFields, log, type EngineEvent, type EngineInfo, type EngineStartOptions, type ErrorKind, type McpServer, type PermissionRequest, type StopReason } from "./types.ts";

/**
 * EditMax's API-key backend: the user's own keys instead of a subscription login, in two shapes.
 *
 * - `claude-agent`: the Claude Agent SDK driving the user's installed Claude Code (`claude` on PATH;
 *   the SDK's own 300 MB binary is never bundled) with ANTHROPIC_API_KEY, full permission callbacks,
 *   MCP servers over HTTP and streaming. The same engine Claude Code runs on, billed to the key.
 * - `anthropic` / `openai` / `google` / `xai`: the Vercel AI SDK (`ai`) with that provider, tools from the
 *   MCP servers through `@ai-sdk/mcp`, a multi-step tool loop and streaming. Switching providers is a
 *   different model object, nothing else.
 *
 * Keys come from EditMax (its keychain) or from the environment. Prompts and replies are never logged.
 */
export type ApiProviderId = "claude-agent" | "anthropic" | "openai" | "google" | "xai";

export interface ApiProvider {
  id: ApiProviderId;
  name: string;
  /** Environment variable holding the key when the host passes none. */
  keyEnv: string;
  /** Key slot in `ApiSettings.keys` (claude-agent and anthropic share one key). */
  keyFor: "anthropic" | "openai" | "google" | "xai";
  defaultModel?: string;
  /** Known model ids worth offering; other providers take any id the user types. */
  models?: { id: string; name: string }[];
  /** Also needs Claude Code installed. */
  needsClaude?: boolean;
  /** Runs without a key. No provider does: the Claude Agent SDK must not fall back to a Claude subscription login,
   *  which Anthropic's terms do not allow for apps built on it (the Agent backend runs the user's own Claude Code for that). */
  keyOptional?: boolean;
}

const CLAUDE_MODELS = [
  { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
  { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
  { id: "claude-haiku-5-5", name: "Claude Haiku 5.5" },
  { id: "claude-fable-5-1", name: "Claude Fable 5.1" },
];

export const API_PROVIDERS: readonly ApiProvider[] = [
  // Every provider needs a key, the Claude Agent SDK included (see keyOptional above).
  { id: "claude-agent", name: "Claude Agent SDK", keyEnv: "ANTHROPIC_API_KEY", keyFor: "anthropic", defaultModel: "claude-opus-5-5", models: CLAUDE_MODELS, needsClaude: true },
  { id: "anthropic", name: "Claude API", keyEnv: "ANTHROPIC_API_KEY", keyFor: "anthropic", defaultModel: "claude-opus-5-5", models: CLAUDE_MODELS },
  { id: "openai", name: "OpenAI", keyEnv: "OPENAI_API_KEY", keyFor: "openai" },
  { id: "google", name: "Google Gemini", keyEnv: "GOOGLE_GENERATIVE_AI_API_KEY", keyFor: "google" },
  { id: "xai", name: "xAI Grok", keyEnv: "XAI_API_KEY", keyFor: "xai" },
];

export function apiProvider(id: string): ApiProvider {
  const p = API_PROVIDERS.find((x) => x.id === id);
  if (!p) throw new Error(`unknown API provider "${id}". Known: ${API_PROVIDERS.map((x) => x.id).join(", ")}`);
  return p;
}

export interface ApiSettings {
  provider: ApiProviderId;
  model?: string;
  /** Keys by slot (`keyFor`); a missing slot falls back to the provider's environment variable. */
  keys?: Partial<Record<ApiProvider["keyFor"], string>>;
  /** Tool-call rounds one turn may take on the AI SDK path (default 40). */
  maxSteps?: number;
  /** Tests: a model (and tools) in place of the real provider and MCP servers. */
  testing?: { model: LanguageModel; tools?: ToolSet };
}

/** The environment minus Claude subscription credentials, so the Agent SDK can only authenticate with the API key. */
export function withoutLoginTokens(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const { CLAUDE_CODE_OAUTH_TOKEN: _token, ...rest } = env;
  return rest;
}

/** The key for a provider: the host's, else the environment's. */
export function apiKeyFor(p: ApiProvider, keys?: ApiSettings["keys"], env: NodeJS.ProcessEnv = process.env): string | undefined {
  return keys?.[p.keyFor] || env[p.keyEnv] || undefined;
}

/** What a provider needs and whether this machine has it (the `providers` request). */
export function apiProviderStatus(keys?: ApiSettings["keys"], env: NodeJS.ProcessEnv = process.env, which: (b: string) => string | null = (b) => Bun.which(b)) {
  return API_PROVIDERS.map((p) => {
    const key = !!apiKeyFor(p, keys, env);
    const claude = p.needsClaude ? !!which("claude") : true;
    return { id: p.id, name: p.name, keyEnv: p.keyEnv, keyOptional: !!p.keyOptional, defaultModel: p.defaultModel, models: p.models, needsClaude: !!p.needsClaude, hasKey: key, hasClaude: claude, available: (key || !!p.keyOptional) && claude };
  });
}

export class ApiEngine {
  info: EngineInfo | null = null;
  session: string | null = null;
  private listeners = new Set<(e: EngineEvent) => void>();
  private provider: ApiProvider;
  private model: string | undefined;
  private cwd = process.cwd();
  private instructions: string | undefined;
  // Claude Agent SDK
  private q: Query | null = null;
  /** The input generator runs while this is set; `close` clears it (the generator may run before `q` is assigned). */
  private open = false;
  private inbox: SDKUserMessage[] = [];
  private wake: (() => void) | null = null;
  private turn: { resolve: (r: StopReason) => void } | null = null;
  private cancelling = false;
  private lastCost = 0;
  private messageId: string | undefined;
  private perms = new Map<string, (allow: boolean) => void>();
  private permSeq = 0;
  // Vercel AI SDK
  private clients: MCPClient[] = [];
  private tools: ToolSet = {};
  private toolServer = new Map<string, string>();
  private history: ModelMessage[] = [];
  private abort: AbortController | null = null;
  private languageModel: LanguageModel | null = null;

  constructor(private settings: ApiSettings) {
    this.provider = apiProvider(settings.provider);
    this.model = settings.model || this.provider.defaultModel;
  }

  onEvent(listener: (e: EngineEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  private emit(e: EngineEvent) {
    for (const l of this.listeners) l(e);
  }

  async start(opts: EngineStartOptions): Promise<EngineInfo> {
    this.cwd = opts.cwd;
    this.instructions = opts.instructions;
    const p = this.provider;
    const key = this.settings.testing ? "test" : apiKeyFor(p, this.settings.keys);
    // Every provider runs on a key, the Claude Agent SDK included (never on the user's Claude subscription login).
    if (!key) throw new Error(`no API key for ${p.name}: set ${p.keyEnv} or pass one`);
    if (!this.model) throw new Error(`${p.name} needs a model id (none is chosen by default)`);
    const servers = opts.mcpServers ?? [];
    const info = p.id === "claude-agent" ? await this.startClaudeAgent(key, servers, opts) : await this.startAiSdk(key!, servers);
    this.info = info;
    return info;
  }

  // ---------- Claude Agent SDK ----------

  private async startClaudeAgent(key: string, servers: McpServer[], opts: EngineStartOptions): Promise<EngineInfo> {
    const claude = Bun.which("claude");
    if (!claude) throw new Error("Claude Code is not installed; the Claude Agent SDK runs through it (curl -fsSL https://claude.ai/install.sh | bash)");
    const mcpServers: NonNullable<AgentOptions["mcpServers"]> = {};
    for (const s of servers) {
      const t = s.transport;
      if (t.type === "http") mcpServers[s.name] = { type: "http", url: t.url, headers: t.headers };
      else if (t.type === "sse") mcpServers[s.name] = { type: "sse", url: t.url, headers: t.headers };
      // The SDK's stdio entry has no working folder; a plugin's command gets its folder through its own arguments.
      else if (t.type === "stdio") mcpServers[s.name] = { type: "stdio", command: t.command, args: t.args, env: t.env };
    }
    const options: AgentOptions = {
      pathToClaudeCodeExecutable: claude,
      cwd: this.cwd,
      model: this.model,
      permissionMode: "default",
      // No built-in tools (Read, Write, Bash…): the agent works through the MCP servers it was given,
      // and only those (strict: nothing from the user's own Claude Code setup, no settings files either).
      tools: [],
      settingSources: [],
      strictMcpConfig: true,
      mcpServers,
      includePartialMessages: true,
      systemPrompt: this.instructions,
      resume: opts.resume,
      // Always the key, and never a subscription token that happens to be in the environment.
      env: { ...withoutLoginTokens(process.env), ANTHROPIC_API_KEY: key, CLAUDE_AGENT_SDK_CLIENT_APP: "editmax" },
      canUseTool: (name, input, o) => this.askPermission(name, input, o.toolUseID),
    };
    this.open = true;
    this.q = query({ prompt: this.input(), options });
    // The SDK sends its `init` (version, model, MCP status) with the first turn, not at start: the
    // session is ready now, and `info` is filled in from `init` when it comes.
    void this.pump((init) => {
      this.info = { ...init, name: init.name };
    }).catch((e) => log("claude-agent-pump", errorFields(e)));
    return { name: this.provider.name, models: this.provider.models, currentModel: this.model };
  }

  /** Streaming input: one `query()` for the whole session; each turn pushes one user message. */
  private async *input(): AsyncIterable<SDKUserMessage> {
    while (this.open || this.inbox.length) {
      if (this.inbox.length) {
        yield this.inbox.shift()!;
        continue;
      }
      await new Promise<void>((r) => (this.wake = r));
    }
  }
  private send(m: SDKUserMessage) {
    this.inbox.push(m);
    const w = this.wake;
    this.wake = null;
    w?.();
  }

  /** Reads the SDK's messages for the session's lifetime, mapping them onto engine events. */
  private async pump(onInit: (info: EngineInfo) => void) {
    const q = this.q!;
    try {
      for await (const m of q) this.onMessage(m, onInit);
    } catch (e) {
      log("claude-agent-stream", errorFields(e));
      if (this.turn) {
        this.emit({ type: "error", kind: "crashed", message: (e as Error)?.message ?? String(e) });
        this.endTurn("error");
      }
      throw e;
    } finally {
      if (this.turn) {
        this.emit({ type: "error", kind: "crashed", message: "Claude Code ended the session before answering" });
        this.endTurn("error");
      }
    }
  }

  private onMessage(m: SDKMessage, onInit: (info: EngineInfo) => void) {
    switch (m.type) {
      case "system":
        if (m.subtype === "init") {
          const info: EngineInfo = { name: `${this.provider.name} (Claude Code ${m.claude_code_version})`, version: m.claude_code_version, models: this.provider.models, currentModel: m.model };
          this.model = m.model;
          if (this.session !== m.session_id) {
            this.session = m.session_id;
            this.emit({ type: "session", id: this.session });
          }
          const failed = m.mcp_servers.filter((s) => s.status !== "connected");
          if (failed.length) this.emit({ type: "notice", level: "warn", title: `MCP server${failed.length > 1 ? "s" : ""} not connected: ${failed.map((s) => `${s.name} (${s.status})`).join(", ")}` });
          onInit(info);
        }
        return;
      case "stream_event": {
        const e: any = m.event;
        if (e.type === "message_start") this.messageId = e.message?.id;
        else if (e.type === "content_block_delta") {
          if (e.delta?.type === "text_delta") this.emit({ type: "text_delta", text: e.delta.text, messageId: this.messageId });
          else if (e.delta?.type === "thinking_delta") this.emit({ type: "thought_delta", text: e.delta.thinking, messageId: this.messageId });
        }
        return;
      }
      case "assistant":
        for (const b of m.message.content as any[]) {
          if (b.type === "tool_use") this.emit({ type: "tool_call", id: b.id, title: b.name, kind: "other", status: "in_progress", detail: shortJson(b.input), input: b.input });
        }
        if (m.error) this.emit({ type: "error", kind: classifyApiError(String(m.error)), message: String(m.error) });
        return;
      case "user":
        for (const b of (m.message.content as any[]) ?? []) {
          if (b?.type === "tool_result") {
            const text = Array.isArray(b.content) ? b.content.map((c: any) => (c.type === "text" ? c.text : `[${c.type}]`)).join("\n") : typeof b.content === "string" ? b.content : JSON.stringify(b.content ?? "");
            this.emit({ type: "tool_update", id: b.tool_use_id, status: b.is_error ? "failed" : "completed", output: text });
          }
        }
        return;
      case "result": {
        const u: any = m.usage ?? {};
        const total = typeof m.total_cost_usd === "number" ? m.total_cost_usd : this.lastCost;
        const costUsd = total >= this.lastCost ? total - this.lastCost : total;
        this.lastCost = total;
        this.emit({ type: "usage", inputTokens: u.input_tokens, outputTokens: u.output_tokens, cacheReadTokens: u.cache_read_input_tokens, cacheWriteTokens: u.cache_creation_input_tokens, model: this.model, costUsd, agentTotalUsd: total });
        if (m.subtype === "success" && !m.is_error) this.endTurn("end_turn");
        else if (this.cancelling) this.endTurn("cancelled");
        else {
          const text = m.subtype === "success" ? String((m as any).result ?? "the turn failed") : (m as any).errors?.join?.("\n") || m.subtype.replace(/^error_/, "").replace(/_/g, " ");
          this.emit({ type: "error", kind: classifyApiError(text), message: text });
          this.endTurn(m.subtype === "error_max_turns" ? "other" : "error");
        }
        return;
      }
      default:
        return;
    }
  }

  private endTurn(stop: StopReason) {
    const t = this.turn;
    this.turn = null;
    this.cancelling = false;
    if (!t) return;
    this.emit({ type: "turn_end", stopReason: stop });
    t.resolve(stop);
  }

  private askPermission(name: string, input: Record<string, unknown>, toolUseID: string): Promise<{ behavior: "allow" } | { behavior: "deny"; message: string }> {
    const id = `perm-${++this.permSeq}`;
    const request: PermissionRequest = {
      id,
      toolCallId: toolUseID,
      kind: name.startsWith("mcp__") ? "other" : /^(Bash|Write|Edit|MultiEdit|NotebookEdit)$/.test(name) ? "execute" : "other",
      title: name,
      detail: shortJson(input),
      options: [
        { id: "allow", label: "Allow once", kind: "allow_once" },
        { id: "deny", label: "Deny", kind: "reject_once" },
      ],
    };
    return new Promise((resolve) => {
      this.perms.set(id, (allow) => resolve(allow ? { behavior: "allow" } : { behavior: "deny", message: "Not allowed here: work through the MCP tools you were given." }));
      this.emit({ type: "permission_request", request });
    });
  }

  // ---------- Vercel AI SDK ----------

  private async startAiSdk(key: string, servers: McpServer[]): Promise<EngineInfo> {
    const p = this.provider;
    if (this.settings.testing) {
      this.languageModel = this.settings.testing.model;
      this.tools = this.settings.testing.tools ?? {};
      for (const name of Object.keys(this.tools)) this.toolServer.set(name, servers[0]?.name ?? "test");
    } else {
      const make = { anthropic: createAnthropic, openai: createOpenAI, google: createGoogle, xai: createXai }[p.id as Exclude<ApiProviderId, "claude-agent">];
      this.languageModel = make({ apiKey: key })(this.model!);
      const connected = await connectMcpServers(servers, (s, e) => {
        log("mcp-connect", { server: s.name, ...errorFields(e) });
        this.emit({ type: "notice", level: "warn", title: `MCP server not connected: ${s.name}`, detail: (e as Error)?.message });
      });
      this.clients = connected.clients;
      this.tools = connected.tools;
      this.toolServer = connected.toolServer;
    }
    this.session = randomUUID();
    this.emit({ type: "session", id: this.session });
    return { name: p.name, models: p.models, currentModel: this.model };
  }

  private async promptAiSdk(text: string): Promise<StopReason> {
    this.history.push({ role: "user", content: text });
    this.abort = new AbortController();
    let stop: StopReason = "end_turn";
    let errored = false;
    const messageIds = new Map<string, string>();
    try {
      const r = streamText({
        model: this.languageModel!,
        system: this.instructions,
        messages: this.history,
        tools: this.tools,
        stopWhen: stepCountIs(this.settings.maxSteps ?? 40),
        abortSignal: this.abort.signal,
        // Errors arrive as `error` parts below; the SDK's default handler would also print them to stderr.
        onError: () => {},
      });
      for await (const part of r.fullStream) {
        switch (part.type) {
          case "text-delta":
            this.emit({ type: "text_delta", text: part.text, messageId: messageIds.get(part.id) ?? part.id });
            break;
          case "reasoning-delta":
            this.emit({ type: "thought_delta", text: part.text });
            break;
          case "tool-call":
            this.emit({ type: "tool_call", id: part.toolCallId, title: `${this.toolServer.get(part.toolName) ?? "mcp"}/${part.toolName}`, kind: "other", status: "in_progress", detail: shortJson(part.input), input: part.input });
            break;
          case "tool-result":
            this.emit({ type: "tool_update", id: part.toolCallId, status: "completed", output: mcpResultText(part.output) });
            break;
          case "tool-error":
            this.emit({ type: "tool_update", id: part.toolCallId, status: "failed", output: String((part.error as Error)?.message ?? part.error) });
            break;
          case "finish-step": {
            const u: any = part.usage ?? {};
            this.emit({ type: "usage", inputTokens: u.inputTokens?.noCache ?? u.inputTokens?.total, outputTokens: u.outputTokens?.total, cacheReadTokens: u.inputTokens?.cacheRead, cacheWriteTokens: u.inputTokens?.cacheWrite, model: this.model });
            break;
          }
          case "finish":
            if (part.finishReason === "length") stop = "max_tokens";
            else if (part.finishReason === "content-filter") stop = "refusal";
            break;
          case "error": {
            errored = true;
            const { kind, message } = describeAiError(part.error);
            this.emit({ type: "error", kind, message });
            break;
          }
          default:
            break;
        }
      }
      // Every step's messages (assistant tool calls, tool results, the answer), so the next turn sees them.
      this.history.push(...(await r.responseMessages));
    } catch (e) {
      if (this.abort.signal.aborted) stop = "cancelled";
      else if (!errored) {
        // Not already reported as an `error` part above (the stream rethrows after it).
        errored = true;
        const { kind, message } = describeAiError(e);
        this.emit({ type: "error", kind, message });
      }
    }
    if (this.abort.signal.aborted) stop = "cancelled";
    else if (errored) stop = "error";
    // A turn that broke leaves no half assistant message behind for the next one.
    if (stop === "error" || stop === "cancelled") while (this.history.length && this.history.at(-1)!.role !== "user") this.history.pop();
    if (stop === "cancelled" || stop === "error") if (this.history.at(-1)?.role === "user") this.history.pop();
    this.abort = null;
    this.emit({ type: "turn_end", stopReason: stop });
    return stop;
  }

  // ---------- Engine ----------

  async prompt(text: string): Promise<StopReason> {
    if (this.provider.id !== "claude-agent") return this.promptAiSdk(text);
    if (!this.q) throw new Error("not started");
    if (this.turn) throw new Error("a turn is running");
    return new Promise<StopReason>((resolve) => {
      this.turn = { resolve };
      this.cancelling = false;
      this.send({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null });
    });
  }

  answerPermission(requestId: string, optionId: string): void {
    const p = this.perms.get(requestId);
    this.perms.delete(requestId);
    p?.(optionId === "allow");
  }

  async cancel(): Promise<void> {
    if (this.provider.id === "claude-agent") {
      if (!this.turn) return;
      this.cancelling = true;
      await this.q?.interrupt().catch(() => {});
    } else this.abort?.abort();
  }

  async setModel(modelId: string): Promise<void> {
    this.model = modelId;
    if (this.provider.id === "claude-agent") await this.q?.setModel(modelId);
    else if (!this.settings.testing) {
      const make = { anthropic: createAnthropic, openai: createOpenAI, google: createGoogle, xai: createXai }[this.provider.id as Exclude<ApiProviderId, "claude-agent">];
      this.languageModel = make({ apiKey: apiKeyFor(this.provider, this.settings.keys)! })(modelId);
    }
    if (this.info) this.info.currentModel = modelId;
  }

  async close(): Promise<void> {
    for (const [, deny] of this.perms) deny(false);
    this.perms.clear();
    const q = this.q;
    this.q = null;
    this.open = false;
    this.wake?.();
    this.wake = null;
    try {
      q?.close();
    } catch {
      /* already gone */
    }
    if (this.turn) this.endTurn("cancelled");
    this.abort?.abort();
    for (const c of this.clients) await c.close().catch(() => {});
    this.clients = [];
  }
}

/**
 * The tools of every server, in the host's order (EditMax's own first, then the plugins'): an HTTP or SSE address, or a
 * command started on this Mac. A tool name two servers share goes to the first. A server that does not connect is
 * reported and left out; the others still work.
 */
export async function connectMcpServers(servers: McpServer[], onFailure: (server: McpServer, error: unknown) => void = () => {}) {
  const clients: MCPClient[] = [];
  const tools: ToolSet = {};
  const toolServer = new Map<string, string>();
  for (const s of servers) {
    const t = s.transport;
    let client: MCPClient | undefined;
    try {
      client = await createMCPClient({
        transport:
          t.type === "stdio"
            ? new Experimental_StdioMCPTransport({ command: t.command, args: t.args ?? [], env: { ...(process.env as Record<string, string>), ...(t.env ?? {}) }, cwd: t.cwd, stderr: "ignore" })
            : ({ type: t.type, url: t.url, headers: t.headers } as any),
      });
      const found = await client.tools();
      clients.push(client);
      for (const [name, tool] of Object.entries(found)) {
        if (toolServer.has(name)) continue;
        tools[name] = tool;
        toolServer.set(name, s.name);
      }
    } catch (e) {
      await client?.close().catch(() => {});
      onFailure(s, e);
    }
  }
  return { clients, tools, toolServer };
}

function shortJson(v: unknown): string | undefined {
  if (v === undefined || v === null) return undefined;
  const s = typeof v === "string" ? v : JSON.stringify(v);
  return s && s !== "{}" ? s.slice(0, 300) : undefined;
}

/** An MCP tool result (`{content: [{type: "text", text}], structuredContent}`) as the text the model saw. */
function mcpResultText(output: unknown): string {
  const o: any = output;
  if (o && Array.isArray(o.content)) return o.content.map((c: any) => (c?.type === "text" ? c.text : `[${c?.type ?? "content"}]`)).join("\n");
  return typeof o === "string" ? o : JSON.stringify(o ?? "");
}

/** The kind of a failure from its text: the provider's plan or rate limit, its key, or something else. */
export function classifyApiError(text: string): ErrorKind {
  const t = text.toLowerCase();
  if (/rate.?limit|too many requests|quota|usage limit|insufficient.credit|billing|overloaded|exceeded/.test(t)) return "quota";
  if (/invalid.*(api.?key|x-api-key|token)|unauthori[sz]ed|authentication|forbidden|not logged in|please log ?in|login/.test(t)) return "auth";
  return "other";
}

/** The AI SDK's errors carry the HTTP status: 401/403 is the key, 402/429 the plan or rate. */
export function describeAiError(e: unknown): { kind: ErrorKind; message: string } {
  const err: any = e;
  const status: number | undefined = typeof err?.statusCode === "number" ? err.statusCode : undefined;
  let message = String(err?.message ?? err ?? "unknown error");
  const body = typeof err?.responseBody === "string" ? err.responseBody : "";
  const m = body.match(/"message"\s*:\s*"((?:[^"\\]|\\.)+)"/);
  if (m && !message.includes(m[1]!)) message = `${message}: ${m[1]!.replace(/\\"/g, '"')}`;
  if (status === 401 || status === 403) return { kind: "auth", message: `${message} (HTTP ${status}; check the API key)` };
  if (status === 402 || status === 429) return { kind: "quota", message: `${message} (HTTP ${status})` };
  const kind = classifyApiError(message);
  return { kind, message: status ? `${message} (HTTP ${status})` : message };
}
