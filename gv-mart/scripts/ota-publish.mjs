#!/usr/bin/env node
// One-command OTA publish: build the web bundle, zip it, sign the
// manifest, and drop both into public/ota/<channel>/ so the next Vercel
// deploy (a plain git push — no store build) serves it.
//
// Usage:
//   OTA_PRIVATE_KEY_PATH=../../_local_only/secrets/ota/ota-signing-private.jwk.json \
//   node scripts/ota-publish.mjs --channel technician-test --build 3 --min-native-build 1 [--frozen] [--notes "..."]
//
// The private key path defaults to the standard _local_only/secrets
// location two levels above the worktree root, so a normal release from
// the main checkout needs no env var at all.

import { execFileSync } from "node:child_process"
import { createHash, sign } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import AdmZip from "adm-zip"

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..")

function parseArgs(argv) {
  const args = { channel: "technician-test", frozen: false, notes: "" }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === "--channel") args.channel = argv[++i]
    else if (a === "--build") args.buildNumber = Number(argv[++i])
    else if (a === "--min-native-build") args.minNativeBuild = Number(argv[++i])
    else if (a === "--frozen") args.frozen = true
    else if (a === "--notes") args.notes = argv[++i]
    else if (a === "--private-key") args.privateKeyPath = argv[++i]
  }
  return args
}

function canonicalManifestString(m) {
  return [m.channel, m.version, String(m.buildNumber), m.url, m.checksum, String(m.minNativeBuild), String(m.frozen), m.publishedAt].join("|")
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.channel !== "production" && args.channel !== "technician-test") {
    throw new Error(`--channel must be "production" or "technician-test", got "${args.channel}"`)
  }
  if (!Number.isFinite(args.buildNumber) || args.buildNumber <= 0) {
    throw new Error("--build <positive integer> is required (strictly increasing per channel)")
  }
  if (!Number.isFinite(args.minNativeBuild) || args.minNativeBuild <= 0) {
    throw new Error("--min-native-build <positive integer> is required (native versionCode floor)")
  }

  const privateKeyPath = args.privateKeyPath ?? process.env.OTA_PRIVATE_KEY_PATH ?? resolve(repoRoot, "..", "..", "..", "secrets", "ota", "ota-signing-private.jwk.json")
  if (!existsSync(privateKeyPath)) {
    throw new Error(`OTA signing private key not found at ${privateKeyPath}. Pass --private-key <path> or set OTA_PRIVATE_KEY_PATH.`)
  }

  console.log("> npm run build")
  execFileSync(process.platform === "win32" ? "npm.cmd" : "npm", ["run", "build"], { cwd: repoRoot, stdio: "inherit" })

  const distDir = join(repoRoot, "dist")
  if (!existsSync(distDir)) throw new Error("dist/ not found after build")

  console.log("> zipping dist/")
  const zip = new AdmZip()
  zip.addLocalFolder(distDir)
  const zipBuffer = zip.toBuffer()

  const version = `${new Date().toISOString().slice(0, 10)}-b${args.buildNumber}`
  const outDir = join(repoRoot, "public", "ota", args.channel)
  mkdirSync(outDir, { recursive: true })
  const bundleFileName = "bundle.zip"
  writeFileSync(join(outDir, bundleFileName), zipBuffer)

  const checksum = createHash("sha256").update(zipBuffer).digest("hex")

  // Filled in by the owner's deploy — the publish script doesn't know the
  // final Vercel domain, so it writes a placeholder the deploy step (or a
  // manual edit) must replace before pushing. See PUBLISH.md.
  const siteOrigin = process.env.OTA_SITE_ORIGIN ?? "https://REPLACE_WITH_VERCEL_DOMAIN"

  const payload = {
    channel: args.channel,
    version,
    buildNumber: args.buildNumber,
    url: `${siteOrigin}/ota/${args.channel}/${bundleFileName}`,
    checksum,
    minNativeBuild: args.minNativeBuild,
    frozen: args.frozen,
    publishedAt: new Date().toISOString(),
  }

  const privateKeyJwk = JSON.parse(readFileSync(privateKeyPath, "utf8"))
  const privateKey = { key: privateKeyJwk, format: "jwk" }
  const message = Buffer.from(canonicalManifestString(payload), "utf8")
  const signature = sign(null, message, privateKey).toString("base64")

  const manifest = { ...payload, signature }
  writeFileSync(join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2))

  console.log(`\nWrote public/ota/${args.channel}/manifest.json and bundle.zip`)
  console.log(`  version: ${version}  buildNumber: ${args.buildNumber}  checksum: ${checksum}`)
  if (siteOrigin.includes("REPLACE_WITH_VERCEL_DOMAIN")) {
    console.log(`\n  WARNING: manifest.url uses a placeholder domain. Re-run with OTA_SITE_ORIGIN=https://<your-vercel-domain> before committing, or hand-edit the url field.`)
  }
  console.log("\nNext: commit public/ota/** and push to main (Vercel deploys it automatically — no store build needed).")
}

main()
