// One-off: splice the updated migration/test content into the existing rehearsal wrapper, apply
// script, and dryrun copy, and update every pinned sha256 to match. Not part of the app build.
import fs from "node:fs"
import crypto from "node:crypto"

function sha256(text) {
  return crypto.createHash("sha256").update(text.replace(/\r/g, ""), "utf8").digest("hex")
}
function readLF(p) {
  return fs.readFileSync(p, "utf8").replace(/\r/g, "")
}

const migrationText = readLF("supabase/migrations/20261120100000_customer_link_otp.sql")
const testText = readLF("supabase/tests/customer_link_otp.test.sql")
const migrationHash = sha256(migrationText)
const testHash = sha256(testText)
console.log("migration sha256:", migrationHash)
console.log("test sha256:", testHash)

function spliceBetweenTags(source, openTag, closeTag, newInner) {
  const openIdx = source.indexOf(openTag)
  if (openIdx === -1) throw new Error("open tag not found: " + openTag)
  const innerStart = openIdx + openTag.length
  const closeIdx = source.indexOf(closeTag, innerStart)
  if (closeIdx === -1) throw new Error("close tag not found: " + closeTag)
  return source.slice(0, innerStart) + newInner + source.slice(closeIdx)
}

function replaceHashConstant(source, varName, newHash) {
  const re = new RegExp(`(${varName}\\s*text\\s*:=\\s*')[0-9a-f]{64,70}(')`)
  if (!re.test(source)) throw new Error("hash constant not found: " + varName)
  return source.replace(re, `$1${newHash}$2`)
}

// 1. Rehearsal wrapper: both $migration$...$migration$ and $testbody$...$testbody$, plus both pins.
{
  let f = fs.readFileSync("supabase/ops/customer_link_otp.rehearsal.sql", "utf8")
  f = spliceBetweenTags(f, "$migration$", "$migration$;", migrationText)
  f = spliceBetweenTags(f, "$testbody$", "$testbody$;", testText)
  f = replaceHashConstant(f, "v_expected_migration_hash", migrationHash)
  f = replaceHashConstant(f, "v_expected_test_hash", testHash)
  fs.writeFileSync("supabase/ops/customer_link_otp.rehearsal.sql", f)
  console.log("rewrote rehearsal.sql")
}

// 2. Apply script: only $migration$...$migration$ and its one pin.
{
  let f = fs.readFileSync("supabase/ops/20261120100000_customer_link_otp.apply.sql", "utf8")
  f = spliceBetweenTags(f, "$migration$", "$migration$;", migrationText)
  f = replaceHashConstant(f, "v_expected_migration_hash", migrationHash)
  fs.writeFileSync("supabase/ops/20261120100000_customer_link_otp.apply.sql", f)
  console.log("rewrote apply.sql")
}

// 3. DRYRUN copy: same migration splice + pin, keep its own extra DRYRUN_OK raise line intact
// (it's outside the $migration$...$migration$ block, in the outer DO block body).
{
  let f = fs.readFileSync("supabase/ops/20261120100000_customer_link_otp.apply.dryrun.sql", "utf8")
  f = spliceBetweenTags(f, "$migration$", "$migration$;", migrationText)
  f = replaceHashConstant(f, "v_expected_migration_hash", migrationHash)
  fs.writeFileSync("supabase/ops/20261120100000_customer_link_otp.apply.dryrun.sql", f)
  console.log("rewrote apply.dryrun.sql")
}

console.log("DONE")
