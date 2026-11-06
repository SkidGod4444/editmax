/**
 * The site's public origin, for canonical, Open Graph, sitemap and structured-data URLs. On Vercel it is the project's
 * production domain (its shortest custom domain, else its vercel.app one), read at build time, so adding a custom
 * domain updates every URL on the next deploy. Elsewhere it falls back to the current production URL.
 */
export const site = process.env.VERCEL_PROJECT_PRODUCTION_URL
  ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
  : "https://editmax-web.vercel.app";

export const title = "EditMax: the video editor your coding agent can drive";
export const description =
  "A native macOS video editor. Cut, grade, caption and deliver by hand, by chat, or from Claude Code, Codex and Cursor over MCP.";
