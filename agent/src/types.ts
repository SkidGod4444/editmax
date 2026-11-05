/** The events the sidecar writes, one JSON line each (the same names EditMax already reads from `codemax serve`). */
export type ToolStatus = "pending" | "in_progress" | "completed" | "failed";
export type StopReason = "end_turn" | "max_tokens" | "cancelled" | "refusal" | "error" | "other";
export type ErrorKind = "quota" | "auth" | "protocol" | "crashed" | "other";

export interface PermissionOption {
  id: string;
  label: string;
  kind: string;
}

export interface PermissionRequest {
  id: string;
  toolCallId?: string;
  kind?: string;
  title: string;
  detail?: string;
  options: PermissionOption[];
}

export type EngineEvent =
  | { type: "text_delta"; text: string; messageId?: string }
  | { type: "thought_delta"; text: string; messageId?: string }
  | { type: "tool_call"; id: string; title: string; kind?: string; status: ToolStatus; detail?: string; input?: unknown; output?: string }
  | { type: "tool_update"; id: string; status?: ToolStatus; title?: string; detail?: string; input?: unknown; output?: string }
  | { type: "permission_request"; request: PermissionRequest }
  | { type: "usage"; inputTokens?: number; outputTokens?: number; cacheReadTokens?: number; cacheWriteTokens?: number; model?: string; costUsd?: number; agentTotalUsd?: number }
  | { type: "session"; id: string }
  | { type: "turn_end"; stopReason: StopReason }
  | { type: "error"; kind: ErrorKind; message: string }
  | { type: "notice"; level: "info" | "warn" | "error"; title: string; detail?: string };

export interface McpServer {
  name: string;
  transport: { type: "http" | "sse"; url: string; headers?: Record<string, string> } | { type: "stdio"; command: string; args?: string[]; env?: Record<string, string> };
}

export interface EngineInfo {
  name: string;
  version?: string;
  models?: { id: string; name: string }[];
  currentModel?: string;
}

export interface EngineStartOptions {
  cwd: string;
  instructions?: string;
  mcpServers?: McpServer[];
  resume?: string;
}

/** Diagnostics, never prompts, replies or keys: one JSON line on stderr, which EditMax keeps in its logs. */
export function log(kind: string, fields: Record<string, unknown> = {}) {
  try {
    process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), kind, ...fields }) + "\n");
  } catch {
    /* stderr gone */
  }
}

export function errorFields(e: unknown): Record<string, unknown> {
  const err: any = e;
  return { error: String(err?.message ?? err).slice(0, 500), name: err?.name, status: err?.statusCode ?? err?.status, code: err?.code };
}
