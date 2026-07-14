import path from "node:path"
import { defineConfig } from "vitest/config"

/**
 * Standalone from vite.config.ts on purpose: this app's build config (PWA
 * plugin, Tailwind plugin, etc.) has nothing to do with running unit tests,
 * and pulling it in would drag plugin side effects into the test runner for
 * no benefit. We only need the `@` path alias the rest of the app uses.
 *
 * Tests target pure/near-pure business logic (validation schemas, geo math,
 * discount banding, etc.) rather than React components, so no jsdom/DOM
 * environment is configured — plain Node is enough and keeps the suite fast.
 */
export default defineConfig({
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
})
