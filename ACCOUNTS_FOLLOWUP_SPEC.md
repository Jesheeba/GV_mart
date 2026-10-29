# GV Mart — Accounts follow-up: Customer Outstanding ↔ Reminders/Tasks, and Expense Categories

Spec for Claude Code. Read this whole file before doing anything. It is written so that you never need to ask the owner a question: every product decision is already made below, and for anything not covered you decide yourself using the **Decision policy** (section 9) and record it in `DECISIONS.md`.

Owner: GV Mart (RO / AC / inverter / battery retail and service). Stack: Vite + React 19 + TypeScript + Supabase/Postgres, Vercel (admin web). Repo root contains the `gv-mart/` app folder (`gv-mart/src`, `gv-mart/supabase/migrations`, `gv-mart/supabase/ops`, `gv-mart/supabase/tests`, `gv-mart/supabase/rollbacks`). Verify paths yourself.

---

## 1. The client request (verbatim, transcribed)

> In the Accounts section, there are Sales, Purchase, Receipt, Payment, Vendor Payment, Customer Outstanding, and Expenses.
> For Expenses, I only need an Under Category field. It should allow me to create and select categories as needed, such as Marketing Expenses, Sales Expenses, Petrol, Salary, Incentives, and so on. I should be able to create and manage these categories myself based on my requirements.
> Please implement only this functionality. No other changes are required.
> One important point: Customer Outstanding must be integrated with the Reminder and Task modules so that reminders and tasks can be created and managed for outstanding customer payments. This is the most important requirement.

## 2. Scope

**In scope**
- **Feature B (priority, ship first):** Customer Outstanding integrated with the existing Reminder and Task modules.
- **Feature A (second):** an "Under Category" field on Expenses with owner-managed categories.

**Out of scope (do not touch):** any other Accounts page (Sales, Purchase, Receipt, Payment, Vendor Payment), restyling, refactors, report changes, filters on expenses, new reports, the technician app / Capacitor / APK, WhatsApp or any messaging, existing migrations (never edit an already-written or already-rehearsed migration; only add new ones).

## 3. Decisions already made (do not re-open; refine only if analysis proves one impossible, then log it)

### Feature B — Customer Outstanding ↔ Reminders and Tasks
1. From the **Customer Outstanding list** and from a customer's outstanding detail, staff can **create a reminder** and **create a task** for that customer's outstanding payment. The forms are prefilled: customer, outstanding amount, oldest due date, suggested due date, suggested assignee. Everything is editable.
2. The **link is stored**: customer id, optional invoice id, and an amount snapshot. Use additive nullable columns or a small link table on the reminder/task side. **No change to existing rows.**
3. The Customer Outstanding page **shows per customer**: number of open reminders and the next reminder date; number of open tasks, assignee and status. From there staff can open, reschedule, complete or cancel them (reuse the existing Reminder/Task components or deep-link if they already manage this well).
4. The **Reminder and Task modules show the outstanding link back** (customer, amount snapshot, link to the customer's outstanding).
5. When a customer's outstanding becomes **zero**: automatically **close the linked open reminders** with a system note. **Do not auto-complete tasks** (tasks have completion rules and purchase-order tasks mark a PO paid on completion): instead show a "payment received" badge on the linked tasks and leave them to staff.
6. **Reminders and tasks created here are INTERNAL staff items only.** They never send anything to a customer. If the existing Reminder module can send external messages (WhatsApp, SMS, email), the new integration must create only internal reminders (no external channel) and the plan must say so.
7. **Roles:** follow the existing Accounts role rules (master and the admins that can already open Customer Outstanding). `sales_admin` is the salesperson role: they get it only if they already see Customer Outstanding. **Technicians never see outstanding amounts, nor these reminders/tasks.**
8. **Performance:** ~16,400 customers exist. Paginate. Outstanding totals come from one aggregate view/RPC, never per-row queries from the client. (The Customers list once took 7+ seconds from an unbounded count; do not repeat that.) The reminder/task counts per customer must be fetched in one set-based query for the visible page.

### Feature A — Expense categories
1. New table `expense_categories`: `org_id`, `name`, active flag, `created_by`, `created_at` (and `updated_at` if the codebase convention uses it). **Case-insensitive unique name per organisation.**
2. The Expenses create/edit form gets **one new field, "Under Category"**: a select with an inline **"Create new category"** action, plus a small **Manage categories** dialog: add, rename, deactivate, and delete **only if unused**.
3. `expenses` gets a **nullable `category_id`** FK. Existing expenses stay uncategorised. **No seeded categories** (the client creates their own: Marketing Expenses, Sales Expenses, Petrol, Salary, Incentives, ...).
4. Show the category in the expenses list. **No filters, no report changes, nothing else.**
5. **Overlap warning:** an unapplied package on branch `feat/monthly-expenses-v2` (migrations `20261107100000`–`20261107100500`, wrapper `supabase/ops/rehearsals/rehearse_combined_all_units.sql`) changes expenses. Find out what it adds. If categories exist there in any form, reuse them; never duplicate; never edit those migrations. Your category migration must work both with the live `expenses` table today and after that package is applied (check column and constraint names carefully). If the live DB has no `expenses` table yet and the table only comes from that package, say so in the plan, make migration A depend on it, and order accordingly.

## 4. Hard rules (never break)

- Never print or write API keys, tokens, passwords, webhook secrets, full phone numbers or WhatsApp message ids anywhere (chat, logs, files). Never disable TLS verification. Never `supabase db push`. Never force-push.
- Real customers must receive nothing. `wa_test_mode_enabled` stays ON. **No feature may send WhatsApp/SMS/email to a customer.** The only test number is the one ending 6740 (refer to it only that way).
- Security: no SECURITY DEFINER function may test `current_user`/`session_user`; every new function gets explicit `revoke ... from public, anon, authenticated`, then only the needed grants, and a fixed `search_path`; new tables get explicit revoke then narrow grants, RLS on, org-scoped; qualify outer columns inside RLS subqueries; nothing executable by PUBLIC/anon (check with a before/after diff of `public` functions executable by PUBLIC/anon); an invoker function must not call `is_test_customer()` (use `customers.is_test`); master tables use the existing audit trigger `audit_master_change()` and `set_updated_at` where the codebase does.
- Notifications: `public.notifications` requires exactly one of `user_id` / `role` to be set.
- Use the existing helpers (verify names): `current_org_id()`, `is_staff()`, `is_ops_staff()`, `is_master()`, `current_technician_id()`.
- All user-facing text in English **and Tamil** (`en.json` / `ta.json`). Tamil is unreviewed by a native speaker: flag it in the final report.
- Work only in your own worktree: `GV_mart\_local_only\worktrees\accounts-followup`, branched from a **fresh `origin/main`** (`git fetch` first). Never touch the divergent local `main` (a backup branch `backup/local-main-0dad54c` holds it). Never merge `ui-ux-improvements`. Reports go to `GV_mart\_local_only\reports\accounts_followup\` (git-excluded; never `git add -f`; never `git clean -fdx`). Nothing on the Desktop.
- Feature branch: `feat/accounts-outstanding-followups`. Never push to `main` except as the controlled step in Stage 2 (section 8.6).

## 5. How to reach the database

Only through the Supabase Management API: `POST /v1/projects/{ref}/database/query` with `SUPABASE_ACCESS_TOKEN` already in the environment, using the reviewed runner `GV_mart\_local_only\reports\run_rehearsal.mjs`. **Before first use verify its sha256 equals `001c54de5364f98e232a26c5ada1c929289243cd2bad00cc008c595c43beafb4`.** It takes one SQL file path, makes one request, writes `<input>.out.txt`, prints only the status. Read the output file yourself, every line. The direct DB host is IPv6-only (unreachable) and the pooler failed TLS verification: do not try them. If the Claude Code permission gate blocks a command, do not work around it: print the exact allow rule needed and continue with other work.

Facts: live `schema_migrations` was applied through `20261024171000` plus whatever the main release (running in another window, log at `GV_mart\_local_only\reports\release_2026-10-28\release_log.md`) has applied since. Real organisation fingerprint: md5 of `id || '|' || name` of the oldest non-`__TEST` organisation = `6f891cf85011f08c2f22fb4a208d21bd`.

## 6. Migration and test conventions (learned the hard way)

- New migrations get timestamps **after the newest existing migration** (start at `20261115100000` for B and `20261115110000` for A; move upward if needed). Each has a rollback script and a DB test file.
- Every rehearsal wrapper: **ONE `DO` block**, no top-level begin/commit/savepoint/rollback; `lock_timeout` 5s as the first statement; time gate **11:00 IST** (owner decision; the gate is 11:00 for rehearsals and applies today); organisation fingerprint pin; embedded migration and test text with **CR-tolerant** sha256 pins (hash and execute `replace(text, E'\r', '')`, because the Windows clipboard turns LF into CRLF); live-definition pre-check for every function it redefines; throwaway `__TEST_` organisations; ends in an unconditional `RAISE EXCEPTION 'RESULTS...'` so nothing persists.
- Gotchas: `pg_temp` helper functions in tests need `do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;`. `pg_get_functiondef` of a pg_temp function prints `pg_temp_N.` (use regex `pg_temp(_[0-9]+)?\.`). `pg_trigger.tgattr::int2[]` has lower bound 0 (compare via text). `RETURNS TABLE` column names are plpgsql variables: qualify columns in CTEs (error 42702 otherwise). `language sql` functions are validated at CREATE time (a missing table is 42P01). `select ... from pg_proc where proname = 'x'` can return two rows once a pg_temp copy exists: use `oid = '...'::regprocedure`. Snapshot/check SQL must not reference objects the migration creates (use `to_regclass`/`to_regprocedure`; never a literal `'public.x'::regclass` cast in a CASE branch: it is resolved at parse time).
- GO APPLY scripts: copy the approved template with `git show feat/technician-pending-reviews:supabase/ops/20261112100000_technician_pending_reviews.apply.sql` (commit `bbf5fcc`): temp status table; ONE `DO` block (no begin/commit); org pin; `lock_timeout` 5s; **11:00 IST** gate; refuse if the version is already registered; CR-tolerant sha256 pin of the embedded migration; live-definition pre-checks; register `supabase_migrations.schema_migrations (version, name, statements)` in the same transaction; diff-based "newly exposed to PUBLIC/anon" check plus an absolute "not executable by anon" check for each new function; a final read-only status `SELECT`. Every snapshot SQL must run cleanly **before** the apply.

## 7. STAGE 1 — Analyse and plan (read-only). Then STOP.

Do only this until the owner replies **APPROVED**:
1. Create the worktree (the only write allowed). Run read-only database queries through the runner.
2. Analyse: the Accounts pages/routes/services/hooks and the tables/views behind Sales, Purchase, Receipt, Payment, Vendor Payment, Customer Outstanding and Expenses; how outstanding is computed today (invoice total vs `amount_paid` / `payment_status` / receipts); which roles can open Customer Outstanding; how the page paginates. The Reminder module (tables, RPCs, RLS, UI, who can create/assign, notifications, external-send behaviour). The Task module (tables, RPCs, RLS, UI, completion rules incl. migration `20261101100000_task_completion_rule` and the purchase-order tasks). The live `expenses` table and the unapplied expenses package (section 3, Feature A, item 5). Other unapplied migrations on other branches that touch the same tables.
3. Write `GV_mart\_local_only\reports\accounts_followup\plan.md` with: findings; data model and migrations (names, timestamps, columns, FKs, indexes); RLS and grants per table/function; RPCs/views; UI changes per page/component; role matrix; the i18n keys; the test plan (SQL rehearsal cases and vitest cases); rollout and rollback; risks; every decision you made that this spec did not already make (each also in `DECISIONS.md`); an honest list of things you could not determine.
4. Print in chat a **short summary of the plan** (about 25 lines) and the exact words **"Waiting for APPROVED."** Then **stop and wait**. Do not write code, do not create branches other than the worktree branch, do not run anything except read-only queries.

## 8. STAGE 2 — Build, test, rehearse, ship (starts only on the owner's APPROVED message)

The owner's typed APPROVED message (in the chat, in their own words) is their written authorisation for everything in this section, including live applies and the push to `main`. From then on, **do not ask the owner any question.** Follow section 9 for every decision.

**8.1 Build B first**: migration + rollback + DB test, service layer and hooks (React Query, consistent with the codebase), UI in the existing design system, i18n en + ta. Run `npm run build`, lint and vitest after each feature (known unrelated failure: `testCustomerGuard.test.ts`; any new failure is a stop-and-fix). One commit per logical step on `feat/accounts-outstanding-followups`; push the branch.
**8.2 Build A second**, same way.
**8.3 Rehearse** each migration (wrapper per section 6) through the runner; read every line. Fix and re-run until every line is PASS (max 3 attempts per distinct failure; after that mark that feature BLOCKED and report). The rehearsal must prove: the role matrix (who can and cannot), RLS org isolation, anon/PUBLIC cannot execute, technician sees nothing, link create/close behaviour, outstanding-zero auto-close of reminders, category unique/rename/deactivate/delete-if-unused, and that the real-organisation fingerprint is unchanged.
**8.4 Apply scripts + snapshots** per section 6. Spawn a **fresh independent reviewer agent per apply script** (it sees only the script, the migration, and a checklist: pins, gate 11:00, atomicity, grants, PUBLIC/anon, search_path, no `current_user` tests, no messaging, pre-check present, registration present, status SELECT present, snapshot runs pre-apply). Run a script only when the reviewer says APPROVED.
**8.5 Backup, then apply live**, B then A: first a definitions backup (pg_get_functiondef of every function being redefined, policies and trigger definitions of touched tables, row counts and fingerprints) into the local reports folder (never printed, never committed), read back and checked. **Never run a live apply while the main release is still applying**: read `release_log.md`; if its database phase is not finished, complete everything else and re-check; if still not finished, stop and report **READY TO APPLY** with the exact steps. After each apply read the status `SELECT`, run the snapshot again and compare.
**8.6 Code to main**: create a fresh branch from `origin/main`, merge `feat/accounts-outstanding-followups`, run build + lint + vitest, then `git push origin <branch>:main` as a plain fast-forward (no force; if rejected, stop and report). Vercel deploys from `main`. This is admin web only: **no APK change**.
**8.7 Verify read-only on live data**: the new views/RPCs return, counts are sane, no PUBLIC/anon-executable function is newly exposed.

## 9. Decision policy (this replaces asking questions)

- Pick the **safest option consistent with this spec**: additive over destructive, nullable over backfilled, internal-only over customer-facing, least privilege over convenience, smallest change over refactor.
- Record each decision in one line in `DECISIONS.md` (what, why, alternative rejected). Do not ask.
- **Stop conditions** (the only reasons to stop and report): a live apply or its post-check fails (no retry, no rollback; read-only state checks only); a rehearsal still failing after 3 attempts on the same cause (that feature only: mark BLOCKED, continue with the other); a merge conflict that is not mechanical (import order, i18n key additions, lockfile); a push to `main` rejected; a permission-gate block (print the allow rule, continue with other work); anything that would send a message to a real customer.
- If the spec and the analysis disagree, the analysis of the real code wins; log it.
- Never expand scope. If you find an unrelated bug, list it in the final report; do not fix it.

## 10. Final report (chat, short; long version saved as `final_report.md`)

What was built per feature; files changed; migrations with versions and sha256; rehearsal results; reviewer verdicts; what is live and what is READY but not applied; the new `origin/main` tip; every command the permission gate blocked (with the allow rule needed); every decision made; unrelated bugs found; and the **owner's manual test script**:
1. As master, open Customer Outstanding for a test customer, create a reminder and a task from it.
2. See them on the outstanding row (counts, next date, assignee, status) and inside the Reminder and Task modules (link back).
3. Record a full payment for that customer: the reminder auto-closes with a system note; the task shows "payment received" and stays open.
4. Create, rename and deactivate expense categories; use one on an expense; try to delete a used one (must refuse); confirm an old expense shows as uncategorised.
5. Log in as a technician: none of this is visible.
6. As `sales_admin` (if they have Customer Outstanding access): same as step 1; otherwise confirm they see nothing.
Flag: Tamil strings need a native check. Open client questions (do not block on them): should outstanding reminders ever contact the customer (WhatsApp/SMS)? Currently internal only.
