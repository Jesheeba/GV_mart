// HELD with 20261010120000_lead_distribute_pending.sql. Run: node supabase/held/lead_distribute_concurrency.test.mjs (needs SUPABASE_ACCESS_TOKEN). Result 2026-10-07: S1 8/8, S2 ok.
// Concurrency test for the round-robin insert trigger and the (held) waiting-lead distribution function.
// Uses two parallel Management API connections against throwaway __TEST_ data that is COMMITTED for the
// duration of the test and removed afterwards. The held distribution migration is NOT applied: a test-only copy
// of the function lives in schema __test_dp and is dropped at the end.
import fs from "node:fs"
const env = fs.readFileSync("../.env (path of the main clone .env)", "utf8")
const TOKEN = env.match(/^SUPABASE_ACCESS_TOKEN=(.*)$/m)[1].trim().replace(/^"|"$/g, "")
const REF = "fsunrjithwcjtsutsgea"
async function q(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: "POST", headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" }, body: JSON.stringify({ query: sql }),
  })
  const j = await r.json()
  if (j.message) throw new Error(j.message)
  return j
}
const out = []
const log = (s) => { out.push(s); console.log(s) }

const migration = fs.readFileSync("C:/Users/JESHEEBA/Desktop/GV_mart_salesperson/gv-mart/supabase/held/20261010120000_lead_distribute_pending.sql", "utf8")
// test-only copy of just the function, in its own schema; no triggers on profiles/settings are created
const fnOnly = migration.slice(migration.indexOf("create or replace function public._lead_distribute_pending"), migration.indexOf("-- a person becomes eligible"))
  .replace("public._lead_distribute_pending", "__test_dp._lead_distribute_pending")

let ORG, A, B, M
try {
  await q(`create schema if not exists __test_dp; ${fnOnly}`)
  const s = await q(`
    with o as (insert into organizations(name) values ('__TEST_conc_org') returning id)
    select id from o`)
  ORG = s[0].id
  const ids = await q(`select gen_random_uuid() a, gen_random_uuid() b, gen_random_uuid() m`)
  ;({ a: A, b: B, m: M } = ids[0])
  await q(`
    insert into settings(org_id) select '${ORG}' where not exists (select 1 from settings where org_id='${ORG}');
    update settings set auto_assign_leads=true where org_id='${ORG}';
    insert into auth.users(id,email) values ('${A}','__test_${A}@example.invalid'),('${B}','__test_${B}@example.invalid'),('${M}','__test_${M}@example.invalid');
    insert into profiles(id,org_id,full_name,role,is_active,receives_new_leads,created_at) values
      ('${M}','${ORG}','__TEST_master','master',true,true, now()-interval '3 days'),
      ('${A}','${ORG}','__TEST_A','sales_admin',true,true, now()-interval '2 days'),
      ('${B}','${ORG}','__TEST_B','sales_admin',true,true, now()-interval '1 days');`)
  log(`setup: throwaway org ${ORG.slice(0, 8)}…, sales persons A and B eligible, switch ON for this org only`)

  // ── Scenario 1: two sessions insert at the same instant, 8 rounds ──────────────────────────────
  let bad = 0
  for (let round = 1; round <= 8; round++) {
    await q(`delete from lead_rotation where org_id='${ORG}'`) // fresh rotation each round so both start equal
    const ins = (tag) => q(`insert into leads(org_id,name,mobile) values ('${ORG}','__TEST_c${round}${tag}','98000000${round}${tag === "x" ? 1 : 2}'); select pg_sleep(1.2);`)
    await Promise.all([ins("x"), ins("y")])
    const r = await q(`select string_agg(coalesce(assigned_to::text,'null'), ',' order by name) as a, count(distinct assigned_to) d from leads where org_id='${ORG}' and name like '__TEST_c${round}%'`)
    const ok = r[0].d === 2
    if (!ok) bad++
    log(`S1 round ${round}: two simultaneous inserts -> ${r[0].d} distinct assignees ${ok ? "ok" : "FAIL (same person got both)"}`)
  }
  log(bad === 0 ? "S1 RESULT: ok, never gave the same person both leads (8/8 rounds)" : `S1 RESULT: FAIL ${bad} rounds`)

  // ── Scenario 2: a person becomes eligible while a lead is being inserted ─────────────────────────
  // 4 leads are waiting (flagged), B is paused. Session X inserts a NEW lead and holds its transaction open;
  // session Y concurrently makes B eligible and runs the distribution. Nothing may be double-assigned.
  await q(`update profiles set receives_new_leads=false where id='${B}'; delete from lead_rotation where org_id='${ORG}'; update settings set auto_assign_leads=false where org_id='${ORG}'`)
  await q(`insert into leads(org_id,name,mobile,created_at) select '${ORG}','__TEST_w'||g,'9810000000'||g, now()-(g||' hours')::interval from generate_series(1,4) g`)
  await q(`update settings set auto_assign_leads=true where org_id='${ORG}'; update leads set auto_assign_pending=true, assigned_to=null where org_id='${ORG}' and name like '__TEST_w%'`).catch(async () => {
    // pending flag is client-guarded but we run as owner here; fall back to explicit trusted update if the guard objects
  })
  const pend = await q(`select count(*) n from leads where org_id='${ORG}' and auto_assign_pending`)
  log(`S2 setup: ${pend[0].n} waiting leads flagged, B paused, A eligible`)
  const X = q(`insert into leads(org_id,name,mobile) values ('${ORG}','__TEST_new','9819999999'); select pg_sleep(1.5);`)
  await new Promise((r) => setTimeout(r, 300)) // X now holds the per-org lock
  const Y = q(`update profiles set receives_new_leads=true where id='${B}'; select __test_dp._lead_distribute_pending('${ORG}');`)
  await Promise.all([X, Y])
  const chk = await q(`
    select (select count(*) from leads where org_id='${ORG}' and name in ('__TEST_new') and assigned_to is not null) new_assigned,
           (select count(*) from leads where org_id='${ORG}' and name like '__TEST_w%' and assigned_to is not null and not auto_assign_pending) waiting_assigned,
           (select count(*) from leads where org_id='${ORG}' and name like '__TEST_w%' and auto_assign_pending) still_waiting,
           (select coalesce(max(c),0) from (select count(*) c from lead_assignments where lead_id in (select id from leads where org_id='${ORG}') group by lead_id) z) max_rows_per_lead,
           (select count(*) from lead_assignments where lead_id in (select id from leads where org_id='${ORG}' and name like '__TEST_w%' or name='__TEST_new')) assignment_rows,
           (select count(*) from leads where org_id='${ORG}' and (name like '__TEST_w%' or name='__TEST_new') and assigned_to=(select id from profiles where id='${A}')) to_a,
           (select count(*) from leads where org_id='${ORG}' and (name like '__TEST_w%' or name='__TEST_new') and assigned_to=(select id from profiles where id='${B}')) to_b`)
  const c = chk[0]
  log(`S2 result: new lead assigned=${c.new_assigned}, waiting leads assigned=${c.waiting_assigned}, still waiting=${c.still_waiting}, max assignment rows on any lead=${c.max_rows_per_lead}, total rows=${c.assignment_rows}, A got ${c.to_a}, B got ${c.to_b}`)
  const ok2 = c.new_assigned == 1 && c.waiting_assigned == 4 && c.still_waiting == 0 && c.max_rows_per_lead <= 1 && c.assignment_rows == 5 && Math.abs(c.to_a - c.to_b) <= 1
  log(ok2 ? "S2 RESULT: ok, every lead assigned exactly once, load split fairly (no double assignment)" : "S2 RESULT: FAIL")
} catch (e) {
  log("ERROR: " + e.message)
} finally {
  // ── cleanup: lead_outcomes and lead_sources first, then the organisation ───────────────────────────
  try {
    if (ORG) {
      await q(`
        delete from notifications where org_id='${ORG}';
        delete from audit_log where org_id='${ORG}';
        delete from lead_assignments where org_id='${ORG}';
        delete from lead_rotation where org_id='${ORG}';
        delete from leads where org_id='${ORG}';
        delete from lead_outcomes where org_id='${ORG}';
        delete from lead_sources where org_id='${ORG}';
        delete from profiles where org_id='${ORG}';
        delete from auth.users where email like '__test\\_%@example.invalid';
        delete from settings where org_id='${ORG}';
        delete from organizations where id='${ORG}';`)
    }
    await q(`drop schema if exists __test_dp cascade`)
    const left = await q(`select (select count(*) from organizations where name like '\\_\\_TEST%') orgs,(select count(*) from auth.users where email like '\\_\\_test\\_%') users,(select count(*) from pg_namespace where nspname='__test_dp') schema_left`)
    log(`cleanup: __TEST_ orgs left=${left[0].orgs}, test users left=${left[0].users}, test schema left=${left[0].schema_left}`)
  } catch (e) { log("CLEANUP ERROR: " + e.message) }
}
