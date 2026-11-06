import type { MetadataRoute } from "next";
import { site } from "./site";

export const dynamic = "force-static";

/** One page: the site is a single long page with in-page sections. */
export default function sitemap(): MetadataRoute.Sitemap {
  return [{ url: `${site}/`, lastModified: new Date(), changeFrequency: "weekly", priority: 1 }];
}
