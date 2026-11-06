import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The site is plain files in out/ after `bun run build`, so any static host can serve it.
  output: "export",
  images: { unoptimized: true },
  // cacheComponents and partialPrefetching (the scaffold's defaults) need a server: export mode refuses them.
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
