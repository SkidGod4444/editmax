import posthog from "posthog-js";

const projectToken = process.env.NEXT_PUBLIC_POSTHOG_PROJECT_TOKEN;
const host = process.env.NEXT_PUBLIC_POSTHOG_HOST;

// Both are public build-time values (Vercel project settings, or .env.local). Without them the site runs and sends
// nothing; in development it says so once instead of breaking every page.
if (projectToken && host) {
  try {
    posthog.init(projectToken, {
      api_host: host,
      defaults: "2026-01-30",
      capture_exceptions: true,
      debug: process.env.NODE_ENV === "development",
      logs: {
        serviceName: "editmax-web",
        environment: process.env.NODE_ENV,
      },
    });
  } catch (error) {
    console.warn("PostHog did not start:", error);
  }
} else if (process.env.NODE_ENV === "development") {
  console.warn("PostHog is off: set NEXT_PUBLIC_POSTHOG_PROJECT_TOKEN and NEXT_PUBLIC_POSTHOG_HOST to send events.");
}
