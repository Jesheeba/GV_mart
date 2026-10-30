# Drop 1 apply — read-only before/after proof

This documents, in plain language, exactly what `20261125100000_product_lifecycle_drop1.apply.sql`
compares before vs. after running the 8 migrations, so the owner can eyeball the logic without reading
raw PL/pgSQL. Every check below already exists inside the apply script's own `DO` block (same
transaction as the migrations — if any check fails, `RAISE EXCEPTION` aborts everything atomically,
nothing partial survives). This file adds no new SQL; it is a reading guide, referencing the apply
script's own line numbers.

## 1. Org fingerprint — proves this is the right database, and that it's unchanged after

- **Before** (apply.sql line 1168): `md5(organizations.id::text || '|' || organizations.name)` of the
  oldest non-`__TEST_` organisation.
- **Check** (line 1175-1177): must equal the pinned value `6f891cf85011f08c2f22fb4a208d21bd` — refuses
  immediately if not (wrong database, or the real org's name/id somehow changed before this ran).
- **After** (line 1277-1281): the identical `md5(id||'|'||name)` query, re-run after all 8 migrations
  executed. Must be byte-identical to the "before" value. This migration set never writes to
  `organizations` (it only reads `installations_logged`/`service_visits`/`service_tickets` in the
  backfill step, and writes only into its own new tables) — so any difference here would mean something
  outside this migration set's own scope touched that row mid-transaction, and the apply refuses.

## 2. `report_kpi_tiles` definition pin — proves we're replacing the function we reviewed, not a
   drifted one

- **Before** (line 1197-1200): CR-tolerant sha256 (`regexp_replace(..., CRLF, LF)` then sha256) of the
  live function definition, taken fresh at apply time.
- **Check** (line 1201-1203): must equal `678b4f865db828a5e6ac0e9c4221e0530fc0bc67e5793a0c1da69b62f37909a8`
  (the hash recorded when the live definition was fetched during Stage 1 planning — see
  `_local_only/reports/product_lifecycle/q_fetch_kpi_def.sql.out.txt`). Refuses if the live function has
  changed since that fetch (someone else shipped a different `report_kpi_tiles` edit in the meantime).

## 3. `report_kpi_tiles` VALUES — proves every existing tile is byte-for-byte unchanged

This is the part that actually matters to a human reading a dashboard, as opposed to just the function
source text.

- **Impersonation** (line 1213-1225): the Management API connection has no JWT, so `auth.uid()` (and
  therefore `current_role()`/`_report_org()` inside `report_kpi_tiles`) would resolve to nothing and
  every branch of the function would short-circuit empty — proving nothing. The script sets
  `request.jwt.claims` to one real, active `master` profile of the pinned org (`'sub'` claim), for this
  transaction only (`set_config(..., true)` = transaction-local, auto-cleared on commit/rollback, never
  persisted). This makes the "before"/"after" calls below exercise the real master+ops branches that
  carry the new `lifecycle` key — otherwise there would be nothing to compare.
- **Before** (line 1228): `report_kpi_tiles(2026-10-01, 2026-10-29)` called once, full result stored.
- *(migrations execute here)*
- **After** (line 1284): the identical call, same fixed probe window, called again.
- **Check A** (line 1285-1287): `v_kpi_before - 'service'` must equal `v_kpi_after - 'service'` — i.e.
  every top-level key EXCEPT `service` (`window`, `role`, `sales`, `money_out`) must be byte-for-byte
  identical. These are untouched by this migration set's function-body edit.
- **Check B** (line 1288-1290): `v_kpi_before->'service' - 'lifecycle'` must equal
  `v_kpi_after->'service' - 'lifecycle'` — i.e. inside `service`, every existing tile (`open_tickets`,
  `resolved_within_24h`, `rating`, `amc`) must be byte-for-byte identical; only the brand-new `lifecycle`
  key is allowed to differ (it goes from not existing to existing, by design).
- Together, A+B are the complete "nothing existing changed" proof — not a sampling, not a tolerance, an
  exact structural diff of the entire real JSON payload for a fixed window.

## 4. Anon/PUBLIC function-exposure — proves no new function leaked to anonymous access

This project has hit this exact leak before (memory: `gv_mart_default_privileges_anon_execute_leak`) —
new functions can auto-inherit EXECUTE for `anon` via this Supabase project's own default privileges,
independent of what the migration's own `revoke` statements say.

- **Before** (line 1231-1234): the full list of every `public`-schema function `anon` can currently
  EXECUTE, as an array of `regprocedure` signatures — taken before touching anything.
- *(migrations execute here, including migration 100700's own explicit revoke sweep)*
- **After** (line 1265-1268): the identical query, re-run.
- **Check** (line 1269-1273): the **diff** of after-minus-before — i.e. only functions that are NEWLY
  anon-executable fail this check. A pre-existing, unrelated leak from some other feature is reported
  nowhere near this error path and never blocks this apply; only a leak this migration set itself
  introduced does.
- A second, independent listing (apply.sql lines 1305-1324, run as a plain read-only `SELECT` after the
  `DO` block commits) prints RLS-enabled flag + anon-SELECT flag for every new table, and anon-EXECUTE
  flag for every new function, by name — the actual thing to eyeball, not just a pass/fail boolean.

## What this file is not

It is not new SQL and does not run anything itself — every check described above already exists,
verbatim, inside `20261125100000_product_lifecycle_drop1.apply.sql`. This file exists only so the proof
can be reviewed without reading 300+ lines of PL/pgSQL line by line.
