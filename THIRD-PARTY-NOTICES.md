# Third-party notices

EditMax's own code is under the [PolyForm Noncommercial License 1.0.0](LICENSE). The components below ship inside
EditMax.app or are compiled into it, and each stays under its own license. Their license texts are in
`EditMax.app/Contents/Resources/Licenses` and in each project's repository.

| Component | Where it lives in the app | License |
| --- | --- | --- |
| [codemax](https://github.com/SkidGod4444/codemax-cli) agent runtime | `Resources/bin/codemax` | AGPL-3.0-only. The complete source is at the link, and the license text ships as `codemax-LICENSE`. |
| [Claude Agent SDK](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk) | compiled into `Resources/bin/editmax-agent` | © Anthropic PBC, all rights reserved, used under [Anthropic's terms](https://code.claude.com/docs/en/legal-and-compliance). Not covered by EditMax's license. |
| [AI SDK](https://github.com/vercel/ai) (`ai`, `@ai-sdk/*`) | compiled into `Resources/bin/editmax-agent` | Apache-2.0 |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | the EditMax executable | MIT, moving to Apache-2.0 |
| [SwiftNIO](https://github.com/apple/swift-nio), [swift-log](https://github.com/apple/swift-log), [swift-system](https://github.com/apple/swift-system), [swift-atomics](https://github.com/apple/swift-atomics), [swift-collections](https://github.com/apple/swift-collections) | the EditMax executable | Apache-2.0 |
| [EventSource](https://github.com/mattt/EventSource) | the EditMax executable | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.1 (app updates) | `Frameworks/Sparkle.framework` | MIT, with the external licenses its `LICENSE` lists. The text ships as `Sparkle-LICENSE`. |
| [PostHog iOS/macOS SDK](https://github.com/PostHog/posthog-ios) 3.93.6 (crash reports and usage) | the EditMax executable | MIT. The text ships as `PostHog-LICENSE`. |
| [PLCrashReporter](https://github.com/microsoft/plcrashreporter), vendored in the PostHog SDK | the EditMax executable | MIT-style, with the parts its `LICENSE` notes under their own terms. The text ships as `PLCrashReporter-LICENSE`. |
| [libwebp](https://chromium.googlesource.com/webm/libwebp), vendored in the PostHog SDK (for session replay, which EditMax leaves off) | the EditMax executable | BSD-3-Clause, with an additional patent grant. The texts ship as `libwebp-COPYING` and `libwebp-PATENTS`. |
| [Bun](https://bun.sh) runtime | `Resources/bin/codemax`, `Resources/bin/editmax-agent` | MIT, with bundled components under their own licenses |
