# GV Mart: multi-agent build brief (2026-10-27)

You are the COORDINATOR. Read this whole file first. Then run FIVE agents in parallel (use your agent tool; give every agent its own isolated git worktree). Work end to end: verify what exists, build what is missing, test, push branches, report. Do not stop to ask questions unless a rule below says STOP.

---

## 1. Hard rules (every agent, always)

1. **No database access of any kind.** No live keys, no `SUPABASE_DB_URL`, no `supabase db push`, no `supabase link`, no remote project. You only write SQL files; you never run them against any real database.
2. **No push to `main`, no force-push, no merge into `main`.** Push only your own NEW feature branches. Never commit onto, or push to, an existing branch owned by another window (list in section 2).
3. **No WhatsApp or any message to a real customer, ever.** In-app notifications to staff (rows in the notifications table) are fine. The only test phone number is "the test number ending 6740".
4. **Never print or store secrets.** Never print keys, tokens, passwords, connection strings or full phone numbers. Never write credentials into any file, log or test output. Tests use throwaway `__TEST_` accounts and organisations with generated passwords that are never printed.
5. **Worktrees only under `GV_mart\_local_only\worktrees\<name>`**, created like this from the main repo (use `git -C <main GV_mart>`; never edit files in the main GV_mart folder itself):
   `git -C <main GV_mart> fetch origin` then `git -C <main GV_mart> worktree add _local_only/worktrees/<name> -b <new-branch> <base>`
6. **Nothing is created on the Desktop.** Reports, notes, backups go under `GV_mart\_local_only\reports` or `...\old-prompts`. `_local_only` is git-excluded: never commit it, never `git add -f` from it, never run `git clean -fdx`.
7. **Do not touch** the worktree `GV_mart_worktree_main_build`, and do not build an APK or open Android Studio.
8. **Do not rebuild what already exists.** If an item already exists and is correct (on main, or on another window's branch), report where and build nothing for it.
9. Every claim in your report needs evidence (file path plus function or component name). Do not guess.

---

## 2. Context you need

- Stack: Vite + React 19 + TypeScript + Supabase/Postgres, Capacitor Android app. A change to the technician or customer app code needs a new APK to reach phones; database changes and admin-web changes do not.
- Roles: master, operation_admin, sales_admin, technician, customer. Multi-tenant by `org_id`. Existing helpers (verify names in the repo): `current_org_id()`, `current_role()`, `is_staff()`, `is_ops_staff()`, `is_master()`, `current_technician_id()`, `current_customer_id()`.
- **Live database state:** migrations are applied through `20261024171000`. Everything with a later version is NOT live. A feature whose database part is unapplied counts as "not live" even if the code exists.
- **Branches owned by other windows (read them with `git show` / `git -C ... log`, never push to them):**
  - `feat/p1-task-security`, `feat/p2-staff-profile-huddle` (earlier tip c1524eb), `feat/p3-task-log-visibility` (earlier tip 570c5d4) — worktrees `GV_mart_p1`, `GV_mart_p2`, `GV_mart_p3` on the Desktop.
  - `pkg1/task-completion-rule`, `pkg2/staff-huddle-profile`, `pkg3/task-logs-colours-workspace-merge`, `pkg4/item-code` (earlier tip 77d1aa9), `pkg5/standard-minutes-and-efficiency` (earlier tip cc5cf3a) — worktrees `GV_mart_pkg1` to `GV_mart_pkg5` on the Desktop.
  - `feat/technician-leave-request-v2`, `feat/monthly-expenses-v2`, `feat/customer-water-profile`, `feat/customers-speedup-followups`.
- **How to build a missing or partial piece on top of an unmerged branch:** create a NEW stacked branch whose base is that branch's tip, e.g. `git -C <main GV_mart> worktree add _local_only/worktrees/GV_mart_gap_x -b gap/x-topic <owner-branch>`. Never commit onto the owner branch itself. If the piece does not depend on any unmerged branch, base it on `origin/main`.
- **Migration version blocks (avoid collisions):** Agent A uses `20261110100000`+, Agent B `20261111100000`+, Agent C `20261112100000`+, Agent E `20261114100000`+. All are later than the newest pending migration (`20261108100000`).

---

## 3. What every agent does

1. **Discover.** Search `origin/main` and the branches above for each requirement in your section.
2. **Classify each requirement:** (A) complete and correct on main; (B) complete on another window's branch; (C) partial; (D) missing.
3. **Act.** A or B: build nothing; report where it lives and list any defects you found. C: build the missing delta on a stacked branch. D: build it on a new branch.
4. **Verify.** Add or extend tests. Run `tsc`, lint and the full unit suite; name any failure that is unrelated and pre-existing.
5. **SQL (only if the agent needs a migration):** follow section 5 completely.
6. **Push your own branch** (never main) and record the FULL 40-character tip.
7. **Report** in the format in section 6.

---

## 4. The five agents

### Agent A: technician review list and productivity master (items 1 and 2)

**Item 1.** "The family members who are not giving a review must be shown to the technician." Interpretation (flag it as an assumption in your report): the technician sees a list of customers/households for his own completed visits who have NOT yet left a rating or review, so he can follow up in person. Display only. No message of any kind is sent from this feature. Only his own customers; no other technician's.

**Item 2.** "The technician productivity master must be connected to the master role; the timing must be set by the master; check whether it is present." Check whether a place exists where the master sets the standard working minutes per work type (look at `pkg5/standard-minutes-and-efficiency` first) and whether technician productivity/efficiency uses those minutes. If the master cannot set them, or the productivity figures do not use them, build the missing part. Only the master may change the standard minutes (enforced in the database, not just hidden in the UI).

### Agent B: daily huddle, task section, assignment and deadlines (items 3, 4, 5, 6)

**Item 3 (daily huddle).** Each huddle entry records: problem, root cause, solution, solution given by. When anyone raises a problem or gives a solution, the master gets an in-app notification (pop-up). The huddle section is visible to all staff. Each entry shows raised-by and solved-by. Look first at `pkg2/staff-huddle-profile` and `feat/p2-staff-profile-huddle`.

**Item 4 (purpose of Task versus My Workspace).** The client says they have the same purpose. Describe each in two lines as it exists today. Decision (build it if not already done): ONE task section; My Workspace is merged into it (see `pkg3/task-logs-colours-workspace-merge`); nothing is lost.

**Item 5 (tasks).** A person can create a task, log their work with the total time worked, log the next work they will do that day, and assign a task to someone. Each person has a different colour. The master sees every person's tasks, all inside the one Task section.

**Item 6 (deadline and completion).** An assigned task whose deadline has passed turns red. Only the person it is assigned to can mark it finished. This must be enforced in the database (RLS/trigger), not only in the UI. Look first at `pkg1/task-completion-rule` and `feat/p1-task-security`. Note: P1 to P3 and pkg1 to pkg3 overlap; state clearly which branch owns which part so nothing is built twice.

### Agent C: salesperson creation and inventory identification number (items 7 and 8)

**Item 7.** Creating a new salesperson (staff user) must require: name, email, password, designation, full address, mobile number. The password is set at creation and the person must change it at first login (forced password change, a decision already made for technician create and reset; check whether it exists). The password is never logged, printed, stored in plain text, or put in a test output. Look at `feat/p2-staff-profile-huddle` and the staff-creation edge function/RPC.

**Item 8.** "An identification number must be added to the inventory, set by the user, and it must be shown in billing." Check `pkg4/item-code`. The product-level item code exists there (updates restricted to the master by a trigger, same pattern as `tier_id_master_guard`, SECURITY INVOKER, `auth.uid() is null` bypass for service role, anon must have no UPDATE on products). Verify that the item code is set by the user and that it is printed on the bill/invoice (screen and PDF/print). If it is not shown on the bill, build that. Do NOT build per-unit serial numbers: the client has not confirmed whether "identification number" means a product-level code or a per-unit serial; say in your report that this still needs the client's answer.

### Agent D: camera capture on the technician side

Front-end only, no SQL. On technician screens, wherever a photo is uploaded today, open the camera directly instead (camera only, no gallery picker).
- First list EVERY technician-side screen/component that takes a photo (expense claims, installation checklist, RO checklist, ratings and low-star screen, visit photos, anything else) before changing anything.
- Use whatever fits the existing stack: an `<input type="file" accept="image/*" capture="environment">` for the web/PWA path and, for the Capacitor Android build, the right approach for this repo (the Capacitor camera plugin with source set to camera, or the capture attribute if it works in the Android WebView). If a plugin or Android permission (CAMERA, file provider) is needed, add it correctly and list exactly which `android/` files changed.
- Keep everything that works today: image size/compression limits, the offline queue (a photo taken while offline must still queue and upload later), upload paths and storage rules, thumbnails.
- Camera permission denied or no camera: a clear message and a retry. Never a silent failure. Never block saving the rest of the form when the photo is optional.
- Customer and admin screens keep their file pickers: do not touch them.
- Tests: success, permission denied, user cancels, offline queue path.
- Note in your report: this needs a new APK to reach phones.

### Agent E: spare parts hand-over to the technician

Default assumptions (the client has not confirmed; flag every one in your report):
- Authorised staff (use the existing ops-staff helper) hand specific spare items and quantities from central inventory to a technician.
- The technician sees "My spares" on his phone, confirms receipt (acknowledgement), and sees his held quantity per item. A hand-over the technician disputes (wrong quantity) is flagged to staff.
- Spares used on a job come off the technician's held stock, NOT off central inventory a second time. Unused spares can be handed back (a return), which adds them back to central inventory.
- Staff see a ledger per technician: handed over, used, returned, balance.
- Technicians see only their own stock. Customers see nothing. No anon access. No negative balances.

Work in two stages, both inside this agent:
1. **Design first.** Read how spares and inventory work today, especially WHEN stock is deducted for a job (which table, RPC or trigger). Write the design (tables, functions and who may call each, RLS per role, how the job-usage deduction hooks into the existing flow without double counting, returns, disputes, the screens, concurrency, partial returns) to `GV_mart\_local_only\reports\spare_handover_design.md`. If the existing deduction flow makes the default design unsafe, STOP after the design and report why instead of building.
2. **Then build it:** an append-only movement ledger plus hand-over header/items, the functions, RLS, the admin hand-over form and ledger screen, the technician "My spares" and acknowledge screen, tests, rollback, and the rehearsal wrapper, all per section 5. Nothing is applied to any database.

---

## 5. SQL, security and rehearsal rules (any agent that writes SQL)

- **New functions:** explicit `revoke ... from public, anon, authenticated`, then grant only what is needed; fixed `search_path`. SECURITY INVOKER unless a definer is truly needed. NEVER test `current_user` or `session_user` inside a SECURITY DEFINER function (client-detecting triggers must be SECURITY INVOKER).
- **New tables:** `revoke all ... from public, anon, authenticated`, then narrow grants. RLS enabled. No access for anon.
- **Qualify outer columns inside RLS subqueries** (`table.org_id`, never a bare `org_id`, which would bind to the inner table and become a tautology). Cross-org references need an explicit same-org existence check in the WITH CHECK.
- **Redefining an existing function** needs a typed `diff -u` and a live-definition md5 pre-check in the wrapper (embed the original text, recreate it in a sub-block, compare `md5(pg_get_functiondef(...))` with the live function, roll back, refuse on mismatch).
- **Rollback files** refuse when data exists, and never `DELETE` from `storage.*`. The refusal check comes first, before any drop or replace.
- **Tests** use throwaway `__TEST_` organisations only (never pick rows from real data with `limit 1`). An RLS refusal that yields 0 rows is asserted with `GET DIAGNOSTICS row_count`, not by catching an exception. A refusal that raises is asserted by SQLSTATE (42501 for policy refusals), and any other error is reported as "WRONG ERROR".
- **Rehearsal wrapper:** ONE `DO` block; refuses to run when `(clock_timestamp() at time zone 'Asia/Kolkata')::time < time '18:00'`; embeds the migration text and every test text and verifies each with `encode(sha256(convert_to(text,'UTF8')),'hex')` against a pinned hash (NOT `text::bytea`, NOT pgcrypto `digest`); runs them with `EXECUTE`; no top-level begin/commit/savepoint/rollback; ends in an unconditional `RAISE EXCEPTION 'RESULTS...'`; takes a relative fingerprint (count plus content checksum) of the real organisation before and compares it at the end; never concatenates a migration and a test into one file.
- **Hashes:** `sha256sum` on the LF blob, 64 hex characters. Regenerate and re-pin after every edit.
- **Settings rows:** creating an organisation does NOT create its `settings` row; tests must insert one.

---

## 6. Final report (coordinator, one combined report)

Save it to `GV_mart\_local_only\reports\multi_agent_report_2026-10-27.md` and also print a summary in the chat. It contains:

1. A table of all ten requirements: requirement | class (A/B/C/D) | where it lives (main / branch / nowhere) | DB part live or not | what was built or changed | branch.
2. For every pushed branch: the FULL 40-character tip and the list of changed files with sha256.
3. For every SQL file: the file typed in full in the chat (or a `diff -u` against its base), its sha256, and the path of its wrapper. The wrapper typed in full (embedded bodies may be shown as `<embedded sha256 ...>`).
4. Conflicts or overlaps between the five agents' branches (same files, same tables, migration version collisions), and how you resolved or avoided them.
5. A proposed apply order for the new migrations, after the already-pending ones.
6. Open questions for the client, with your default assumption for each.
7. Anything blocked, skipped, or unclear. Say so plainly; do not paper over it.

Do not merge anything. Do not apply anything. Stop after the report and wait.
