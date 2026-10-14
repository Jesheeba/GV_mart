# Release review: release/b17-batch5 (26 commits) and how it was assembled

Written 2026-10-14 so the reasoning lives in the repository, not in a chat session.

## 0. Read this first: batch5 is already on main

When this review was prepared, `git fetch` showed:

- `origin/release/b17-batch5` exists at `970c02a` (the tip of the local branch).
- `970c02a` is an **ancestor of `origin/main`** (`a08819b`). `git log origin/main..release/b17-batch5` is therefore empty.
- `origin/main` is 24 commits ahead of batch5 (batch6, batch7 and the Sales & Invoices KPI work were merged after it).

So the "26 commits" below are not waiting for a push; they were pushed and merged by someone other than the session that
built them (not verified who). The summary is still written against the range the branch had when it was built:
`e53a1f7..970c02a` (26 commits, `e53a1f7` being main at that time). Nothing in this document pushes anything.

## 1. The 26 commits, grouped

### 1.1 Migrations and rollbacks (database)
| Commit | What | Migration(s) |
|---|---|---|
| `61c9c3e` | dispatcher v2 schema: pending state, delivery columns, last-inbound contacts, template mirror and mapping | `20261016300000` |
| `8ccf2b3` | takes `20261016300000` and its test byte-for-byte from `feat/dispatcher-fix` (includes anon revokes already applied live) | `20261016300000` |
| `9be99e0` | per-number dispatcher v2 scope: empty list means nobody | `20261016330000` |
| `ef09003` | verification pass: stuck-pending and skipped-per-day alerts; unknown-outcome network errors never resent | `20261016310000`, `20261016320000` |
| `9f6cbd8` | revoke anon table privileges, stop new objects inheriting them | `20261016500000` |
| `155dc80` | rollback for `20261016500000` regenerated from live ACLs | rollback file |
| `a624206`, `4b4b8d2` | automation phase 2 foundation (event log, audit, rules, dry-run queue, `automation_emit`, emit hooks, failure isolation) | `20261017100000` |
| `8972a79` (orig `07f4126`) | `report_kpi_tiles` function + partial index (file name was a placeholder) | `PENDING_report_kpi_tiles.sql` |
| `aea204a` (orig `22adb7e`) | rename to the real version | `20261017110000_report_kpi_tiles.sql` |

### 1.2 Functions (Edge Functions, SQL functions)
| Commit | What |
|---|---|
| `05707bd` | dispatcher v2 send path, claim-before-send, webhook `delivery_status`, window logic (flag OFF) |
| `ef09003` | verification pass in the dispatcher (23 files under `supabase/functions` change across the dispatcher commits) |
| `8972a79` / `aea204a` | SQL function `report_kpi_tiles` (SECURITY DEFINER, `search_path=public`, authenticated only) |
| `a624206` | SQL: `automation_emit` and emit trigger functions |

### 1.3 UI and client services
| Commit | What |
|---|---|
| `0d320af` | KPI step 1: Owner/Sales dashboard tiles exclude `is_test` customers' leads, tickets, AMC (opt-in `excludeTest`) |
| `6fcf052` | KPI step 1b: Ops open tickets and Sales Quotation to Sale exclude test rows |
| `970c02a` | KPI step 1c: missing-product nag excludes test customers' tickets |
| `9491538` (orig `32ee996`) | KPI step 3: KPI tile strip on Owner, Ops, Sales dashboards and three Reports tabs; `kpi.*` strings en + ta (Tamil draft) |
| `db0433c` | Failed Sends screen shows skipped, delivery-failed and stuck rows; types for dispatcher v2 |

### 1.4 Tests
| Commit | What |
|---|---|
| `9303907` | live exclusion test avoids node globals so `tsc -b` stays clean |
| `a98def9` | v2 normaliser test sets the scope org explicitly |
| `8972a79` | `report_kpi_tiles.test.sql` (50 checks, rolled back), mapper tests, manifest entry |
| (inside others) | `kpiTilesView.test.ts`, `kpiTestExclusion*.test.ts`, automation timing tests |

### 1.5 Docs and merges
`7c797f4` (go-live: create tables only through migrations), `e4a2a16` (automation retention note), `441b1b5` (KPI Step 2 scope),
`de49797` (Step 3 UI plan), `65b1a2d` (Step 2 apply and Step 3 verification), plus merge commits `add3064`, `3f2141a`,
`6a61add`.

## 2. Migrations in the range and whether each is applied live

Checked against `supabase_migrations.schema_migrations` on 2026-10-14.

| Version | Name | Applied live |
|---|---|---|
| `20261016300000` | wa_dispatch_v2_schema | yes |
| `20261016310000` | wa_dispatch_v2_pending_normalisation | yes |
| `20261016320000` | wa_dispatch_v2_alerts_and_mappings | yes |
| `20261016330000` | wa_dispatch_v2_number_scope | yes |
| `20261016500000` | revoke_anon_table_privileges | yes |
| `20261017100000` | automation_phase2_foundation | yes |
| `20261017110000` | report_kpi_tiles | yes (applied 2026-10-17 session in one guarded transaction, ACL verified) |

All seven are live. The repository now matches the database for these versions.

## 3. Client-visible behaviour changes

1. **Dashboards (Owner, Ops, Sales) and Reports tabs (P&L, Sales & Service, Sales Insights) show the KPI tile strip.** The Owner
   headline revenue is now **net of GST** with the gross as a sub-line (it used to show the gross). Open Tickets, Lead
   Conversion, AMC due and Today's Sales on those screens now come from `report_kpi_tiles`.
2. **Test customers disappear from dashboard counts** (Owner/Ops/Sales tiles, Quotation to Sale, the Ops missing-product
   nag). List pages are unchanged and still show them.
3. **Ops dashboard gets a period filter** (default current IST month); live tiles ignore it.
4. **Failed Sends screen** lists skipped, delivery-failed and stuck rows (dispatcher v2).
5. **Anon table privileges revoked** (`20261016500000`): any page that relied on an anonymous read of a table directly stops
   working. The migration was tested and applied live; the staff app and customer app use authenticated sessions.
6. **WhatsApp delivery behaviour** (dispatcher v2) is behind a flag that was OFF at build time; the live flag state is
   recorded in the dispatcher hand-off doc, not here.
7. **Automation phase 2** is dry-run only: it records events and queues, it does not send.
8. **Tamil strings** for `kpi.*` are drafts (`docs/tamil-review-kpi.md`).

## 4. `sell_amc_plan`

No commit in this range edits `sell_amc_plan` (`git diff e53a1f7 970c02a -G sell_amc_plan` is empty). Files in the range
that mention it only call it: `src/services/amc.ts` (the RPC call), `src/lib/offline/sync.ts` (`sell_amc_plan_onsite`),
`src/types/database.ts` (generated signature). The range did change `src/services/amc.ts` and `src/hooks/useAmc.ts`, but
only `listAmcContracts` / `useAmcContracts` (the `excludeTest` option), not the sale call.

`feat/amc-assign-window` does redefine `sell_amc_plan` (migration `20261022100000_amc_visits_unassigned_until_due.sql`, NOT
applied at the time of writing).

## 5. Conflicts with `feat/amc-assign-window`

- Its merge-base with `origin/main` is `a08819b`, which already contains batch5. So batch5 landing cannot create a new
  conflict for that branch: the branch was cut after it.
- Files the AMC branch touches that also changed in this range: `src/lib/i18n/en.json`, `src/lib/i18n/ta.json`,
  `src/types/database.ts`. Both sides appended to these; because the branch is based on main they are already merged text.
  The only real risk is a future rebase after more i18n or `database.ts` additions: the `kpi.*` block was inserted as the
  first key of both JSON files, so keep additions elsewhere to avoid a repeat conflict at the top of the file.
- No overlap with `SellAmcPanel.tsx`, `TicketsListPage.tsx`, `ticketFilters.ts`, `amc-window.ts` or `validation/amc.ts`.
- Test file `supabase/tests/amc_and_test_flag.test.sql` is edited by the AMC branch; this range did not touch it.
- Database side: nothing in this range redefines `sell_amc_plan` or the AMC generators, so the AMC migration's
  `CREATE OR REPLACE` does not clobber any of these changes.

## 6. Cherry-pick reasoning for release/b17-batch5

Base: `release/b17-batch4` (`6a61add`). The KPI work had been built as a stack of branches
(`feat/kpi-step1-test-exclusion` -> `feat/kpi-step2-report-kpi-tiles` -> `feat/kpi-step3-ui`).

Skipped because batch4 already contained them as cherry-picks:

| Original | Already in batch4 as | Why skipped |
|---|---|---|
| `6e95702` KPI step 1 | `0d320af` | same patch; picking it again would be a duplicate |
| `8a07ade` live test node-globals fix | `9303907` | same |
| `c577f5b` KPI step 1b | `6fcf052` | same |
| `3d9d9b0` Step 2 scope doc | `441b1b5` | same; this commit also created the plan doc file, so later doc commits apply on top of it |

Picked, in this order, with no conflicts:

| Original | New | Note |
|---|---|---|
| `07f4126` Step 2 build | `8972a79` | migration under a placeholder name |
| `3b3d5a4` Step 3 UI plan | `de49797` | **not in the list the owner gave** |
| `22adb7e` rename migration | `aea204a` | |
| `32ee996` Step 3 UI | `9491538` | |
| `e65d8a6` apply + verification note | `65b1a2d` | |

Why `3b3d5a4` was added although it was not listed: it is the commit that creates section 11 (the Step 3 UI plan) of
`docs/plan-kpi-tiles.md`. The later doc commits (`32ee996` appends 11.11, `e65d8a6` appends 11.12) append at the end of
that section, so without it they either fail to apply or leave 11.11 and 11.12 without the section they describe. It is
documentation only; it changes no code or database.

One further change was made on top and is not a cherry-pick: `970c02a` (KPI step 1c, the missing-product nag fix, plus the
end-of-work credential rotation section in the go-live checklist), requested in the same instruction.

Resolution rule agreed for conflicts: keep batch4's version of a duplicate or conflicting hunk and report it. No
conflict occurred; the i18n files auto-merged.

## 7. Credential rotation section

Section 9 of `docs/go-live-checklist-sales-persons.md` lists the credentials to rotate by name only
(`SUPABASE_DB_PASSWORD`, the Supabase personal access token variable, `SUPABASE_SERVICE_ROLE_KEY`, test-login passwords,
Desktop database backups) and where to update them after rotating. It contains **no values**: no password, token, key,
connection string or phone number. This was checked by reading the section and by a pattern search for long
token-like strings.
