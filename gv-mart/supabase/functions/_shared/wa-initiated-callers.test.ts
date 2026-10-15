import { readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"

// Every sendMessage() call under supabase/functions must be classified. An INITIATED send (the system starts it:
// milestone dispatch, scheduled tasks, failed-send retries) must pass `initiated: true`. A REPLY to an inbound message
// must not. Adding a caller to neither list fails this test, so a new initiated path cannot silently skip the gate.
const ROOT = join(__dirname, "..")
const REPLY_FILES = ["_shared/whatsapp-handle-message.ts"] // bot replies, supplier acks, opt-out and START replies
const INITIATED_FILES = ["_shared/wa-milestone-dispatch-core.ts", "wa-scheduled-tasks/index.ts"]
const IGNORE = [/\.test\.ts$/, /^_shared\/whatsapp\.ts$/]

function walk(dir: string, out: string[] = []): string[] {
  for (const e of readdirSync(dir)) {
    const p = join(dir, e)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (p.endsWith(".ts")) out.push(p)
  }
  return out
}
const rel = (p: string) => p.slice(ROOT.length + 1).replace(/\/g, "/")
const callBlocks = (src: string) => [...src.matchAll(/sendMessage\(\s*admin,\s*\{([\s\S]*?)\n\s*\}\)/g)].map((m) => m[1])

describe("sendMessage callers are classified (design B)", () => {
  const files = walk(ROOT).filter((f) => !IGNORE.some((r) => r.test(rel(f)))).filter((f) => /sendMessage\(\s*admin,/.test(readFileSync(f, "utf8")))

  it("every caller file is listed as reply or initiated", () => {
    for (const f of files) expect([...REPLY_FILES, ...INITIATED_FILES], rel(f)).toContain(rel(f))
  })
  it("every call in an initiated file passes initiated: true", () => {
    for (const name of INITIATED_FILES) {
      const blocks = callBlocks(readFileSync(join(ROOT, name), "utf8"))
      expect(blocks.length, name).toBeGreaterThan(0)
      for (const b of blocks) expect(b, name).toMatch(/initiated:\s*true/)
    }
  })
  it("no call in a reply file passes initiated", () => {
    for (const name of REPLY_FILES) {
      for (const b of callBlocks(readFileSync(join(ROOT, name), "utf8"))) expect(b, name).not.toMatch(/initiated:/)
    }
  })
})
