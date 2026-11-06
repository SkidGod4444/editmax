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
| [Bun](https://bun.sh) runtime | `Resources/bin/codemax`, `Resources/bin/editmax-agent` | MIT, with bundled components under their own licenses |
