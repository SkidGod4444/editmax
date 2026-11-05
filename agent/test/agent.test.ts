import { describe, expect, test } from "bun:test";
import { MockLanguageModelV4 } from "ai/test";
import { tool } from "ai";
import { z } from "zod";
import { API_PROVIDERS, ApiEngine, apiKeyFor, apiProviderStatus, classifyApiError, describeAiError } from "../src/engine.ts";
import type { EngineEvent } from "../src/types.ts";
import { Server } from "../src/main.ts";

const usage = (i: number, o: number) => ({ inputTokens: { total: i, noCache: i, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: o, text: o, reasoning: 0 }, raw: {} });
const stream = (chunks: unknown[]) => new ReadableStream({ start: (c) => { for (const ch of chunks) c.enqueue(ch); c.close(); } });

/** A model that calls `inspect_timeline` once, then answers. */
function twoStepModel() {
  let call = 0;
  return new MockLanguageModelV4({
    doStream: async () => {
      call++;
      return {
        stream: stream(call === 1
          ? [{ type: "stream-start", warnings: [] }, { type: "text-start", id: "a" }, { type: "text-delta", id: "a", delta: "Looking. " }, { type: "text-end", id: "a" },
             { type: "tool-call", toolCallId: "c1", toolName: "inspect_timeline", input: JSON.stringify({ project: "p1" }) },
             { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_use" }, usage: usage(10, 5) }]
          : [{ type: "stream-start", warnings: [] }, { type: "text-start", id: "b" }, { type: "text-delta", id: "b", delta: "Two clips." }, { type: "text-end", id: "b" },
             { type: "finish", finishReason: { unified: "stop", raw: "end_turn" }, usage: usage(20, 6) }]),
      };
    },
  });
}

const tools = {
  inspect_timeline: tool({
    description: "timeline",
    inputSchema: z.object({ project: z.string() }),
    execute: async ({ project }) => ({ content: [{ type: "text", text: `{"project":"${project}","clips":2}` }] }),
  }),
};

describe("api engine (Vercel AI SDK path)", () => {
  test("runs the MCP tool loop: text, tool_call, tool_update, usage, turn_end; keeps history", async () => {
    const e = new ApiEngine({ provider: "openai", model: "test-model", testing: { model: twoStepModel(), tools } });
    const events: EngineEvent[] = [];
    e.onEvent((ev) => events.push(ev));
    const info = await e.start({ cwd: "/tmp", mcpServers: [{ name: "editmax", transport: { type: "http", url: "http://127.0.0.1:1/mcp", headers: {} } }] });
    expect(info.name).toBe("OpenAI");
    expect(info.currentModel).toBe("test-model");
    const stop = await e.prompt("how many clips?");
    expect(stop).toBe("end_turn");
    const types = events.map((x) => x.type);
    expect(types).toEqual(["session", "text_delta", "tool_call", "tool_update", "usage", "text_delta", "usage", "turn_end"]);
    const call = events.find((x) => x.type === "tool_call") as any;
    expect(call.title).toBe("editmax/inspect_timeline");
    expect(call.input).toEqual({ project: "p1" });
    const upd = events.find((x) => x.type === "tool_update") as any;
    expect(upd.status).toBe("completed");
    expect(upd.output).toContain('"clips":2');
    expect(events.filter((x) => x.type === "text_delta").map((x: any) => x.text).join("")).toBe("Looking. Two clips.");
    // The next turn sees the whole first one (user, assistant+tool call, tool result, assistant).
    const history = (e as any).history as { role: string }[];
    expect(history[0]!.role).toBe("user");
    expect(history.at(-1)!.role).toBe("assistant");
    expect(JSON.stringify(history)).toContain("inspect_timeline");
    await e.close();
  });

  test("a 401 from the provider is an auth error and the turn ends with error", async () => {
    const { APICallError } = await import("@ai-sdk/provider");
    const model = new MockLanguageModelV4({
      doStream: async () => { throw new APICallError({ message: "invalid x-api-key", url: "u", requestBodyValues: {}, statusCode: 401, responseBody: '{"error":{"message":"invalid x-api-key"}}' }); },
    });
    const e = new ApiEngine({ provider: "anthropic", testing: { model, tools: {} } });
    const events: EngineEvent[] = [];
    e.onEvent((ev) => events.push(ev));
    await e.start({ cwd: "/tmp" });
    expect(await e.prompt("hi")).toBe("error");
    const err = events.find((x) => x.type === "error") as any;
    expect(err.kind).toBe("auth");
    expect(err.message).toContain("HTTP 401");
    expect((e as any).history).toEqual([]); // the failed turn leaves nothing behind
    await e.close();
  });

  test("no key: start fails with the variable to set", async () => {
    const e = new ApiEngine({ provider: "xai", model: "grok-x" });
    const env = process.env.XAI_API_KEY;
    delete process.env.XAI_API_KEY;
    try {
      await expect(e.start({ cwd: "/tmp" })).rejects.toThrow("XAI_API_KEY");
    } finally {
      if (env !== undefined) process.env.XAI_API_KEY = env;
    }
  });
});

describe("api providers", () => {
  test("keys: the host's slot wins over the environment; claude-agent needs claude on PATH", () => {
    const env = { ANTHROPIC_API_KEY: "env-key" } as NodeJS.ProcessEnv;
    const p = apiProviderStatus({ anthropic: "host-key" }, env, () => null);
    expect(p.find((x) => x.id === "claude-agent")).toMatchObject({ hasKey: true, hasClaude: false, available: false, keyOptional: true });
    expect(apiProviderStatus({}, {} as any, () => "/usr/bin/claude").find((x) => x.id === "claude-agent")).toMatchObject({ hasKey: false, available: true });
    expect(p.find((x) => x.id === "anthropic")).toMatchObject({ hasKey: true, available: true });
    expect(p.find((x) => x.id === "openai")).toMatchObject({ hasKey: false, available: false });
    expect(apiKeyFor(API_PROVIDERS[1]!, { anthropic: "host-key" }, env)).toBe("host-key");
    expect(apiKeyFor(API_PROVIDERS[1]!, {}, env)).toBe("env-key");
    expect(classifyApiError("You have hit your rate limit")).toBe("quota");
    expect(classifyApiError("invalid x-api-key")).toBe("auth");
  });

  test("describeAiError: status decides the kind", () => {
    expect(describeAiError({ message: "x", statusCode: 429 }).kind).toBe("quota");
    expect(describeAiError({ message: "x", statusCode: 403 }).kind).toBe("auth");
    expect(describeAiError({ message: "boom", statusCode: 500 })).toEqual({ kind: "other", message: "boom (HTTP 500)" });
    expect(describeAiError(new Error("fetch failed")).kind).toBe("other");
  });
});

describe("the sidecar protocol", () => {
  test("configure runs the engine with the host's keys; MCP tools are allowed, anything else refused; providers lists the slots", async () => {
    const lines: any[] = [];
    const s = new Server({
      write: (l) => lines.push(l),
      engineFactory: (settings) => {
        expect(settings.keys!.openai).toBe("sk-test");
        return new ApiEngine({ ...settings, testing: { model: twoStepModel(), tools } });
      },
    });
    const run = s.run((async function* () {
      yield JSON.stringify({ id: 1, method: "configure", params: { cwd: "/tmp", api: { provider: "openai", model: "gpt-test", keys: { openai: "sk-test" } }, mcp: [{ name: "editmax", transport: { type: "http", url: "http://127.0.0.1:1/mcp", headers: { Authorization: "Bearer t" } } }] } }) + "\n";
      yield JSON.stringify({ id: 2, method: "prompt", params: { text: "clips?" } }) + "\n";
      yield JSON.stringify({ id: 4, method: "providers" }) + "\n";
      while (!lines.some((l) => l.id === 4)) await Bun.sleep(10);
      yield JSON.stringify({ method: "close" }) + "\n";
    })());
    await run;
    expect(lines[0]).toMatchObject({ event: "ready" });
    expect(lines.find((l) => l.id === 1).result).toMatchObject({ agent: "api", name: "OpenAI", model: "gpt-test", provider: "openai" });
    expect(lines.find((l) => l.id === 2).result.stopReason).toBe("end_turn");
    expect(lines.filter((l) => l.event === "tool_call").map((l) => l.title)).toEqual(["editmax/inspect_timeline"]);
    expect(lines.filter((l) => l.event === "text_delta").map((l) => l.text).join("")).toBe("Looking. Two clips.");
    const ps = lines.find((l) => l.id === 4).result;
    expect(ps.map((p: any) => p.id)).toEqual(["claude-agent", "anthropic", "openai", "google", "xai"]);
    expect(ps.find((p: any) => p.id === "openai").hasKey).toBe(true);
  });

  test("permission policy: the host's server's tools are allowed, others refused", async () => {
    const lines: any[] = [];
    const s = new Server({ write: (l) => lines.push(l) });
    (s as any).setup = { cwd: "/tmp", mcp: [{ name: "editmax", transport: { type: "http", url: "u" } }], api: { provider: "anthropic" } };
    const answers: [string, string][] = [];
    const fake = { answerPermission: (id: string, opt: string) => answers.push([id, opt]) } as any;
    const req = (title: string) => ({ type: "permission_request" as const, request: { id: "p-" + title, title, options: [{ id: "allow", label: "Allow", kind: "allow_once" }, { id: "deny", label: "Deny", kind: "reject_once" }] } });
    (s as any).onEvent(fake, req("mcp__editmax__set_playhead"));
    (s as any).onEvent(fake, req("editmax/inspect_timeline"));
    (s as any).onEvent(fake, req("Bash"));
    expect(answers).toEqual([["p-mcp__editmax__set_playhead", "allow"], ["p-editmax/inspect_timeline", "allow"], ["p-Bash", "deny"]]);
    expect(lines.map((l) => l.decision)).toEqual(["allow", "allow", "reject"]);
  });

  test("configure without params.api is refused", async () => {
    const lines: any[] = [];
    const s = new Server({ write: (l) => lines.push(l) });
    await s.run((async function* () {
      yield JSON.stringify({ id: 1, method: "configure", params: { cwd: "/tmp" } }) + "\n";
      yield JSON.stringify({ method: "close" }) + "\n";
    })());
    expect(lines.find((l) => l.id === 1).error).toContain("params.api");
  });
});
