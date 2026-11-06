# EditMax website

The product site, built with Next.js, Tailwind and shadcn/ui, exported as static files.

```sh
bun install
bun run dev --port 3100   # http://localhost:3100
bun run build             # static site in out/
bun run lint
```

The screenshot and icon in `public/` are copies of the ones in `../docs`. Add components with
`bunx shadcn@latest add <name>`.
