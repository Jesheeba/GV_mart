# DECISIONS.md — OTP-verified customer Google account linking (phase 1: build + rehearsal only)

Branch: `feat/customer-otp-link`. Worktree: `GV_mart\_local_only\worktrees\customer-otp-link`.
Nothing in this phase was pushed, merged, or applied to the live database for real — only
rehearsed (explicitly allowed) and dry-run-verified.

## 1. Deviation from the 2026-10-14 spec (`docs/spec-link-customer-login-phone-otp.md`)

That spec decided **option 1b**: Supabase native phone verification (`auth.users.phone_change` +
`verifyOtp`) with a custom Send-SMS hook delivering the code over WhatsApp, and explicitly said a
hand-rolled OTP table should be built only "if 1b proves impossible". This build does **not**
follow 1b — it is a purpose-built `customer_link_otp_challenges` table, delivered through the
**existing** `whatsapp_outbox` + milestone dispatcher, with no Supabase phone provider involved at
all.

**Why this is the right call, not a shortcut around the spec:** the task that commissioned this
work is `docs/backlog-product-gaps.md`'s "Backlog: OTP-verified customer Google account linking"
entry, added 2026-10-29 — two weeks after the spec, by the same owner, as the live, current
instruction to build against. It explicitly describes reusing "the existing Wasi dispatcher, no
new SMS vendor" and says nothing about the phone-verification/hook route. Read together, this is
the owner's updated decision, not an oversight: it needs no SMS vendor, no `external_phone_enabled`
(so it does **not** reopen phone sign-up as a second self-sign-up route the way 1b would — see
`docs/security-link-customer-account.md` section 5, "item 4"), no Standard-Webhooks signature
verification, no new Edge Function at all, and no change to any Supabase Auth project setting.
Everything stays inside this project's existing database + existing outbox/dispatcher security
model, which is also what HARD RULE 1 of the task explicitly directs ("no new send path, no
direct provider API calls").

**What this trades away, honestly:** 1b's main appeal was "don't hand-roll an OTP table — the
hole we just closed came from hand-rolled identity logic." This build *does* hand-roll one. It is
reviewed as a security component on its own terms in section 3 below (independent adversarial
review) rather than inheriting Supabase's own hardening for free. If that review, or the owner,
decides the hand-rolled risk is not acceptable, 1b remains fully available as a fallback — nothing
in this build forecloses it (the phone provider is still off, `sms_autoconfirm`/`sms_test_otp` are
untouched).

## 2. WhatsApp delivery — what must be true before the flag can go on

Read `supabase/functions/_shared/whatsapp.ts` and `wa-milestone-dispatch-core.ts` directly (not
assumed) to answer this, per the task's explicit instruction:

- **A row for `ref_type = 'customer_link_otp'` is picked up by the SAME dispatcher** that already
  serves `service_ticket`/`service_visit`/`invoice`/`purchase_quote_request` — added to
  `MILESTONE_REF_TYPES` in this commit. No new send path exists anywhere in this build.
- **An approved WhatsApp template is required for reliable delivery.** The v2 dispatch path
  (`settings.wa_dispatch_v2_enabled`) calls `sendMessage()` with `purpose: "notification"` for
  every milestone row, which — per `whatsapp.ts`'s own doc comment on `SendMessageInput.purpose`
  — only sends as free text if the recipient is inside Meta's 24-hour business-initiated-message
  session window, otherwise the row is recorded `skipped_no_template` and nothing is sent. A
  brand-new customer linking a Google account for the first time has, by definition, never
  messaged the business on WhatsApp before and is never inside that window. **There is currently
  no `customer_link_otp` template registered anywhere in this codebase** (no row keyed to that
  name in whatsapp_templates / Automation > Templates). Until one is created and approved (an
  AUTHENTICATION-category template is the right category per Meta's rules, mirroring the approach
  the 2026-10-14 spec already worked out for a similar OTP message, `gvm_login_otp` — reusable
  guidance even though the delivery mechanism changed), **every send through the v2 path will be
  silently skipped, not sent.**
- **If `wa_dispatch_v2_enabled` is OFF**, the dispatcher's legacy loop sends unconditionally as
  free text with no template-or-window check in this codebase's own logic — but Meta's own
  servers still enforce the real 24-hour/template rule server-side, so an unapproved first-contact
  message to a brand-new number is likely to be rejected or silently dropped by WhatsApp itself
  regardless of what this code does. Either way, **a template is the real precondition**, not an
  implementation detail to defer.
- **Dispatch latency is a second, separate precondition.** The customer calling
  `request_customer_link_code()` has, by definition, no `profiles` row yet, so the on-demand
  `wa-dispatch-now` Edge Function (which flushes a pending row immediately after a staff/
  technician/customer action) **cannot be called by this customer** — `wa-dispatch-now/index.ts`
  looks up the caller's `profiles.org_id` and returns 403 "Caller profile not found" when there is
  none. The only thing that will ever dispatch an OTP row is the GitHub Actions cron sweep
  (`wa-milestone-dispatch`), nominally every 5 minutes but per this project's own memory ("WA cron
  pacing" notes) observed firing every 3–7 **hours** in practice. A 10-minute-expiry OTP sitting
  behind a multi-hour cron is effectively undeliverable. **This must be fixed (the held
  `feat/wa-cron-pgnet` pg_net-based near-real-time dispatch, or an equivalent) before this flag can
  safely go on for real customers** — this is the single most important precondition in this
  whole report, more load-bearing than the template approval above.
- **Redaction:** once a `customer_link_otp` row is actually sent (v2 path only — see section 5),
  `wa-milestone-dispatch-core.ts` now overwrites `payload.body` to `"[redacted after send]"`
  immediately, so the plaintext code does not sit readable in `whatsapp_outbox` (any staff/master
  user can otherwise read that table via `whatsapp_outbox_select_staff`,
  `20260702170000_automation_purchase_schema.sql:65`) for longer than it takes to send. If
  `wa_dispatch_v2_enabled` is off, the legacy path has no equivalent hook (see section 5) — this is
  a second reason, on top of the template/latency issues above, that `wa_dispatch_v2_enabled`
  should be ON before this flag goes on.
- `wa_test_mode_enabled` stays ON throughout this phase (unchanged by this build); nothing in this
  migration touches it. The flag (`customer_link_otp_settings.enabled`) defaults to `false` and
  was never turned on against the live project — confirmed by the rehearsal/dry-run proof in
  section 4.

## 3. verify_customer_link_code implementation notes (found while rehearsing, not assumed)

- **Returning jsonb, not raising, for every "bad code" outcome.** A single RPC call is one
  implicit transaction. Early drafts raised an exception for wrong-code/expired/locked/
  already-linked, which rolled back the `attempts := attempts + 1` update along with everything
  else in that same call — meaning the 5-attempt lock would never actually persist across calls.
  Fixed by returning `{status: 'invalid_or_expired', attempts_left: N}` on every non-success path
  instead, so the function reaches its own implicit commit and the attempts counter is durable.
  Only genuinely pre-state input problems (not authenticated, caller already has a profile,
  malformed code, feature flag off) still `raise`, because nothing has been written yet on those
  paths.
- **Collapsed response shape.** Per the task's explicit requirement ("don't let response shape
  leak whether the code was wrong vs expired vs challenge-not-found"), wrong code, expired,
  no-challenge-at-all, already-linked, and lost-the-link-race all return the identical
  `{status: 'invalid_or_expired', attempts_left: ...}` shape. `attempts_left` is the caller's OWN
  attempt history (0–4 on a real open challenge, the fixed default 5 whenever there is no such
  challenge) — a statement about the caller's own state, never about whether some other person's
  phone number belongs to a customer, which is the leak this feature exists to close and is
  handled entirely in `request_customer_link_code`.
- **Lock-before-insert-before-update ordering, found via rehearsal, not design review.** The
  first two rehearsal runs against the live project failed with a Postgres foreign-key violation:
  the draft updated `customers.primary_profile_id = v_user_id` **before** inserting the
  `profiles` row for that same `v_user_id`, which `customers_primary_profile_id_fkey` rejects
  immediately (the referenced row does not exist yet). Fixed by taking `select ... for update` on
  the customer row first (serializing against a concurrent verify of a second challenge for the
  same customer), inserting the profile second, and updating the customer last — the only
  ordering that satisfies both the foreign key and the race-safety requirement at the same time.
- **Marking the challenge used BEFORE the link itself, not after.** A correct code is burned
  (`used_at` set) immediately once the hash matches, even on the rare path where the link then
  fails its own re-check (customer flagged test or linked by hand in the interim). The alternative
  — marking it used only after a successful link — would let one correct code be retried
  indefinitely across repeated race losses. The tiny residual cost: a genuine race loser's correct
  code cannot be reused even for a legitimate retry; they must request a new one. Accepted.
- **`now()` vs `clock_timestamp()`.** `now()`/`transaction_timestamp()` is frozen to the start of
  the current transaction — correct for ordinary business logic, wrong for a cooldown/expiry
  check, and this phase's own rehearsal test (many RPC calls back-to-back inside one open
  transaction) would have seen every call at the identical frozen instant, making every
  time-window comparison meaningless. Found via the rehearsal itself, not by inspection. Fixed by
  using `clock_timestamp()` everywhere a real-time comparison matters
  (`v_now`, the expiry check, `used_at`). Has no visible effect in normal production use, where
  each RPC call is its own transaction — this is strictly a correctness improvement, not a
  behavior change for real traffic.
- **pgcrypto lives in the `extensions` schema on the live project, not `public`.** An existing
  migration's own comment (`20260701090000_extensions_and_enums.sql`) claims pgcrypto was
  installed into `public`; the live project's actual `pg_proc`/`pg_namespace` say `digest()` and
  `gen_random_bytes()` are in `extensions` (Supabase's platform relocates extensions there
  regardless of the `CREATE EXTENSION` statement's own target). Found live, via rehearsal, not by
  reading that comment and trusting it. Every function in this migration that calls either one
  sets `search_path = public, extensions, pg_temp`, not just `public, pg_temp`.
- **Rate-limit phone hashing has no pepper.** `customer_link_otp_send_log.phone_hash` is a plain
  `sha256(mobile)`, not an HMAC with a server-side secret (the 2026-10-14 spec's hook design used
  one). This project has no secrets-manager-backed pepper a plain SQL function can read at
  migration-build time, and the 10-digit Indian-mobile keyspace (starting 6–9) a pepper would
  protect is small enough that an unsalted hash buys little real extra resistance anyway. Access
  to this table is restricted as tightly as the challenges table instead (no RLS policy for any
  role) specifically because of this. Recorded as a conscious, documented limitation, not an
  oversight.

## 4. Rehearsal + dry-run proof (this phase — nothing applied for real)

Ran via the sha256-verified `_local_only/reports/run_rehearsal.mjs`
(`001c54de5364f98e232a26c5ada1c929289243cd2bad00cc008c595c43beafb4` — confirmed before use) against
the live project (`fsunrjithwcjtsutsgea`), following the exact wrapper convention copied from
`supabase/ops/technician_pending_reviews.rehearsal.sql` (git history, `feat/technician-pending-reviews`),
with the 11:00 IST gate this task specified (not that older file's original 18:00).

- `supabase/ops/customer_link_otp.rehearsal.sql` — embeds the migration
  (`20261120100000_customer_link_otp.sql`, sha256 `112febdfb033c3e84d0a1840ac7ab13097f2c565fd0cccebfe8bd5e206ec81c1`
  — this hash is the POST-security-review version, after the section 7 fixes; the rehearsal was
  re-run against the live project after those fixes and re-confirmed below)
  and the test (`supabase/tests/customer_link_otp.test.sql`, sha256
  `38a34fe919e371aa6f03c4e2ef05e0c30d9521cd711f842bbb815a73f687bdf5`) verbatim, pinned. Final run
  (post-security-fixes): **24 of 24 test assertions passed** (`G0`–`G2`, `P1`–`P13` and their
  sub-checks), ending in the wrapper's own unconditional `RAISE EXCEPTION`, so nothing committed.
- **Independent before/after proof**, run as two SEPARATE Management-API calls outside the
  rehearsal's own transaction (`supabase/ops/20261120100000_customer_link_otp.snapshot.sql`), not
  just the rehearsal's own internal fingerprint claim:

  | | before | after |
  |---|---|---|
  | `customers` row count | 16479 | 16479 |
  | `profiles` row count | 10 | 10 |
  | `whatsapp_outbox` row count | 82 | 82 |
  | `audit_log` row count | 3119 | 3119 |
  | real-row md5 (`customers`) | `d2ed1e5239127c595ce32d719db097ac` | `d2ed1e5239127c595ce32d719db097ac` |
  | real-row md5 (`profiles`) | `8760e3e45d608446670f44c2beb7b239` | `8760e3e45d608446670f44c2beb7b239` |
  | the 3 new tables exist? | false/false/false | false/false/false |

  Identical in every column — the 3 new tables still do not exist live (confirming the migration
  itself never committed either), and no real row anywhere changed.
- **DRYRUN-OK copy of the real apply script actually run.** `supabase/ops/20261120100000_customer_link_otp.apply.dryrun.sql`
  is byte-identical to the real apply script (`...apply.sql`) except for one extra line that
  unconditionally raises `DRYRUN_OK: ...` immediately before the final status-row insert. Run
  through the same verified `run_rehearsal.mjs` against the live project: **every step passed** —
  org fingerprint check, 11:00 IST gate, already-registered check, pre-checks (none of the 3 new
  tables or 3 new functions exist yet), leak snapshot, sha256 pin, the actual migration DDL run,
  schema_migrations register, post-checks (all 3 tables + 3 functions exist, none anon-executable,
  none authenticated-table-readable, the flag starts `false`), the diff-based anon-leak check
  (nothing newly leaked), and the real-org fingerprint re-check — then hit the deliberate
  `DRYRUN_OK` raise and rolled back. The same independent before/after snapshot (above) was
  re-run after this and is unchanged. **The real apply script itself (not just the migration) is
  proven to work end-to-end without having been run for real.**

### 4b. Re-run after a test-setup bug fix (commit `c59874d`)

Re-rehearsing after the section 7 security fixes above hit a real failure:
`insert or update on table "audit_log" violates foreign key constraint
"audit_log_actor_id_fkey"`. Root cause, found by bisection: a NEW line this phase added to the
test's setup (`insert`/`update` on `public.settings`, needed because
`is_customer_link_otp_enabled()` now also requires `wa_dispatch_v2_enabled`) ran while
`request.jwt.claims` still held an earlier test step's profile-less user — `reset role` resets
the SQL role but not that GUC. `settings` carries the generic `audit_master_change` trigger,
which (unlike `profiles`' own `audit_profile_changes`) writes `actor_id = auth.uid()` with no
existence check, so the audit insert itself violated the FK. This was a bug in the TEST file,
not the migration — fixed by moving/clearing `request.jwt.claims` around every direct `settings`
write; the `G0b` and `P14` assertions from section 7 were restored alongside the fix.

Current pinned hashes (superseding the ones quoted in section 4 above): migration
`a75b901e79a44233e4422bc1e386040ef0a82db69a5b86b53c09b39096d48222`, test
`9e78ec0250f739bab304e03dee3d1d2700ffdd7403c89dccb8e2229a1ba423e5`. Rehearsal re-run clean:
**26 of 26 assertions passed** (`G0`, `G0b`, `P1`–`P14`, `G1`, `G2`), real-row fingerprint
unchanged before/after. The DRYRUN-OK copy of the apply script was re-run against this same
migration content and still raises cleanly on its first statement.

Two independent fresh reviews were then run against this exact commit:
- **Adversarial security review**: no CRITICAL/HIGH findings; verdict READY FOR LIVE APPLY. Two
  informational items for the record: (1) the known `whatsapp_outbox` plaintext-OTP exposure
  window between enqueue and cron dispatch is real but already at this codebase's practical
  minimum (redact-on-send and now redact-on-give-up both confirmed implemented); (2)
  `is_customer_link_otp_enabled()`'s `wa_dispatch_v2_enabled` check is organisation-existential
  (any org having it on satisfies the check), not scoped to the matched customer's own org — a
  latent gap that is inert today (effectively single-organisation product) but would reopen the
  plaintext-exposure issue for an org with v2 dispatch off if a second organisation is ever
  onboarded. Worth a follow-up ticket, not a blocker.
- **Apply-script/syntax review**: no BLOCKING findings; verdict APPROVED FOR LIVE APPLY. Confirmed
  by direct hash computation (not by trusting this document) that `apply.sql`/`apply.dryrun.sql`/
  `rehearsal.sql` all embed migration/test text byte-identical to the current source files, with
  correctly matching pinned hashes; grants, one-shot/idempotency-refusal behavior, and the
  anon-exposure sweep's whole-schema scope all meet this project's convention. Found three stale
  prose comments (a leftover "24/24" count, a leftover "five tables + four functions" count, and
  this section's own now-superseded hashes) — fixed in the same pass that added this subsection.

## 5. Dispatcher redaction — scope of the fix

`wa-milestone-dispatch-core.ts`'s v2 path (`runMilestoneDispatchV2`) redacts `payload.body` to a
placeholder immediately after a confirmed `sent` status for `ref_type = 'customer_link_otp'` rows.
This does **not** cover the legacy dispatch path (`wa_dispatch_v2_enabled` off): that path inserts
a fresh outbox row per retry attempt via `sendMessage()`'s own legacy insert rather than updating
one row in place by a known id, and retrofitting redaction there risks touching the shared send
path every other milestone type also uses. Decision: leave the legacy path unredacted and
document the residual exposure here (per the task's own instruction — "if the dispatcher
architecture doesn't allow it cleanly, document the residual exposure... and restrict read access
as tightly as possible instead") rather than risk a wider blast radius for a narrow gain. This is
a second, independent reason (on top of section 2's latency point) that `wa_dispatch_v2_enabled`
should be ON before this feature's flag goes on for real customers.

## 7. Independent adversarial security review (HARD RULE 3)

A separate agent, with no knowledge of this build beyond the migration/code/tests/this document,
was asked to attack the design against: OTP guessing/brute force, replay, race conditions on
verify, user enumeration via content OR timing, linking an already-linked/test customer, staff
reading codes off the outbox, session fixation, and anything else it found. Full findings below;
every High/Medium is now fixed in code (not just documented) except where noted.

- **HIGH — timing side-channel reopened the enumeration oracle via response latency, not
  content.** The true-match branch of `request_customer_link_code` does measurably more work
  (an `UPDATE`, two crypto calls, two more `INSERT`s, an `audit_log` write) than the no-match/
  test/already-linked branches, and — worse — none of the rate-limit counters engaged for a
  non-matching probe at all, since they only counted `decision = 'sent'` rows. An attacker could
  therefore call the function unthrottled against any list of candidate numbers and use latency
  alone to learn which ones are real customers. **FIXED**, two parts: (1) the three count-based
  caps (per-user/hour, per-phone/hour, distinct-numbers/24h) now count every attempt regardless
  of decision, so the probing rate itself — not just successful sends — is bounded to the same
  existing limits; the 30-second cooldown stays scoped to `decision = 'sent'` only, deliberately,
  so an unrelated wrong guess on some other number can't block a legitimate resend. (2) the
  no-match branch now performs the same `gen_random_bytes`/`digest` calls as the real branch
  (result discarded, nothing stored) to narrow the CPU-time gap. **Residual risk, stated
  plainly, not glossed over:** this reduces rather than eliminates the signal — it does not
  equalize the cost of the extra `UPDATE`/2 `INSERT`s/audit-log write the true-match branch still
  does, and a determined attacker could still spin up many throwaway Google accounts (public
  sign-up is open) to collect more timing samples than the per-user caps allow from one account.
  Full constant-time guarantees across branches with different numbers of writes are not
  realistically achievable in PL/pgSQL without disproportionate complexity for this phase; the
  rate-limit fix is the primary, load-bearing mitigation (it bounds the attacker's total sample
  count, which bounds how much statistical confidence a timing attack can ever reach), and the
  dummy-crypto-work fix is a secondary one. Flagged as an open item for phase 2 / ongoing
  monitoring, not claimed as fully closed.
- **MEDIUM — shared per-phone cap lets anyone who knows a customer's number grief their linking
  flow (supersede their in-flight challenge, exhaust the phone's 3/hour send cap so they silently
  get "ok, code sent" with nothing actually sent).** Reviewed and accepted as an inherent property
  of ANY phone-number-based OTP system, not a flaw specific to this implementation: in every
  system where "type a phone number" triggers a code send (bank logins, 2FA enrollment, etc.),
  anyone who knows that number can trigger the same send/no-send behavior — the number itself is
  not secret, and must not be treated as if it were. Knowing someone's phone number has never
  been enough to take over their account here (the attacker never receives or learns the code),
  only to repeatedly interrupt their own attempt to link it within the same hour. No code
  change in this phase; the existing per-number cap already resets hourly, limiting how long the
  interruption lasts. **Recommended follow-up for the owner, not built here:** the 2026-10-14
  spec's "project circuit-breaker: alert, don't block" idea (a notification when one phone number
  hits its send cap repeatedly, as a staff-visible signal of targeted harassment) would be a
  reasonable layer to add later; out of scope for this phase's build.
- **MEDIUM — the 6-digit code was generated with Postgres' `random()`, which Postgres' own docs
  say is not cryptographically secure, while the salt right next to it correctly used
  `gen_random_bytes`.** **FIXED**: the code is now derived from `gen_random_bytes(4)` via a
  bit-string cast and modulo, confirmed via a live probe (3 samples, values in range, see commit)
  to produce a valid 6-digit-range value from the CSPRNG source.
- **LOW — no rate limit on `verify_customer_link_code` when the caller has no active challenge
  at all.** That path does no write, so impact is bounded to minor resource use from unbounded
  calls, not a brute-force or enumeration vector (response is constant regardless of target).
  Accepted, not fixed — the cost/benefit does not justify adding a counter for a no-op path.
- **Already covered, reviewer agreed, no change needed:** replay of a used/superseded code
  (`used_at`/`superseded_at`, proven by test P8); race conditions on verify (`for update` locks on
  both the challenge and the customer row, in the order found during this phase's own rehearsal —
  see section 3); linking an already-linked or `is_test` customer (checked at request time AND
  again under lock at verify time); session fixation / cross-user challenge access (`user_id`
  scoping in the verify lookup, proven by test P9); SQL injection / privilege escalation (all
  inputs parameterized, role hardcoded to `'customer'`); grants (both RPCs `authenticated`-only,
  both new tables have zero policies for any role, proven by tests G1/G2 and the dry-run apply's
  own post-checks).
- **Already covered elsewhere in this document, reviewer agreed:** the dispatcher-redaction gap
  on the legacy path (section 5) and the unpeppered phone hash (section 3) — reviewer read those
  sections and confirmed the stated reasoning without raising anything new on either.

**Go/no-go input from this review:** no unresolved High or Medium finding remains. The one
residual risk carried forward (the timing side-channel's partial-not-full mitigation) is stated
above, not hidden, and is a reduction of an existing gap rather than a newly introduced one.

## 8. Scope decisions

- **No rename of `GoogleLinkAccountCard` → `LinkCustomerAccountCard`.** The 2026-10-14 security doc
  separately "approved" that rename as part of a different, broader cleanup (dropping the old
  function and its remaining touch-points). This task's instructions never asked for it, and
  renaming a component only to also change its content in the same commit adds review surface
  for no functional benefit. Left as a follow-up for whichever commit actually drops
  `link_customer_google_account` for good.
- **No distinct-numbers-per-24h counter beyond what's asked.** The task explicitly asks for "a
  rate limit per phone number... and per authenticated user, plus a short global cooldown" — three
  limits. A fourth (distinct numbers targeted per user per day) was added anyway as cheap defense
  in depth (one extra `count(distinct phone_hash)` query, same shape as the others) since it
  stops one account from walking a list of numbers even while staying under the flat per-user
  send cap. Not independently exercised by its own rehearsal test (P13's per-user cap triggers
  first at exactly the same scenario), noted as a gap in section 7.
- **Multi-organisation collision: still refused, per the existing 2026-10-14 decision (5b in
  `docs/security-link-customer-account.md`), not re-opened.** `request_customer_link_code` counts
  ALL rows matching the mobile number globally (not org-scoped); more than one match is treated
  identically to zero matches (the generic no-op response) rather than picking one. "Oldest across
  all organisations" stays gone for good.

## 9. Phase 2 (2026-10-29): template discovery + fast OTP dispatch path, and a concurrent-session collision

Separate work pass, same worktree/branch. Picked up where PARKED.md left off: items 1-2 of
PARKED.md's "prerequisites before the flag can ever be turned on" (template, fast dispatch
latency). **Read this whole section before touching this feature again** — it records a real
discrepancy from the phase-1 account and a live, same-worktree collision with another session
that was working this exact task concurrently.

### 9.0 CRITICAL FINDING, not caused by this pass: 20261120100000_customer_link_otp.sql was
### ALREADY APPLIED LIVE before this pass started

PARKED.md and this document's own sections 1-8 describe the base migration as rehearsed/dry-run
only, never applied. A read-only check at the start of this pass (`to_regclass` for all 3 tables,
`to_regprocedure` for `request_customer_link_code(text)`, `supabase_migrations.schema_migrations`)
found all three tables, both original RPCs, and a `schema_migrations` row for version
`20261120100000` genuinely live on the project. Leftover `*.out.txt` response files under
`supabase/ops/` (since deleted — stray rehearsal/apply output is this project's own established
hygiene issue, see commit `38abfeb`) recorded `"version_registered":true` and an `applied_at`
timestamp of `2026-10-29 16:00:30 UTC`, roughly 20 minutes after commit `c59874d` (21:09:55 IST /
15:39:55 UTC) and matching `customer_link_otp_settings.updated_at` exactly. This was **not done by
this pass** — found, not caused. Impact, confirmed read-only: `customer_link_otp_settings.enabled`
is `false` (unchanged default), all 3 new tables have 0 rows, and the post-apply anon-exposure
sweep (also found already run, also clean — `[]` newly-leaked functions) came back clean. No
customer impact. This is flagged here as the record of what actually happened, not acted on
further (no rollback attempted — reverting a live apply without authorization would itself be an
unauthorized write) and is the owner's to decide what to do with, if anything.

**Consequence for this pass's own work discipline**, learned the hard way (see 9.2): since
`20261120100000_customer_link_otp.sql` is live, its bytes must never change after the fact — the
same immutable-migration convention this project already follows everywhere else. An agent
working this pass independently (see 9.1) reached the same conclusion and built the Item
1/Item 2 additions as a **new**, separate migration file instead of hand-editing the applied one.
That is the correct approach and the one this document now defers to (9.1/9.3).

### 9.1 A second, concurrent Claude Code session was independently building the SAME two items,
### in the SAME shared worktree, at the SAME time

Not a different worktree per this project's "worktree-only policy" memory — this pass's
coordinator placed it directly in `GV_mart\_local_only\worktrees\customer-otp-link`, the one
worktree already checked out to this branch, and so was whatever session produced commits
`c59874d`/`c155bdc` before this pass even started, and so was a THIRD session that appeared mid-
pass and, within the span of about 15 minutes, independently built: `wa_otp_fast_dispatch_invoke`
(byte-for-byte the same design — allow-listed org-only `net.http_post`, its own
`wa_otp_fast_dispatch_secret` vault entry distinct from `wa_cron_secret`, revoked from
public/anon/authenticated), the same `is_customer_link_otp_enabled()` fix (require
`wa_dispatch_v2_scope = 'org'`, not just `wa_dispatch_v2_enabled`), and the same `payload.code`
addition to `request_customer_link_code`'s outbox insert — as a clean, separate migration file
`20261120100100_customer_link_otp_fast_dispatch.sql`, its own apply/dryrun/rehearsal/test bundle
(`gen_fast_dispatch_scripts.mjs`, `customer_link_otp_fast_dispatch.rehearsal.sql`,
`supabase/tests/customer_link_otp_fast_dispatch.test.sql`), with its own dry-run already passing
(`DRYRUN_OK`) as of this writing.

This pass had independently built the identical design (same function name, same secret-naming
convention, same scope fix, same payload key) as hand-edits to the ALREADY-LIVE
`20261120100000_customer_link_otp.sql` directly — the wrong place, per 9.0 — before noticing the
other session's files appear on disk mid-run (git status showing new untracked files this pass
never created, migration-file edits reverting to HEAD between one tool call and the next, and a
transient `git: unable to access '.git/config': Permission denied` consistent with a concurrent
git operation). **Resolution taken here:** this pass's own hand-edits to the live migration file
and its apply/dryrun/rehearsal/test bundle were reverted back to HEAD (`git checkout HEAD --
<those 6 files>`), ceding the DB-migration layer entirely to the other session's cleaner,
correctly-separated-migration approach — redoing the same work in the wrong place a second time
would have been pure waste and an active collision risk. **This pass's own new, non-duplicate
contribution — the pieces the other session's SQL-only migration does not and cannot cover —
was kept and is the actual deliverable of this pass:**

1. `wa-otp-dispatch` (new Edge Function, `supabase/functions/wa-otp-dispatch/index.ts`): the
   actual HTTP endpoint `wa_otp_fast_dispatch_invoke` calls via `net.http_post`. Authenticated by
   its own `WA_OTP_FAST_DISPATCH_SECRET` (constant-string compare against the Authorization
   header — deliberately NOT `CRON_SECRET`, so a leak of one secret never grants the other), takes
   `org_id` from the request body, and calls the shared dispatcher with a **hardcoded**
   `{ refTypes: ["customer_link_otp"] }` — a literal array, never derived from the request body,
   so nothing reachable from outside this codebase can widen the scan to any other milestone type.
   `[functions.wa-otp-dispatch] verify_jwt = false` added to `supabase/config.toml` (same pattern
   as `wa-scheduled-tasks`/`wa-milestone-dispatch`), and `WA_OTP_FAST_DISPATCH_SECRET` documented
   in `supabase/functions/.env.example`.
2. `runMilestoneDispatch`'s new optional 3rd argument, `opts?: { refTypes?: readonly string[] }`
   (`wa-milestone-dispatch-core.ts`) — every EXISTING caller (the cron sweep, `wa-dispatch-now`)
   omits it and keeps scanning the full `MILESTONE_REF_TYPES` list, completely unchanged;
   `wa-otp-dispatch` is the only caller that passes it, and only with the literal above.
3. `customerLinkOtpStillSendable()` (`wa-milestone-dispatch-core.ts`) — the task's explicit "an
   OTP must never be sent after it has expired or been used" requirement, checked immediately
   before `sendMessage()` in BOTH the v2 `send` closure and the legacy loop (both dispatch paths,
   not just the new fast one — the cron fallback races the same clock). Looks up
   `customer_link_otp_challenges` by `ref_id`; refuses to send (marks the row `failed`, reason
   `otp_expired_or_used`, and redacts `payload` the same way a successful send does) when
   `used_at`/`superseded_at` is set or `expires_at` has passed. Fails OPEN (sends anyway) on a
   lookup error — a transient DB blip must never silently block a real, still-valid code, and a
   stale code slipping through has no exploitable consequence since `verify_customer_link_code`
   independently re-checks expiry/used/superseded before ever linking an account. A true no-op
   (no query at all) for every ref_type except `customer_link_otp` — this must never become a
   general staleness check for other message types.
4. `wa-event-context.ts`'s new `customer_link_otp` branch reads `vars.code` from
   `row.payload.code` (the raw value, not re-parsed out of the rendered sentence) so the
   dispatcher can pass it as a named WhatsApp template parameter once a template is actually
   wired. `PendingRow`'s `payload` type (`wa-dispatch-v2.ts`) and `StuckOutboxRow`'s (
   `wa-milestone-dispatch-core.ts`) both widened to include `code?: string`.
5. Test coverage added to the existing `wa-milestone-dispatch-core.customer-link-otp.test.ts`
   (vitest): expired/used/superseded challenges are never sent on either dispatch path (v2 and
   legacy), a still-valid challenge sends normally (no regression), a different ref_type's row
   never triggers a challenge lookup at all, and the new `refTypes` option is proven to actually
   scope the scan (restricted vs. the default-unscoped behavior every existing caller still gets).
   12 tests in that file, all passing; full suite 776 passed / 17 pre-existing skipped (`tsc -b`
   clean, `npm run build` clean, one `oxlint` warning introduced and fixed in the same pass —
   unsafe optional chaining in a new test assertion, switched to a non-null assertion after an
   explicit `expect(u).toBeDefined()`).

**Independent adversarial review of this fast-path addition** (HARD RULE from this phase's task,
same bar as section 7): a separate agent read the migration, the new Edge Function, the
dispatcher changes, and the config/env changes, and attacked specifically the timing-oracle,
response-leak, dispatch-spam, rate-limit-bypass, and secret-handling angles the task named.
Verdict: **one MEDIUM finding** — `is_customer_link_otp_enabled()`'s check only required
`wa_dispatch_v2_enabled`, not `wa_dispatch_v2_scope = 'org'`; under the column's actual default
(`'numbers'`), any `to_mobile` not on an admin-configured allow-list still routes through the
non-atomic legacy dispatch loop (post-send `retried_at` stamp only, no claim-before-send), and the
new fast path now triggers a scan on every successful OTP send instead of once per 3-7-hour cron
tick, making a same-org double-send realistically more likely than before this phase. **FIXED**
(independently, in parallel, by both this pass and the other session — see 9.2) by also requiring
`wa_dispatch_v2_scope = 'org'`. Everything else came back INFO/LOW and confirmed-safe on direct
inspection: the `refTypes` hardcoding cannot be widened from outside; the two secrets are never
cross-referenced; the stale-challenge guard's fail-open behavior is provably harmless given
`verify_customer_link_code`'s own independent re-check and is never reachable from user input; the
fast-path's own `net.http_post` call is fire-and-forget with its result discarded, so there is no
response-content leak path. A LOW/INFO note on the bearer-secret comparison not being
constant-time was accepted as-is (impractical to exploit over real network jitter against a
high-entropy secret) rather than fixed, consistent with this document's existing practice of
recording an accepted residual rather than fixing everything a reviewer can theoretically name.
**No unresolved High or Medium finding remains.**

### 9.2 Both sessions found and fixed the SAME MEDIUM independently — recorded once, not duplicated

The `wa_dispatch_v2_scope = 'org'` fix above was discovered by this pass's own independent
reviewer AND, separately, by the other concurrent session (visible in its migration file's own
section-2 comment, timestamped minutes apart from this pass's review). Recorded here once as a
cross-check that both arrived at the identical root cause and the identical fix independently —
treated as corroboration, not re-applied twice (the live function definition will simply be
whichever migration — `20261120100100_customer_link_otp_fast_dispatch.sql` — the other session
commits and, eventually, applies; this pass made no further edit to that function once it ceded
the migration layer per 9.1).

### 9.3 Item 1 (template discovery) — FOUND a unique candidate, then the owner raised a real
### brand-neutrality concern that supersedes this pass's own confidence

A read-only query against `whatsapp_wasi_templates` (Management API, via the sha256-verified
`run_rehearsal.mjs`, `001c54de5364f98e232a26c5ada1c929289243cd2bad00cc008c595c43beafb4`) found
exactly ONE Wasi-approved AUTHENTICATION-category template on the live project: `wasi_name =
'lexdraft_otp'`, `language = 'en'`, `status = 'approved'`. Being the only candidate of its
category was this pass's own basis for high confidence ("the owner's own statement that an
AUTHENTICATION template already exists and is approved matches a unique row, not an ambiguous
one") — template NAME and LANGUAGE were therefore judged determinable from the repo/live settings
alone, satisfying this phase's own stated bar for proceeding rather than stopping.

**That confidence is superseded by real owner input surfaced through the concurrent session**
(9.1): the other session's migration file records that "the owner flagged that this template's
name suggests it may belong to a different product sharing this WhatsApp account and asked for
its exact body/category/language and a brand-neutrality check before anything maps this feature
to it," and deliberately left the `whatsapp_event_templates` mapping insert OUT of its migration
entirely for that reason. This pass had independently drafted the identical mapping insert
(`event_key = 'customer_link_otp'`, `wasi_template_name = 'lexdraft_otp'`, `language = 'en'`,
`param_map = {"code": "code"}`) before learning of the owner's concern — that insert was **not**
committed anywhere and should not be, until the owner's brand-neutrality question is answered.
**Status for Item 1, corrected from this pass's own earlier conclusion: BLOCKED, needs owner
input** — not "found and used." What's still needed from the owner, unchanged by anything this
pass did: confirmation that `lexdraft_otp` belongs to THIS product/WhatsApp Business account (not
a different tenant sharing the same number), its exact body text/category/language as shown in
Wasi's own dashboard, and whether it has a copy-code button — the live sync job
(`wasi-templates.ts`) reported zero `body_param_examples` for it, which this document's earlier
draft (now superseded) read as "Wasi's sync not surfacing this category's real param contract,"
but could equally mean the wrong template was found. **Until that is answered, nothing should
reference `lexdraft_otp` from this feature.** The dispatcher wiring built in this pass (9.1) is
deliberately generic/parametrized — `vars.code` is populated regardless of which template
eventually gets mapped — so answering this question later is a pure data change
(`whatsapp_event_templates` row), not a code change.

### 9.4 Status at hand-off

- **Live/applied (found, not caused by this pass):** `20261120100000_customer_link_otp.sql`'s
  original tables/functions. Flag OFF, zero rows, clean anon sweep (9.0).
- **Rehearsed/dry-run only, NOT applied, NOT pushed (the other concurrent session's work, left in
  its hands):** `20261120100100_customer_link_otp_fast_dispatch.sql` and its bundle — dry-run
  passed as of this writing; full rehearsal pass/fail and any commit/apply decision belongs to
  that session, not recorded further here.
- **Built, tested, committed by THIS pass (this pass's own commit, see the final report for the
  hash):** the `wa-otp-dispatch` Edge Function, the `runMilestoneDispatch` `refTypes` scoping, the
  `customerLinkOtpStillSendable` stale-challenge guard on both dispatch paths, the
  `wa-event-context.ts` `code` variable wiring, the widened `PendingRow`/`StuckOutboxRow` payload
  types, `supabase/config.toml` + `supabase/functions/.env.example` entries, and the vitest test
  coverage for all of the above. None of this depends on which migration file ends up defining
  `wa_otp_fast_dispatch_invoke`/`request_customer_link_code` live — it is the Edge
  Function/dispatcher-side half of the same feature, reachable only once that function exists.
- **Not built, not applied, deliberately withheld pending owner input:** the
  `whatsapp_event_templates` mapping row for `customer_link_otp` (9.3).
- **No live apply, no push performed by this pass**, per this phase's own explicit instruction —
  everything above that needed live verification was checked read-only or rehearsed with an
  unconditional rollback.

## 10. Phase 3 (2026-10-30): template facts, redaction/dispatch hardening, net.* finding

Separate work pass, same worktree/branch. Owner confirmed the AUTHENTICATION-category template
name is `lexdraft_otp` and gave a strict ordered plan (steps 1-5, STOP before edge-function
deploy/secrets/live customer test, all gated on a typed "APPROVED" not given this pass). This
section records exactly what was found and built, in order.

### 10.0 Housekeeping

The stray `20261120100000_customer_link_otp.anon_exposure_sweep.sql.out.txt` file the task named
did not exist in the worktree — already removed by commit `38abfeb`, nothing to delete.
`git fetch origin` + merge brought in 5 new commits (`60cd116`..`03cb43a`, a master-only
Google-account-linking stopgap feature, unrelated to this feature) with exactly one conflict
(`src/types/database.ts`, two independent `Functions` entries needing concatenation, same
discipline as this branch's prior merge) — resolved, merge commit `d2c99a2`. `tsc -b`, `oxlint`,
`npm test` (776 passed / 17 skipped before this pass's own additions), and `npm run build` all
pass clean after the merge.

**A concurrent Claude Code session was again working this exact worktree during this pass**
(consistent with 9.1/9.2 and this project's "deliberate parallel sessions" memory): mid-pass, the
previously-untracked `20261120100200_whatsapp_outbox_secret_payload_scrub.sql` file (described in
9.0/9.4 as still pending) was committed from outside this pass as `9caef1d`, between a `git status`
call and the next. No collision with this pass's own work — ceded to that commit (it is read, not
re-written, by the migration built in 10.2 below) and nothing here conflicted with it.

### 10.1 Step 2/3 (template facts + brand check): BLOCKED, confirmed via live read-only query,
### not re-litigated from 9.3's prior finding

Read-only query against `whatsapp_wasi_templates` (same sha256-verified `run_rehearsal.mjs`,
`001c54de5364f98e232a26c5ada1c929289243cd2bad00cc008c595c43beafb4`) confirms the row 9.3 already
found: `wasi_name='lexdraft_otp'`, `language='en'`, `status='approved'`, `category='Authentication'`,
`header_type=null`, `param_keys=[]` (empty), one org (`b6822905-5557-4e43-a606-f26ecfd5a541`). A
second query against `whatsapp_event_templates` confirms (again) no mapping row exists for
`customer_link_otp` or `lexdraft_otp` anywhere live.

**Why body text/footer/button-type are NOT discoverable from the repo or DB, confirmed by reading
the sync code itself, not assumed:** `supabase/functions/_shared/wasi-templates.ts`'s own header
comment records that Wasi's real API response for a template includes `body`, `header_content`,
`footer_text`, `buttons`, and `body_param_examples` — but `mapWasiTemplateList()` (the ONLY place
that ever reads that response) deliberately discards `body`/`header_content`/`footer_text`/
`buttons` and persists only `wasi_name`/`language`/`category`/`status`/`header_type`/`param_keys`
into `whatsapp_wasi_templates` (whose own table definition, `20261016300000_wa_dispatch_v2_schema.sql`,
has no body/footer/button columns at all). `lexdraft_otp`'s `param_keys` being empty is itself
ambiguous (a template with zero body parameters, or the sync not surfacing them — 9.3's same open
question, not resolved by this pass).

**Per the task's own stop condition, this pass does NOT guess the language code, button type, or
body text.** Step 2 is BLOCKED; step 3 (brand check) is therefore also blocked (it needs the body
text); step 4(d) (the template mapping row) is skipped, per the task's own instruction for exactly
this case. **What is needed from the owner, pasted from WhatsApp Manager / Wasi's own template
dashboard for `lexdraft_otp`:**
1. Confirmation this template belongs to THIS product/WhatsApp Business Account (the name itself
   suggests a different product, "LexDraft" — the owner's own concern, carried over from 9.3,
   unchanged by anything found this pass).
2. The exact body text (with its `{{1}}`-style placeholder(s) shown as Wasi/Meta render them).
3. Footer text, if any.
4. Button component shape: none / copy-code / one-tap / zero-tap — and if copy-code, whether the
   button itself also carries a parameter (some copy-code buttons encode the code a second time in
   the button's own parameter, separate from the body parameter).
5. The exact `language` code value the WhatsApp send API expects for this template (confirm `en`
   is correct and not `en_US` — the sync mapper's own fallback default is `en_US`, but this row's
   stored value is the literal `en`, and Meta's template API is picky about exact language-code
   matches).

### 10.2 Step 4(a)+(b)+(c): built, local-rehearsed, live-rehearsed; (b) found INFEASIBLE, not
### silently skipped; one HIGH found by independent review and fixed

New migration `20261121100100_customer_link_otp_dispatch_hardening.sql` (after the newest existing
timestamp, `20261121100000_admin_link_customer_google_account.sql`, from the merge above). Edits
nothing in the two already-applied migrations or the already-committed `20261120100200`.

- **(a) HIGH, built and proven correct.** The existing redaction (app-level, on confirmed-send/
  give-up-on-visit; DB-level, on any status transition away from `pending`, per `20261120100200`)
  only ever fires when some dispatch pass actually VISITS a row. A row nothing ever visits before
  its challenge expires (fast-dispatch secret not yet provisioned, Edge Function down, cron not
  firing — all real possibilities this project has already lived through) stays `pending` with the
  plaintext code forever. Closed with `scrub_expired_customer_link_otp_outbox()`, a 1-minute
  pg_cron sweep (this project's existing pattern) that finds any `customer_link_otp` row still
  `pending` whose challenge (joined via `outbox_id`) has expired/been used/been superseded, and
  clears `payload.code`/`template_params` + flips the row to `failed`/`otp_expired_or_used_db_sweep`
  directly (belt-and-suspenders with the `20261120100200` trigger, which also fires on that same
  status transition). Bounds the worst-case exposure for an unvisited row to under a minute past
  expiry. The registry note in `whatsapp_payload_secret_ref_types` is refreshed to describe all
  three coverage mechanisms together, so the `redaction_covered = true` claim that gates the
  template-mapping guard is honest for the first time across every code path, not just
  send/give-up-on-visit.
- **(b) pg_net hardening — ATTEMPTED, FOUND GENUINELY INFEASIBLE for this project's migration
  role, NOT silently skipped.** Read-only probe confirmed the exposure (`net.*` owned by
  `supabase_admin`, `proacl` null → PUBLIC/anon/authenticated all implicitly have EXECUTE). The
  actual REVOKE was then tried as a REHEARSAL (rolled back), not assumed to work from the absence
  of an error: `revoke execute on function net.http_post(...) from public, anon, authenticated`,
  run as `postgres` (the role every migration on this project runs as — confirmed
  `rolsuper = false`, confirmed NOT a member of `supabase_admin`, confirmed not the owner of any
  `net.*` function), completed WITHOUT ERROR but a before/after comparison of `net.http_post`'s own
  `proacl` and of `has_function_privilege('public', ..., 'execute')` proved it silently did
  nothing — PostgreSQL only lets a REVOKE actually remove a grant made by the revoking role itself
  (or one it has ownership/admin authority over); the implicit PUBLIC-default grant was made by the
  owner (`supabase_admin`), not `postgres`, so `postgres` revoking it is accepted syntactically but
  has zero effect. A second probe confirmed no workaround: `postgres` is not a member of
  `supabase_admin` (`pg_has_role` false), and `alter default privileges for role supabase_admin in
  schema net ...` errors "permission denied to change default privileges". **Conclusion: closing
  this requires authority this project's migration role does not have on this project** — it would
  need `supabase_admin` or actual superuser access, available only via a Supabase support request,
  not from inside this repository. The migration does NOT mutate any `net.*` grant (doing so while
  claiming success would be a false security claim); the already-existing, already-effective
  mitigation is unchanged and is the real control: every caller of `net.http_post` in this codebase
  (`wa_otp_fast_dispatch_invoke`) is itself owned by `postgres` and IS lockable by `postgres`
  (confirmed — already revoked from public/anon/authenticated by its own migration), callable only
  from one other function in this codebase, never from a grant-mediated external path; `net.*`
  itself staying PUBLIC-executable is unreachable from outside this project's own Postgres
  connection (PostgREST never exposes the `net` schema). Residual risk is unchanged from before
  this migration, not newly accepted by it.
- **(c) dispatch-time re-check, built in `wa-milestone-dispatch-core.ts`** (TS, not a migration —
  `customerLinkOtpUnsendableReason`, renamed from `customerLinkOtpStillSendable` for the fix below):
  re-checks `is_customer_link_otp_enabled()` via RPC immediately before either dispatch path sends
  a `customer_link_otp` row, fail-OPEN (send, log) on a transient RPC error, fail-CLOSED (refuse,
  mark `failed`/`customer_link_otp_disabled_at_dispatch`) on an explicit `false` — closing the
  previously-Low/Info gap where the flag was only checked once, at request time.

**Independent adversarial review** (fresh agent, no prior context, same bar as sections 7/9.1):
found **one HIGH** — `is_customer_link_otp_enabled()` (`20261120100100`) was granted EXECUTE to
`authenticated` only, never `service_role`; the new dispatch-time re-check calls this RPC using the
Edge Function's service-role admin client, so in real deployment every single call would hit
"permission denied for function", silently swallowed into the re-check's own fail-open branch —
the entire re-check would have been a permanent no-op in production, not actually re-checking
anything, ironic given its purpose. **FIXED**: `grant execute on function
public.is_customer_link_otp_enabled() to service_role;` added to the new migration (additive, does
not touch the already-applied `20261120100100` file), proven live via rehearsal (`G4` assertion)
and locked in by a new unit test asserting the disabled-dispatch path's error reason. Two LOW
findings, both fixed: (1) the disabled-at-dispatch path previously reused `error =
'otp_expired_or_used'`, conflating a deliberate admin action with a genuinely stale code in data
ops' later reading of `whatsapp_outbox.error` — split into a distinct
`customer_link_otp_disabled_at_dispatch` reason. (2) this section itself was the missing
cross-reference the review flagged ("DECISIONS.md section 10" cited before it existed) — now it
exists. No unresolved Critical/High/Medium remains after the fix.

### 10.3 Verification

- **Local (WSL Ubuntu 24.04, Postgres 16.15, no sudo password available):** `pg_cron`/`pg_net` are
  not installable here without root (apt/sudo unavailable), so a user-owned, no-sudo cluster
  (`initdb`-created, alternate port, unix socket under `$HOME`) was stood up with hand-built
  stand-in `cron`/`net` schemas replicating the LIVE project's exact confirmed properties (role
  memberships, `net.*` owned by `supabase_admin` with null `proacl`, `postgres` role literally
  non-superuser with the exact live `pg_auth_members` membership set). The real, unmodified
  migration file was run AS that stand-in `postgres` role (not the local superuser) and: created
  the scrub function/cron job without error; a direct call correctly scrubbed the
  expired-and-never-sent row and the used-but-still-pending row (status/error/payload/
  template_params all correct) while leaving a still-valid pending row completely untouched; a
  second call was a clean no-op. A separate proof confirmed the existing `net.http_post` wrapper
  pattern (SECURITY DEFINER, owned by `postgres`) still works when called by `service_role` even
  with `net.*` itself untouched, and that `anon` calling the same wrapper directly still fails —
  confirming the real, load-bearing control is the wrapper, not `net.*`'s own ACL.
- **Live rehearsal** (allowed, non-persisting, same convention as every prior migration on this
  branch — one DO block, `lock_timeout` 5s, 11:00 IST gate, org-fingerprint pin,
  `__TEST_`-prefixed throwaway rows, sha256-pinned embedded migration+test text, ends in an
  unconditional `RAISE EXCEPTION`): embeds `20261120100200` (not yet live as of this run) ahead of
  the new migration in the same rolled-back transaction, so it does not depend on apply order
  outside this script's control. **10 of 10 assertions passed** (`G0`-`G4`, `P1`-`P4`,
  `P1-3`) and the independent before/after real-row fingerprint (`whatsapp_outbox` non-test rows
  only — the cron job's own creation is deliberately excluded from this fingerprint, since
  scheduling it is this migration's own intended effect, not a mutation to catch) is identical:
  `89666fb82e9ac6ccb121bcd0a6d82522` before and after.
- **DRYRUN-OK apply script**, same convention (org pin, already-registered refusal, pinned sha256,
  post-apply checks including the `service_role` grant, anon-exposure-adjacent checks, real-org
  fingerprint re-check), run through the same verified runner: raises `DRYRUN_OK` cleanly on its
  first statement, nothing below it ran.
- `tsc -b`, `oxlint`, `npm test` (779 passed / 17 skipped — 3 new tests for the dispatch-time
  re-check), `npm run build` all pass clean with the TS changes in place.

### 10.4 Status at hand-off

- **Built, local- and live-rehearsed, NOT applied, NOT pushed:** `20261121100100_customer_link_otp_dispatch_hardening.sql`
  (the expiry sweep + the `service_role` grant fix) and its full ops bundle
  (`gen_dispatch_hardening_scripts.mjs`, `.rehearsal.sql`, `.apply.sql`, `.apply.dryrun.sql`) and
  `supabase/tests/customer_link_otp_dispatch_hardening.test.sql`.
- **Built, tested, NOT applied (TS, ships with the Edge Function the next time it's deployed —
  deployment itself is step 6, explicitly out of scope this pass):** the `wa-milestone-dispatch-core.ts`
  dispatch-time re-check (`customerLinkOtpUnsendableReason`) and its test coverage.
- **Found genuinely infeasible for this project's migration role, documented, not built:** pg_net
  schema-level ACL hardening (10.2(b)) — recommend a Supabase support request if the owner wants
  this closed at the `net` schema level itself; the existing wrapper-function control is unchanged
  and sufficient for today's risk.
- **BLOCKED, needs owner input (10.1), unchanged from 9.3's prior finding:** `lexdraft_otp`'s real
  body/footer/button-type/language facts. Step 4(d) (the `whatsapp_event_templates` mapping row)
  is SKIPPED pending that input — nothing in this repository references `lexdraft_otp` as a result
  of this pass.
- **No live apply, no push, no Edge Function deploy, no secret changes, no live customer-facing
  test performed by this pass**, per this phase's own explicit instruction (steps 6-8 gated on the
  owner's typed "APPROVED", not given).

## 11. Phase 3 continuation (2026-10-30, same day): owner-confirmed template facts, redaction
## reconciliation with a concurrent session's trigger design, and the `lexdraft_otp` mapping

The owner provided the real `lexdraft_otp` template facts (read directly off the live Wasi
template edit form, screenshot, not re-derived): category Authentication, language `en`, approved;
body Meta-generated and not editable, `"Your verification code is *{{1}}*."` plus an optional
security-disclaimer line and an optional expiry line whose presence is not guaranteed; exactly one
Copy Code button, needing the code in both the body component AND the button component (Meta's own
documented shape: `sub_type "url"`, `index "0"`, `text = code`); **brand check PASSED** (Meta-
generated body, no third-party brand text — the owner separately confirmed the account itself is
the right one, resolving 9.3/10.1's "LexDraft" naming concern). This section records what was built
from those facts, AND a required reconciliation the owner separately flagged.

### 11.1 Reconciling two redaction designs into one, not two stacked on top of each other

The concurrent session's `20261120100200_whatsapp_outbox_secret_payload_scrub.sql` (commit
`9caef1d`, already read and ceded to in section 10.0) is a registry table
(`whatsapp_payload_secret_ref_types`) plus a BEFORE UPDATE trigger (`scrub_whatsapp_outbox_secret_payload`)
that nulls `template_params` and strips `payload`'s `code` key on ANY status transition away from
`pending`, for a ref_type registered `redaction_covered = true` — `customer_link_otp` already is
(that migration's own insert, confirmed). This session's own `20261121100100` expiry sweep had
independently duplicated that same clearing logic inline. The owner asked: verify whether the
trigger alone already covers the sweep's own gap case, and drop the duplication if so.

**Verified, not assumed:** a Postgres BEFORE UPDATE trigger's `NEW` record carries over every
column's prior value for any column the application's `UPDATE ... SET` list doesn't mention — so
the trigger fires and clears `template_params`/`payload.code` on ANY update that flips
`status` away from `pending` for a covered ref_type, REGARDLESS of whether that update's own SET
list mentions `template_params`/`payload` at all. This was proven, not just reasoned about, three
ways: (1) a local WSL rehearsal with the real trigger function (reproduced verbatim from the
committed migration file, not re-invented) attached, where the sweep's simplified UPDATE (status +
error only) still ended with `template_params` null; (2) a live rehearsal test (`P5`) that
deliberately mirrors `wa-send-core.ts`'s own real `patchForOutcome` update shape — `status`,
`wa_message_id`, `delivery_status`, `error`, never `template_params`/`wasi_response` — and confirms
the trigger still clears them; (3) direct reading of `scrub_whatsapp_outbox_secret_payload`'s
function body (not just its comment).

**Result:** `20261121100100`'s own `scrub_expired_customer_link_otp_outbox()` was simplified to NO
LONGER set `template_params` or strip `payload.code` itself — it relies entirely on the other
migration's trigger for that (one mechanism, not two). What the sweep still does, because nothing
else can: produce the UPDATE for a row no dispatch pass ever visits before its challenge expires
(the trigger only fires on an actual UPDATE; an unvisited row never gets one), and redact
`payload.body` — the rendered sentence containing the digits in prose, which the trigger
deliberately never touches (it only strips the separate `code` JSON key). The registry's
`covered_note` was rewritten to describe this as one reconciled system, not three independent
claims. Neither `20261120100000`, `20261120100100`, nor the concurrent session's `20261120100200`
were edited — all changes are in `20261121100100` (already committed by, and owned by, this
session, so amending it further before it is ever applied is not the same as editing an applied or
another session's committed file).

### 11.2 `customer_link_otp` registration confirmed, exact row stated

`whatsapp_payload_secret_ref_types` has exactly one row: `ref_type = 'customer_link_otp'`,
`redaction_covered = true` (inserted by `20261120100200`, re-confirmed read-only and by this
phase's own rehearsal, not assumed). `guard_secret_ref_type_template_mapping` — the BEFORE
INSERT/UPDATE trigger on `whatsapp_event_templates` — therefore allows the `lexdraft_otp` mapping
below; a test (`customer_link_otp_template_mapping.test.sql`, `G2`) proves the SAME guard genuinely
REFUSES a different, deliberately-uncovered ref_type, so this isn't assumed from reading the guard's
code either.

### 11.3 The `lexdraft_otp` mapping, new migration, strictly after the redaction fix

`20261121100200_customer_link_otp_template_mapping.sql`: adds `has_auth_copy_code_button boolean
not null default false` to `whatsapp_event_templates` (every existing mapping row unaffected), then
inserts one row per real organisation — `event_key = 'customer_link_otp'`, `language = 'en'`,
`wasi_template_name = 'lexdraft_otp'`, `param_map = {"1": "code"}` (`"1"` matches Meta's own
positional `{{1}}` numbering; `"code"` is the variable key `wa-event-context.ts` already populates,
phase 2), `has_auth_copy_code_button = true`. Timestamped `20261121100200`, strictly after
`20261121100100` — file ordering, not just reasoning, enforces that the redaction fix exists before
this mapping can.

`wa-send-core.ts`'s `buildTemplateRequest` gained `TemplateMapping.hasAuthCopyCodeButton`: when
set, it requires exactly one resolved body param (anything else is `copy_code_button_requires_exactly_one_body_param`,
refused rather than guessed) and duplicates that single value into a new `components` field on the
outgoing Wasi request — Meta's own documented shape, body component + button component (`sub_type
"url"`, `index "0"`), both carrying the same code. **Traced, not assumed, that `components` is
NEVER persisted**: `payloadFor`/`templateInfo` (the only things that become `whatsapp_outbox.payload`/
`.template_params`) only ever read `{name, params}` off the built request, never `.components` —
same precedent as `headerMediaUrl`, which is also request-only. `whatsapp.ts`'s `findApprovedMapping`
and `src/types/database.ts`'s hand-patched type (Docker unavailable for `gen types`, per this
project's standing note) were both updated to carry the new column through.

### 11.4 Second independent review: one more HIGH found and fixed — `wasi_response`

A second fresh reviewer (no prior context, same bar) attacked the reconciled whole. Findings:
- **Verified true, no changes needed:** the trigger-is-sole-clearing-mechanism claim (11.1);
  `components` is never persisted (11.3); the guard trigger genuinely blocks a bad mapping, and
  `ON CONFLICT DO UPDATE` cannot bypass a row trigger (Postgres fires row triggers on the UPDATE
  branch of an upsert too); `has_auth_copy_code_button` cannot leak onto an unrelated mapping
  (defaults false, only the one row is set `true`, and a wrongly-flagged multi-param mapping would
  hard-fail rather than fabricate a button).
- **HIGH, fixed:** `whatsapp_outbox.wasi_response` (Wasi's raw send-response body,
  `20261016300000_wa_dispatch_v2_schema.sql`) was covered by NONE of the reconciled mechanisms —
  the trigger only touches `template_params`/`payload.code`; the app-level and sweep redaction only
  touch `payload.body`. `sanitizeForStorage`/`redactWasiText` only masks 10-15-digit (phone-shaped)
  runs, never a bare 6-digit code, so if Wasi's real API ever echoes a submitted template param back
  in its response — a common BSP pattern, and this phase's own `components` duplication sends the
  code a second time in the same request, plausibly raising that odds — the plaintext code would
  sit in `wasi_response` forever, readable via `whatsapp_outbox_select_staff`, uncovered. **Fixed**:
  a new, separate trigger, `scrub_whatsapp_outbox_wasi_response` (own function, own trigger name —
  additive and complementary to the concurrent session's trigger, not a duplicate of it), nulls
  `wasi_response` under the identical status-transition condition. Proven via a new test (`P5`,
  11.1 above) that mirrors the real send path's exact update shape, not assumed. Not claimed to
  close every conceivable leak path (Wasi's real echo behavior is, like every other wire-format
  detail in this feature, only settled by the owner's later live phone test) — closes the concrete
  mechanism this review found, for the `customer_link_otp` ref_type specifically, consistent with
  this project's existing scoped-defense style (it does not attempt to fix `redactWasiText`'s
  digit-length gap generically for every other template, which is a broader, separate concern).

**No unresolved Critical/High/Medium remains** after this fix.

### 11.5 Verification (combined package)

- **Local WSL**, extended from phase 3's own harness: the concurrent session's real trigger/guard
  function bodies (reproduced verbatim, not re-invented) were added to the stand-in schema, along
  with a minimal `organizations`/`whatsapp_event_templates`. The real, unmodified
  `20261121100100` + `20261121100200` migration files ran cleanly as the stand-in `postgres` role;
  a direct call to the sweep correctly scrubbed the expired and used-but-pending rows (confirmed
  `template_params`/`wasi_response` both null afterward, via the OTHER migration's trigger plus
  this phase's new one, not this function's own code) while leaving the still-valid row completely
  untouched; the mapping row was created correctly shaped; the guard trigger correctly refused a
  deliberately-uncovered ref_type.
- **Combined live rehearsal** (one transaction, non-persisting, same convention — org pin, 11:00
  IST gate, sha256-pinned embedded text for all five pieces, ends in unconditional `RAISE
  EXCEPTION`): embeds the prereq (`20261120100200`, still not live as of this writing) ahead of
  both new migrations and both their tests. **16 of 16 assertions passed** (hardening: `G0`-`G4`,
  `P1`-`P5`; mapping: `G0`-`G3`, `P1`). Independent before/after fingerprint of real
  `whatsapp_outbox` rows and every OTHER real template mapping (deliberately excluding
  `customer_link_otp`'s own new row, the mapping migration's intended effect) is identical,
  `55e2994d492e58bc0f2817c45bddda33` before and after; a separate explicit check confirms the real
  org's new `customer_link_otp -> lexdraft_otp` row is correctly shaped.
- **Both DRYRUN-OK apply scripts** (hardening and mapping) raise cleanly on their first statement.
- `tsc -b`, `oxlint`, `npm test` (783 passed / 17 skipped — the `waOutboxSentGuard` CI guard caught
  a literal `"whatsapp_outbox"` substring this phase's own first-draft doc comment introduced into
  `wa-send-core.ts`, a pure-logic module the guard expects never to name that table; reworded, not
  a real issue, confirmed green), `npm run build` all pass clean.

### 11.6 Status at hand-off

- **Built, local- and combined-live-rehearsed, NOT applied, NOT pushed:** the revised
  `20261121100100` (now reconciled, plus the new `wasi_response` trigger) and the new
  `20261121100200` template-mapping migration, both with full ops bundles, both tests.
- **Built, tested, NOT applied (TS):** `wa-send-core.ts`'s copy-code-button support,
  `whatsapp.ts`'s mapping lookup extension, `src/types/database.ts`'s hand-patched type.
- **Step 2/3 (template facts, brand check): RESOLVED this pass** — owner-confirmed, PASSED.
- **Step 4(d) (the mapping): DONE this pass**, no longer skipped.
- **Not proof the feature works end-to-end** — per the owner's own explicit instruction, only the
  owner's later live phone test proves that; nothing in this pass claims otherwise.
- **No live apply, no push, no merge to main, no Edge Function deploy, no secret changes, no live
  customer-facing test performed by this pass**, per this phase's own explicit instruction — all
  gated on the owner's typed "APPROVED", not given.

## 12. Pre-apply sanity round (2026-11-30ish, same worktree): `customer_auto_onboard` landed on
## `origin/main` in the meantime — checked for collisions, and a real cross-feature gap found and
## STOPPED on, not fixed

`git fetch origin` shows `origin/main` moved far ahead (product-lifecycle integration branch), and
specifically `supabase_migrations.schema_migrations` on the live project now also includes
`20261121100000` (the master-only manual-link stopgap, owner-applied, 0 High — `admin_link_customer_google_account`/
`admin_unlink_customer_google_account`, confirmed OUT OF THIS FEATURE'S SCOPE, not touched) and
`20261130100000`–`20261130100003` (`customer_auto_onboard` package, also owner-applied). Full live
version list confirmed read-only: `...20261120100000, 20261120100100, 20261121100000,
20261125100000-20261125100800, 20261130100000-20261130100003`. `20261120100200` (the concurrent
session's redaction trigger, commit `9caef1d`) and this feature's own `20261121100100`/
`20261121100200` remain NOT live, exactly as before.

### 12.1 No version collision, no renumbering needed

`20261121100100`/`20261121100200` do not match any live version string — no collision. Checked
whether applying them NOW, after the later-timestamped `20261130` batch is already live, creates
any REAL problem (not just a numbering oddity): read all four `20261130*` migration files in full
(via `git show origin/main:...`, they are not yet merged into this branch) — none reference
`whatsapp_outbox`, `customer_link_otp*`, `cron.*`, `net.*`, or `is_customer_link_otp_enabled` in any
form (grepped, zero matches). This feature's three pending migrations (`20261120100200`,
`20261121100100`, `20261121100200`) touch `whatsapp_outbox`, `whatsapp_event_templates`,
`whatsapp_payload_secret_ref_types`, `customer_link_otp_challenges`, and `pg_cron` — zero table/
function overlap with `customers`/`profiles`/`auto_link_blocked_at`/the admin link functions. **No
renumbering done** — there is nothing to renumber against; the two batches are fully independent,
and this project's apply mechanism (the rehearsal/apply-script convention, not a strict sequential
runner) does not require chronological application order, only that each migration's own
dependencies are satisfied, which these are (confirmed: `20261120100200` must still apply before
`20261121100100`/`20261121100200`, as already documented).

### 12.2 Anon-exposure baseline: already correct, no change needed

Confirmed read-only: `admin_link_customer_google_account`/`admin_unlink_customer_google_account`
are `authenticated`-executable, NOT `anon`-executable — exactly the owner's stated expectation, not
a leak. Checked this feature's own rehearsal/apply scripts (`customer_link_otp_phase3_combined.rehearsal.sql`,
both `.apply.sql` files): none of them perform a whole-`public`-schema anon-EXECUTE diff (unlike
the much earlier base-feature apply script, which did and is not re-run by this round) — every
`has_function_privilege('anon', ...)` check in this round's scripts names a SPECIFIC function this
feature itself created (`scrub_expired_customer_link_otp_outbox`, `scrub_whatsapp_outbox_wasi_response`,
etc.), never a schema-wide scan. There is therefore no baseline in this round's own scripts that
could ever flag the two admin link functions as new/unexpected — nothing to update.

### 12.3 BLOCKING QUESTION, not fixed: `verify_customer_link_code` does not respect
### `customers.auto_link_blocked_at` — the OTP path can silently undo a master's unlink

Read `customers.auto_link_blocked_at`'s real definition from `20261130100000`/`20261130100002`
(not assumed): set by `admin_unlink_customer_google_account` on every successful unlink
(`auto_link_blocked_at = now(), auto_link_blocked_by = auth.uid()`), cleared ONLY by
`admin_link_customer_google_account` on an explicit master relink
(`auto_link_blocked_at = null, auto_link_blocked_by = null`) — never automatically, by
construction. `customer_auto_onboard()` (the EMAIL-based auto-link path, `20261130100001`) already
respects it: `if v_matched.primary_profile_id is null and v_matched.auto_link_blocked_at is null
then` link, `elsif v_matched.auto_link_blocked_at is not null then` refuse with an explicit reason.

**`verify_customer_link_code` (the PHONE-based OTP link path, this feature, already live in
`20261120100000`) does NOT.** Read the actual current definition line by line, not assumed:
- `request_customer_link_code`'s match lookup (lines 294-302) selects
  `id, org_id, primary_profile_id, is_test, preferred_language` — no `auto_link_blocked_at` column
  at all (the column did not exist when this function was written) — and its exclusion condition
  (`v_match_count <> 1 or v_match_primary_profile_id is not null or v_match_is_test`) does not
  check it either.
- `verify_customer_link_code`'s own lock-time re-check immediately before linking (lines 521-524,
  `for update` on the customer row first) is `where id = v_challenge.customer_id and
  (primary_profile_id is not null or is_test)` — again, no `auto_link_blocked_at` check.

**Consequence, concrete, not hypothetical:** a customer a master unlinked (`primary_profile_id`
now `null`, `auto_link_blocked_at` set) is, from the phone-based OTP flow's point of view, *exactly*
indistinguishable from any other unlinked, non-test customer — `request_customer_link_code` will
match them and send a code; `verify_customer_link_code` will link whichever Google-signed-in user
supplies that code. This defeats the master's unlink exactly the way the "unlink loop" the
`20261130100002` migration's own header comment describes for the EMAIL path — just through the
PHONE path instead, which that migration never touched (correctly out of its own scope, and
correctly out of this pass's scope to silently fix).

**Per the owner's explicit instruction, this is reported as a blocking question, not fixed:**

Proposed guard (NOT written to any migration file, NOT applied — text only, for the owner's
decision), mirroring `20261130100002`'s own pattern of reproducing a live function's body with one
added condition, as a NEW migration (never editing the already-applied `20261120100000`):

```sql
-- request_customer_link_code: treat a blocked customer exactly like an already-linked/test one --
-- same generic no-op response, so the response shape leaks nothing new.
select id, org_id, primary_profile_id, is_test, preferred_language, auto_link_blocked_at  -- ADDED column
  into v_match_id, v_match_org_id, v_match_primary_profile_id, v_match_is_test,
       v_match_preferred_language, v_match_auto_link_blocked_at                            -- ADDED var
  from public.customers where mobile = p_mobile;
...
if v_match_count <> 1
   or v_match_primary_profile_id is not null
   or v_match_is_test
   or v_match_auto_link_blocked_at is not null   -- ADDED
then
  -- existing generic no-op response, unchanged

-- verify_customer_link_code: same treatment at the lock-time re-check immediately before linking.
if exists (
  select 1 from public.customers
  where id = v_challenge.customer_id
    and (primary_profile_id is not null or is_test or auto_link_blocked_at is not null)  -- ADDED
) then
  return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0);  -- unchanged, collapsed response
end if;
```

Both additions are read-only checks of a column this feature does not own or write — they do not
redefine or alter `customer_auto_onboard()`, `admin_link_customer_google_account`, or
`admin_unlink_customer_google_account` in any way, and do not change `auto_link_blocked_at`'s own
semantics (still set/cleared only by the two admin functions). **Not applied. Waiting on the
owner's explicit go-ahead before this (or any variant of it) is written as a real migration.**

### 12.4 Status at hand-off, this round

- Items 1-3: confirmed clean, no action needed, no files changed.
- Item 4: **BLOCKING QUESTION surfaced to the owner, reported, not fixed.** No new migration
  written or applied for this.
- No files in this worktree were changed by this round (read-only checks + this doc update only).
- Still no live apply, no push, no merge, no deploy, no secrets, no customer-facing test.

## 13. Owner approved the guard (12.3) — built, ordered, reviewed, re-rehearsed

New migration `20261121100150_customer_link_otp_respects_auto_link_block.sql`, timestamped
between `20261121100100` (dispatch hardening) and `20261121100200` (template mapping) per the
owner's explicit ordering instruction. `create or replace`s `request_customer_link_code` and
`verify_customer_link_code`, reproducing their LIVE bodies (fetched via `pg_get_functiondef`,
sha256-pinned: `9e108f6e9f55ad8539773de90d3ceca201231e24874854d3db855f41829557a3` for request,
`2a12b2ef965e068297a40922f88477b9b8db92196b896755bc4599196e374bb4` for verify) plus exactly one
added condition each, exactly as proposed in section 12.3. The migration's own DO block refuses to
apply if either live body has drifted from these pinned hashes since written — same discipline
`20261130100002` used for the two admin link functions. Neither `admin_link_customer_google_account`,
`admin_unlink_customer_google_account`, nor `customer_auto_onboard` is touched.

### 13.1 Two independent reviews of the final combined package

**String-literal/factual accuracy review** found the reproduced function bodies' LOGIC exactly
matches the proposal (confirmed line-by-line against the live source, including correctly
reproducing `request_customer_link_code`'s POST-`20261120100100`-fast-dispatch body, not the
stale original — the `'code'` payload key and `wa_otp_fast_dispatch_invoke` nudge are genuinely
part of the live function, confirmed), and all sha256 hashes (per-function and whole-migration-
file) are byte-identical everywhere they appear (the migration file, the generator script, both
`.apply.sql`/`.apply.dryrun.sql` files). **One real discrepancy, fixed**: the first draft of this
migration's reproduction silently dropped nearly every original rationale comment from both
functions (the timing/rate-limit security-review notes, the row-lock rationale, the "lost the
race" note, etc.), contradicting its own header's "verbatim... nothing else changes" claim. Fixed
by reconstructing both function bodies against the exact live text (`pg_get_functiondef` output,
re-verified byte-for-byte against the pinned hashes on local Postgres 16 before and after the
fix) with every original comment restored, and ONLY the one new comment+condition added to each —
the migration's own claim is now actually true, not just asserted. Also flagged: this document's
section 12.4 was stale the moment this migration existed (superseded by this section) and 12.3's
line-number citation (`294-302`) referred to the pre-fast-dispatch file, not the actually-live one
— both noted here, not independently worth a further fix (the SQL content cited was accurate
either way).

**Security review**: no unresolved Critical/High/Medium. Confirmed: the new
`auto_link_blocked_at` check in `request_customer_link_code` produces a response and send-log
decision byte-identical to every other exclusion case (same branch, same `v_generic`, same
`'no_match'` decision, no new query specific to the blocked case) — no new oracle. The
`verify_customer_link_code` check sits after the code is already verified correct and the
challenge already marked used, under the pre-existing `for update` row lock on the customer, and
returns the identical `{status: 'invalid_or_expired', attempts_left: 0}` every other race-loss
case already returns. No alternate bypass path exists (`profiles` has no self-insert policy since
`20261006130000`; these two `SECURITY DEFINER` RPCs are the only non-master way a phone-linked
profile gets created). Grants/`search_path` unchanged and re-asserted by the migration itself. One
Low/Info residual, inherent to the existing design and not newly introduced: `request_customer_link_code`'s
own match lookup is an unlocked `select`, so a master could theoretically unlink a customer in the
narrow window between that lookup and the challenge insert, letting one more OTP get dispatched to
a now-blocked number — it can never actually result in a link (verify's locked re-check still
catches it), so this is a stray message at most, not a security bypass.

### 13.2 Verification (final combined package, this round)

- **Local Postgres (WSL)**: the exact live function bodies (captured via `pg_get_functiondef`, not
  re-typed) were loaded onto the local cluster first — confirmed their `pg_get_functiondef` hash
  there matches the pinned live hashes exactly (same Postgres 16 canonicalization), proving the
  pin is meaningful, not just internally consistent. The real, unmodified guard migration then ran
  against them, correctly detected drift when re-run against its OWN already-guarded output
  (proving the drift check works), and — reset to the pristine base and re-run once — applied
  cleanly. The dedicated test (14 assertions: blocked customer behaviour, byte-identical response
  vs. a nonexistent phone, blocked-mid-flow refusal with no link, unblocked customer unaffected,
  relink-after-unblock works again) passed in full, inside a rolled-back transaction.
- **Combined live rehearsal** (one transaction, non-persisting, same convention throughout —
  embeds the prereq, hardening + test, THIS guard + test, mapping + test, in that order): **24 of
  24 assertions passed** (hardening 11, guard 14, mapping 5 — consistent with 13.1 note: `G0` here
  simply restates that the migration's own assertions already proved the source change). Real-row
  fingerprint (`whatsapp_outbox`, every other template mapping, and every real customer's own
  link/block state) identical before and after: `b2ed235071b8f7a2c0b965ad07f75b38`.
  Re-ran again after the comment-fidelity fix (13.1) — identical result, same fingerprint.
- **All three pending migrations' DRYRUN-OK apply scripts** (hardening, guard, mapping) raise
  cleanly on their first statement at the final commit.
- `tsc -b` clean (no TypeScript changed this round).

### 13.3 Status at hand-off

- **Built, local- and combined-live-rehearsed, reviewed twice (string + security), NOT applied,
  NOT pushed:** `20261121100150_customer_link_otp_respects_auto_link_block.sql` and its ops
  bundle/test.
- **Final migration ordering for this feature's still-pending work:** `20261120100200` (prereq,
  committed by a concurrent session) → `20261121100100` (dispatch hardening) →
  `20261121100150` (this guard) → `20261121100200` (template mapping). No version collisions
  against anything live (section 12.1, unchanged).
- **No live apply, no push, no merge to main, no Edge Function deploy, no secret changes, no live
  customer-facing test performed by this pass.** The coordinator performs the actual live apply
  once satisfied with this round's results, per the owner's explicit instruction — not this pass.

## 14. Post-apply READ-ONLY analysis (2026-10-31): the auto-onboard collision, test-mode mechanics,
## frontend state, and a plan — nothing built, nothing applied this round

The coordinator applied all four pending migrations live (`20261120100200`, `20261121100100`,
`20261121100150`, `20261121100200`) and independently verified them clean. Before any deploy/
secrets/phone test, the owner asked for a pure read-only investigation. Nothing in this section was
written to the database; every fact below was read live via `pg_get_functiondef`/`information_schema`
through the sha256-verified `run_rehearsal.mjs`, or read from source on this branch and `origin/main`.

### 14.1 Item 1 — the auto-onboard collision is REAL and CONFIRMED: the phone path is currently
### dead in production for any already-onboarded user

Read the LIVE `verify_customer_link_code` body (re-fetched post-apply, not assumed from the
migration file). Its very first checks, unchanged by this feature's own guard, are:

```sql
if v_user_id is null then raise exception 'cannot_verify_code: not authenticated'; end if;
if exists (select 1 from public.profiles where id = v_user_id) then
  raise exception 'cannot_verify_code: profile_exists';
end if;
```

`request_customer_link_code` has the identical `profile_exists` guard. **`customer_auto_onboard()`
(live since 2026-10-30) creates a `profiles` row for EVERY Google sign-in, unconditionally, before
anything else can happen** — read its live body: on first sign-in it either links an existing
unlinked/unblocked email match (inserting `profiles` immediately) or creates a brand-new
`profiles` + `customers` pair (`source = 'customer_app'`). Either way, by the time a user could
ever reach the phone-OTP screen, they already have a `profiles` row — so BOTH OTP RPCs would
immediately `raise exception 'profile_exists'` and refuse. **Confirmed: as currently built, the
phone-OTP path can never complete for any user who has ever signed in with Google since
auto-onboard went live — which, per the owner's own framing, is now every Google sign-in.** This
is not a hypothetical; it is the literal first `if` in the live function.

**What "auto-created 'app' customer" actually looks like, read from the real schema and the real
auto-onboard migration, not guessed:**
- Table `public.customers`. The marker is `source = 'customer_app'` (set only by
  `customer_auto_onboard()`'s create-new path).
- `mobile` is `NULL` at creation (relaxed from `NOT NULL` to nullable by `20261130100000`
  specifically for this case — a Google-only sign-in has no phone yet).
- `primary_profile_id` = the signed-in user's own `auth.uid()`.
- "Empty," in the exact checkable terms `admin_merge_auto_customer` (read live, full body above)
  already uses as its own safety precondition for archiving a FROM customer: `source =
  'customer_app'`, `archived_at is null`, `primary_profile_id` is not null (i.e. it really is this
  caller's own auto row), and **zero rows** in `service_tickets`, `amc_contracts`, `warranties`,
  `rental_contracts`, `quotations`, `invoices` for that `customer_id`. (No separate "spares" check
  exists in the live function — spare handovers are tied to tickets, already covered by the
  `service_tickets` count. Nothing beyond these six tables is checked live; if the owner wants
  more tables covered, that is a new decision, not something already implied.)
- The TO side's own live preconditions: `is_test = false`, `archived_at is null`,
  `primary_profile_id is null`. (This feature's own guard, section 13, additionally requires
  `auto_link_blocked_at is null` — `admin_merge_auto_customer` itself does not check that column at
  all, since it is a master-driven explicit action, not an auto-link path; the new merge-on-verify
  logic below must check it itself, the same way this feature's guard already does elsewhere.)

**Proposed design (NOT built, NOT a migration file — text only, for the owner's approval), closing
the gap without ever calling `admin_merge_auto_customer` itself** (that function requires
`is_master()` and `current_org_id()` — a bare customer calling `verify_customer_link_code` is
neither a master nor necessarily resolvable the same way; the safety LOGIC is reused, the function
itself is not):

1. **`request_customer_link_code`**: before the existing `profile_exists` raise, allow a caller
   through if their own existing profile belongs to an auto-created, still-empty, unlinked-from-
   anything-real customer (`customers.primary_profile_id = v_user_id and source = 'customer_app'`,
   same six-table emptiness check as above) — everyone else (a real staff/technician account, a
   customer already linked by phone or by a prior merge, or an auto customer that already has real
   records) still gets the exact current `profile_exists` refusal, unchanged. This is the one
   place "never match staff/technician accounts" is enforced: a staff/technician profile's `role`
   is never `'customer'`, and the auto-created-customer check above structurally can never match
   one (a staff profile has no `customers` row with `source = 'customer_app'` pointing at it).
   Ambiguous phone (`v_match_count > 1`, already detected, currently a silent no-op): **flag the
   CALLER's own auto-created customer** `needs_review = true`, `needs_review_reason = 'phone
   matched more than one existing customer'` (same shape `customer_auto_onboard`'s own ambiguous-
   email path already uses) — the response to the caller stays the identical collapsed
   `v_generic` "if that number is registered..." message; nothing about the ambiguity is ever
   returned to the caller (no oracle). A phone already linked to someone else, or blocked
   (`auto_link_blocked_at is not null`, this feature's own existing check): no flag, no link,
   identical generic response — exactly today's behaviour, unchanged.
2. **`verify_customer_link_code`**: same early-exit relaxation (allow a caller through whose
   existing profile is this exact auto-created, empty, unlinked shape). After the code verifies
   correct and the existing lock-time re-check passes (matched customer still unlinked, not test,
   not blocked — unchanged, section 13), branch on whether the caller already has a profile:
   - **No existing profile** (today's only path): unchanged, exactly as live today.
   - **Existing profile, auto-created/empty** (the new path): under locks on BOTH the auto FROM
     customer (by the caller's own `primary_profile_id`) and the matched TO customer, in a fixed
     id order (same deadlock-avoidance convention `admin_merge_auto_customer` already uses),
     re-verify every FROM/TO precondition above (not just at request time — right here, under
     lock, the same discipline this feature's own guard already follows for `auto_link_blocked_at`),
     then: clear FROM's `primary_profile_id`, archive FROM (`archived_at = now()`, an
     `archived_by` column exists but there is no master actor here — record `null` or the
     caller's own `auth.uid()`, an open question for the owner, not decided here); set TO's
     `primary_profile_id = v_user_id`, `phone_verified = true`, merge `email` (`coalesce`, TO's own
     wins, matching `admin_merge_auto_customer`'s own convention); update the EXISTING `profiles`
     row (not insert — one already exists) to TO's own `org_id`/name/mobile/language, matching
     `admin_merge_auto_customer`'s own profile-realignment step; two `audit_log` rows, same shape
     as `admin_merge_auto_customer`'s own two rows, `action` values distinguishing this path (e.g.
     `customer_link_otp_merge` / `customer_link_otp_merge_archived`) with `reason: 'otp_verified'`.
   - Response: identical `{status: 'linked'}` either way — the customer-visible shape never
     changes between the two internal paths, exactly the owner's own explicit requirement.
   - If the FROM/TO preconditions somehow fail under lock at this point (a real record appeared on
     FROM between request and verify, TO got linked/blocked/archived in the meantime): refuse with
     the SAME collapsed `{status: 'invalid_or_expired', attempts_left: 0}` every other race-loss
     case in this function already returns — no new response shape, no new oracle.

This is a design, not code — it has not been written as a migration, and per the owner's own
stop-point discipline nothing above gets built without a separate typed "APPROVED" for its exact
migration content, same as every prior piece of this feature.

### 14.2 Item 2 — `wa_test_mode_enabled` is an ALLOW-LIST, not a suppress-all or a redirect

Read `supabase/functions/_shared/wa-test-mode.ts` in full (the one place every real send passes
through, `sendMessage` in `whatsapp.ts`, confirmed by its own header comment and call site).
Exact mechanics: when `settings.wa_test_mode_enabled = true` for an org, a send is allowed ONLY if
the destination number (bare 10 digits) is present in that same org's `settings.wa_test_allowed_numbers`
array; every other destination is BLOCKED — the `whatsapp_outbox` row still gets created/claimed
(insert-first, per `wa-send-core.ts`'s own convention) but is marked `status = 'failed'`,
`error = 'blocked: test_mode_not_allow_listed'`, and a `WA_SEND_BLOCKED` row is written to
`audit_log` (last four digits only) — nothing is sent to Wasi at all, nothing redirected anywhere.
It fails CLOSED on a `settings` read error (blocks rather than risks a real send if the flag's own
state can't be confirmed).

**Live state, read-only, confirmed for the real org ("GV Mart"):** `wa_test_mode_enabled = true`
already, `wa_test_allowed_numbers = ["9092766740"]` already (one number already allow-listed from
earlier work on this project). **Safest mechanism for the owner to receive exactly one real code
on his own phone with zero risk to any real customer**: add the owner's own mobile number to that
same `wa_test_allowed_numbers` array (alongside the existing one, or replacing it — the owner's
call) for the real org. With test mode already on, this is the ONLY thing that needs to change for
this specific safety property — no code change, no deploy, a single `settings` row update (which
this round does NOT perform — read-only).

**Important additional finding, not asked for but load-bearing for item 3**: `is_customer_link_otp_enabled()`
(read live) requires BOTH `customer_link_otp_settings.enabled = true` AND
`exists (select 1 from settings where wa_dispatch_v2_enabled = true and wa_dispatch_v2_scope = 'org')`.
**Read live: `wa_dispatch_v2_enabled` is currently `false` for the real org** (`wa_dispatch_v2_scope`
defaults to `'numbers'`). Flipping the OTP flag alone, without ALSO turning on `wa_dispatch_v2_enabled`
+ `wa_dispatch_v2_scope = 'org'` for that org, would leave `is_customer_link_otp_enabled()` returning
`false` and both RPCs refusing with `feature_disabled` regardless. **This is a real, non-trivial
side effect to flag explicitly**: `wa_dispatch_v2_enabled`/`scope` are not OTP-specific — they
govern the SAME shared milestone dispatcher's behaviour for `service_ticket`, `service_visit`,
`invoice`, and `purchase_quote_request` sends too. Turning this on for the real org to test OTP
changes the dispatch path for every one of those other message types for the whole org for the
duration of the test window, not just for OTP. Not a reason to avoid it (v2 is the intended target
state for this project per its own history), but the owner should know the test window is not as
narrowly scoped as "just OTP."

### 14.3 Item 3 — exact sequence to test end-to-end while the flag stays off for everyone else

There is no existing per-customer or per-account allow-list for `customer_link_otp_settings.enabled`
itself (it is one global boolean row, `id = true`) — read live, confirmed no such column exists.
The only two realistic options, given what already exists:

**Option A — temporary global enable + test-mode allow-list (recommended), exact sequence:**
1. Add the owner's own mobile number to the real org's `settings.wa_test_allowed_numbers`
   (test mode is already on for that org — confirmed above).
2. Set the real org's `settings.wa_dispatch_v2_enabled = true` and `wa_dispatch_v2_scope = 'org'`
   (required per 14.2's finding — read, not assumed).
3. Set `customer_link_otp_settings.enabled = true` (global — the only lever that exists).
4. Owner performs the test from a device signed into the customer app. **If item 1's merge-on-
   verify fix is NOT yet built**, the owner must use a Google account that has NEVER signed in
   before (so `customer_auto_onboard` has never run for it, so no `profiles` row exists yet, so
   the current `profile_exists` guard never fires) — this proves the OTP send/receive/verify
   mechanics work end-to-end, but does NOT exercise the "already-onboarded customer takes over
   their phone-matched real record" scenario, since that scenario is exactly what item 1's fix is
   for. **If item 1's fix IS built and approved**, the owner can test with his own already-
   onboarded account directly, proving the real production scenario.
5. During the window between steps 3 and 6, any OTHER real customer who happens to attempt this
   (unlikely — nothing points them at it yet, see 14.4) would have their RPC calls processed
   normally (rate limits, challenge rows, audit_log) but their WhatsApp send would be BLOCKED by
   the test-mode allow-list (14.2) — no real customer ever receives a wrong message; the residual
   exposure is limited to extra rows in `whatsapp_outbox`/`customer_link_otp_send_log` for a number
   that isn't the owner's, not any customer-visible effect.
6. Immediately after: reverse exactly steps 1-3 — `customer_link_otp_settings.enabled = false`,
   `wa_dispatch_v2_enabled`/`scope` back to whatever they were before step 2 (`false`/`'numbers'`
   for the real org, confirmed), and remove the owner's number from the allow-list if it wasn't
   there before (the pre-existing `9092766740` entry stays, since that was already there before
   this round touched anything).

**Option B — skip step 3 entirely**, if only the WhatsApp send/template mechanics need proving
(not the actual phone-link flow): call `wa_otp_fast_dispatch_invoke`/the dispatcher directly against
a manually-inserted throwaway `customer_link_otp` outbox row pointed at the owner's own number,
under the same test-mode allow-list — narrower, proves less, but never touches the global OTP
flag or `wa_dispatch_v2_enabled` at all. Not detailed further here; Option A is the owner's
explicit ask ("test end to end").

### 14.4 Item 4 — frontend: NOT on `origin/main` today; this branch's own integration point is
### now STALE relative to `origin/main` and needs real rework, not just a merge

Fetched `origin/main` and read both branches' `LoginPage.tsx`/`GoogleLinkAccountCard.tsx` in full.

- **`origin/main` today**: `GoogleLinkAccountCard` is a 56-line dead-end NOTICE screen only
  (`reason: "staff_account" | "error"`) — no phone/code form anywhere in it. `LoginPage` routes a
  first-time Google sign-in with no `profiles` row to `<CustomerAutoOnboardGate />`, which calls
  `customer_auto_onboard()` and only falls through to `GoogleLinkAccountCard` on the two refusal
  cases above. **The phone-entry/code-entry OTP UI does not exist on `origin/main` at all.**
- **This branch**: `GoogleLinkAccountCard` (same file name, materially different component) IS the
  full phone/code two-step form (`services/auth.ts`'s `requestCustomerLinkCode`/
  `verifyCustomerLinkCode`, calling the two RPCs directly), gated by `isCustomerLinkOtpEnabled()`
  (reads `is_customer_link_otp_enabled()` live). **Confirmed flag-state behaviour, read from the
  component's own code**: while the query is loading, a blank frame (deliberately, to avoid a
  flash of the wrong state); once settled, if the flag reads anything other than exactly `true`
  (`false`, or the query errored), a fixed "not available yet" notice with no form at all — the
  phone-entry form itself is NEVER rendered while the flag is off; once the flag reads `true`, the
  phone step renders, then (after a successful request) the code step.
- **The real problem, not a trivial merge conflict**: this branch's `LoginPage.tsx` STILL routes
  "no profile row" directly to this card — it has never been updated for `CustomerAutoOnboardGate`,
  which did not exist when this branch was built. Merging `origin/main` into this branch would
  bring in `CustomerAutoOnboardGate`, and with it, "no profile row" would almost always resolve
  through auto-onboard BEFORE this card ever gets a chance to render — exactly the collision item 1
  describes, now visible at the UI layer too. **This branch's phone-OTP card, as currently wired,
  would essentially never be reached in practice once merged as-is** — not because of a merge
  conflict, but because the condition that used to trigger it ("no profile yet") now almost never
  survives to the point `LoginPage` checks it. A real decision is needed on WHERE/WHEN to surface
  phone-linking now: candidates include (a) as a "link your phone number" affordance inside an
  already-onboarded customer's own account/profile page (not at login at all), or (b) kept at
  login but only for the narrower cases `CustomerAutoOnboardGate` itself falls through on. This is
  a product decision for the owner, not something to decide unilaterally — flagged as its own item
  in the plan below, not quietly assumed.
- **What is pushed vs not**: nothing from this entire feature (migrations, Edge Functions,
  dispatcher wiring, or this frontend code) is on `origin/main`. Everything lives only in this
  unpushed branch (`feat/customer-otp-link`) and the now-applied-live-but-still-unpushed migrations.

### 14.5 Item 5 — the mapping and the dispatcher's actual final payload shape, code masked

Confirmed live (re-read post-apply): `whatsapp_event_templates` has one row per organisation for
`event_key = 'customer_link_otp'`, `wasi_template_name = 'lexdraft_otp'`, `language = 'en'`,
`param_map = {"1": "code"}`, `has_auth_copy_code_button = true`, `is_active = true` — 8 rows (one
per org on this project, including `__TEST_` orgs from past rehearsals), all identical.

The button component is added in `wa-send-core.ts`'s `buildTemplateRequest` (read the current
source, lines ~93 and ~138-150 of this branch's file): when `mapping.hasAuthCopyCodeButton` is
true, it takes the single resolved body parameter (there must be exactly one, or the function
refuses with `copy_code_button_requires_exactly_one_body_param` rather than guessing) and builds:

```json
{
  "client_id": "<org's Wasi client id>",
  "to": "91XXXXXXXXXX",
  "type": "template",
  "template": "lexdraft_otp",
  "params": { "1": "██████" },
  "components": [
    { "type": "body", "parameters": [{ "type": "text", "text": "██████" }] },
    { "type": "button", "sub_type": "url", "index": "0", "parameters": [{ "type": "text", "text": "██████" }] }
  ]
}
```

(the `██████` placeholder stands in for the real 6-digit code — the SAME value in all three
places, duplicated per Meta's documented shape, never printed here as a real value). Only `params`
(the flat body-only map) is ever persisted to `whatsapp_outbox.payload`/`.template_params` —
`components` is request-only, confirmed by tracing `payloadFor()`/`executeSend` in the same file
(already independently verified by the earlier adversarial review, section 11/13). This exact
wire shape is Meta's documented convention for a copy-code AUTHENTICATION template, reproduced
faithfully from the owner's own reading of the live Wasi template form — **still not proven
against Wasi's real API until the owner's own live phone test**, per every prior note on this
point in this document.

### 14.6 Item 6 — plan, deliverable-only, nothing built

| # | Work package | What it is | Needs owner's approval for... |
|---|---|---|---|
| WP1 | Merge-on-verify migration (14.1) | New migration: relax the `profile_exists` guard for an auto-created/empty caller only, merge onto the matched customer under lock, flag ambiguous phones for review | The exact migration content (typed "APPROVED"), same discipline as every prior migration this feature has shipped — not written yet |
| WP2 | Frontend rewiring (14.4) | Merge `origin/main`'s `CustomerAutoOnboardGate` flow in, and DECIDE where/when the phone-link UI is now offered (login-time narrow case vs. an in-account "link your phone" affordance) | A product/UX decision on WHERE the entry point lives, before any code is written — this is not purely an engineering choice |
| WP3 | Edge Function deploy (`wa-otp-dispatch`, already built, never deployed) | Deploy the fast-dispatch Edge Function this feature already built in an earlier phase | Explicit typed "APPROVED" for deploy specifically — the standing stop-point for this whole engagement, unchanged |
| WP4 | Secrets (`WA_OTP_FAST_DISPATCH_SECRET` Edge Function secret + matching `wa_otp_fast_dispatch_secret` vault entry) | Provisioning the shared secret both sides of the fast-dispatch call need | The owner's own action — secrets have never been created/set by this work, by standing rule, not just this round |
| WP5 | Owner's own live test (14.2/14.3) | The temporary flag-flip sequence + the owner's own phone, end to end | Everything above (WP1 at minimum if testing the real merge scenario; WP3/WP4 if testing real WhatsApp delivery) plus the owner's own explicit decision to run it |

**Order**: WP1 before WP5 if the owner wants to prove the real "already-onboarded customer" merge
scenario (otherwise WP5 can run narrower, with a fresh never-signed-in Google account, without
WP1). WP2 is independent of WP1/WP3/WP4's ordering but gates whether a real customer could ever
reach this flow through the UI at all — without it, only a direct RPC call (as in WP5's test) can
exercise the backend regardless of what else ships. WP3+WP4 must both be done before any WhatsApp
message can actually be delivered (the legacy cron-only path would eventually pick up a pending
row too, but at the multi-hour cadence this project's own history already documents as unsuitable
for a 10-minute-expiry code). **Nothing in WP1-WP5 was built, written, deployed, or applied this
round** — this section is the plan only, awaiting the owner's go on each piece.

## 15. WP1/WP2/WP3/WP4 built, per the owner's approval of section 14's plan — read-only
## dispatch-queue analysis, two more independent review rounds

The owner accepted section 14's analysis and approved building (not applying) WP1, approved
building WP2 in this worktree (unpushed until WP1 is live), asked for WP3/WP4 to be prepared as
text only, and asked for a precise read-only answer on the live dispatch queue before any owner
test. All four are recorded here. **No live apply, no push to origin, no deploy, no secrets
execution, no customer-facing test performed by this round.**

### 15.0 Context update: the four migrations from sections 11-14 are now all applied live for real

Before starting this round, confirmed read-only: `20261120100200`, `20261121100100`,
`20261121100150`, and `20261121100200` are ALL now registered in
`supabase_migrations.schema_migrations` — the coordinator applied them directly and independently
verified them clean. This is why WP1's own rehearsal/apply scripts (below) embed and pin ONLY
`20261130100100` itself against the REAL current live state, not the whole prior chain — the
first draft of this round's rehearsal generator still tried to re-embed all four already-live
migrations and their own internal drift checks correctly refused (each pins the hash of what was
live BEFORE it itself applied, not the current, post-itself state) — found by actually running it
against the live project, not assumed.

### 15.1 Read-only dispatch-queue analysis (owner's explicit ask, before any test)

Read live: `whatsapp_outbox` currently has **zero `pending` rows** and 19 `failed` rows (18
`service_ticket`, 1 a different, non-milestone ref_type), and **every one of those 19 already has
`retried_at` set** — confirmed by reading their actual `error` text (`'blocked:
test_mode_not_allow_listed'` for most, one older `'neutralised: test AMC contract...'`).

Read `supabase/functions/wa-scheduled-tasks/index.ts`'s `runFailedSendRetries`/
`runFailedSendRetriesV2`/`runLegacyFailedSendRetries` in full to answer precisely, not generically:
both the v2 and legacy failed-retry passes filter `.is("retried_at", null)` — a row with
`retried_at` already set is EXCLUDED from ever being picked up by either pass again, permanently,
regardless of `wa_dispatch_v2_enabled`/`scope`. **Conclusion: turning `wa_dispatch_v2_enabled =
true` and `wa_dispatch_v2_scope = 'org'` on for ~15 minutes would retry, resend, or alter NONE of
the 19 existing failed rows or any pending row (there are none) — there is nothing currently
eligible for either retry pass to touch.** The only real effect during that window: any BRAND-NEW
milestone event firing during it (e.g. a technician completing a ticket) would route through the
v2 dispatch path instead of legacy for that one send — but `wa_test_mode_enabled`'s allow-list
(already `true` for the real org, confirmed) still blocks delivery to any number not on the list
regardless of which path handles it, so no real customer receives anything wrong either way; the
only difference is which code path processes it.

Given this, the owner's own fallback ("OTP gate accepting `scope: 'numbers'` for allow-listed
recipients only, needing its own review") is **not required by anything currently queued** — but
is still recorded here as a text proposal, per the owner's instruction, for future reference or if
the live queue state changes before the test actually happens: `is_customer_link_otp_enabled()`
would need a second, OR'd condition alongside its existing `scope = 'org'` check — something like
`exists (select 1 from settings where wa_dispatch_v2_enabled = true and wa_dispatch_v2_scope =
'numbers')` AND the caller's own matched/target customer's `to_mobile` is present in that org's
`wa_dispatch_v2_numbers` allow-list — checked at DISPATCH time (inside
`customerLinkOtpUnsendableReason`, which already has the row's `to_mobile`), not at the flag-check
RPC itself (which has no recipient to check against). **Not built.** This is exactly the kind of
security-sensitive gate change the owner said needs its own review before being built at all, and
nothing here authorizes building it.

### 15.2 WP1 — built, local- and live-rehearsed, two independent review rounds, NOT applied

New migration `20261130100100_customer_link_otp_merge_on_verify.sql`. Reproduces the LIVE bodies
of `request_customer_link_code`/`verify_customer_link_code` (sha256-pinned via
`pg_get_functiondef`, refuses on drift) plus: a relaxed `profile_exists` gate for a caller whose
existing profile is the empty, auto-created shape (reusing `admin_merge_auto_customer`'s own six-
table emptiness precondition, not calling that function — it requires `is_master()`); three
verify-time outcomes — MERGE (archive the empty auto customer, never delete, link the matched
customer, reason `otp_verified`), CLAIM OWN NUMBER (zero matches — set the typed, now-verified
mobile directly on the caller's own record), and NO LINK + `needs_review` flagged on the caller's
own customer (ambiguous match, or a match already linked elsewhere) — every outcome returning the
same collapsed generic response shape the feature has used throughout, no new oracle. Also adds
`customer_link_otp_card_eligible()`, a narrow read-only RPC WP2's frontend card uses, single-
sourced from the same eligibility test.

**Bug found by this round's own local rehearsal, not assumed correct from reading the code**: the
first draft's top-level relaxation gate in `verify_customer_link_code` required FULL emptiness
(the same six-table check), so a genuine race — real activity landing on the caller's own customer
in the gap between request and verify, exactly scenario F's own test — turned into an unhandled
`profile_exists` exception instead of the collapsed generic response every other race-loss case in
this function already returns. Fixed by loosening the top-level gate to a pure routing decision
(does a customer row of this shape exist at all), moving the full emptiness re-verification into
the MERGE branch's own lock-gated re-check, where a failure correctly collapses.

**Two independent review rounds**, same bar as every prior round on this branch:

*String-literal/factual accuracy*: confirmed the diff against the prior migration
(`20261121100150`) contains exactly the claimed additions, nothing else; confirmed the four copies
of the six-table emptiness check (request's gate, verify's merge-branch recheck, the card-
eligibility function, and — found genuinely NOT identical, correctly, since it's a deliberate
routing-only check — verify's top-level gate) match where they're supposed to; confirmed both
pinned hashes are consistent everywhere they appear; confirmed the test file's race scenarios
(E, F) genuinely insert the colliding row strictly between request and verify, with no cross-
scenario variable reuse. **Found a real factual gap, now closed by this section's own existence**:
every file in this round (the migration, both apply scripts, the rehearsal, this branch's frontend
code) cited "docs/DECISIONS.md section 15" before this section existed — section 14 ended the
document, and its own text still said WP1 was "not written yet." That citation is now accurate.

*Security*: found and this migration now fixes two real findings (not glossed over):
- **HIGH, fixed**: the CLAIM OWN NUMBER branch's own lock (`for update` on the caller's OWN
  customer row) does not serialize two DIFFERENT callers racing to claim the SAME phone number —
  each locks a different row, so under READ COMMITTED both callers' own `exists(...)` uniqueness
  checks could run concurrently before either UPDATE commits, both pass, and two customers end up
  sharing one `mobile` value. Fixed with a second advisory lock, keyed on the phone number itself
  (`pg_advisory_xact_lock(hashtext('customer_link_otp_claim:' || requested_mobile))`), taken before
  the uniqueness check — the same kind of fix `request_customer_link_code`'s own pre-existing
  advisory lock already applies for a different race, just keyed by phone instead of customer id
  here since two unrelated callers share no customer id to lock.
- **MEDIUM, fixed**: unlike the MERGE branch, CLAIM OWN NUMBER never re-verified the caller's own
  customer's safety preconditions under lock before writing to it — a concurrent merge/claim/admin
  action could have archived or reassigned it in the gap between request and verify. Fixed with an
  explicit re-check (still the caller's own, still unarchived, still has no mobile of its own yet)
  under the same lock, collapsing to the generic race-loss response on failure, consistent with
  the MERGE branch's own stated philosophy ("not trusted from request time").
- **LOW, fixed**: the MERGE branch's own re-check gained one more condition — TO's `mobile` must
  still equal the `requested_mobile` the caller actually proved control of, in case staff edited it
  between request and verify.
- Everything else reviewed and confirmed safe: response-shape/timing — no new oracle on any of the
  three outcomes; `needs_review` writes correctly scoped to the caller's own pre-selected customer,
  never leaked into the response; `customer_link_otp_card_eligible()` never raises, grants
  correctly asserted; lock ordering for the MERGE branch matches `admin_merge_auto_customer`'s own
  fixed-id-order convention.

**No unresolved Critical/High/Medium remains after the fixes above.** Honest limitation, recorded
not hidden: true concurrent-transaction testing (two genuinely simultaneous `verify_customer_link_code`
calls) is not practical in this project's single-session SQL rehearsal style — the fix's
correctness rests on standard Postgres advisory-lock semantics (the same reasoning this codebase's
own pre-existing locks already rely on, never tested via true concurrency either), not on a test
that literally races two transactions.

Re-verified after both fixes: local WSL Postgres (22 assertions, real live function bodies) and a
live, non-persisting rehearsal against the real current project (22 assertions, real-customer-row
fingerprint unchanged) both pass again. DRYRUN-OK re-confirmed. **Not applied** — waiting on the
owner's typed "APPROVED"; the coordinator performs the actual live apply.

### 15.3 WP2 — built in this worktree, gates green, NOT pushed

`src/app/customer/LinkPhoneCard.tsx`, wired into `CustomerHomePage.tsx` and
`CustomerProfilePage.tsx` only — `LoginPage.tsx` and `CustomerAutoOnboardGate` are untouched, per
the owner's own explicit product decision (no login-time step, no gate). Visible only when
`customer_link_otp_card_eligible()` returns true; renders nothing otherwise (not even a loading
placeholder), proven by a test of the extracted decision function `shouldHideLinkPhoneCard` (this
project has no component-render-test infrastructure, so the hide/show decision is pulled out as
its own pure function and tested directly — the same pattern `GoogleLinkAccountCard`'s own
cooldown/error-selection logic already uses). New `customerApp.linkPhoneCard.*` EN/TA strings
(parity test passes); the rest of the form reuses the existing `auth.*` strings. `tsc -b` / `oxlint`
/ `npm test` (795 passed / 17 skipped) / `npm run build` all pass. Committed in this worktree,
**not pushed to origin** — stays unpushed until WP1 is live, per the owner.

### 15.4 WP3/WP4 — prepared as text, NOT run

Written to `GV_mart\_local_only\reports\customer_otp_link\wp3_wp4_deploy_and_secrets_prep.md`: the
exact `npx supabase functions deploy wa-otp-dispatch --project-ref fsunrjithwcjtsutsgea --use-api`
command (WP3), and a PowerShell script that generates ONE fresh random secret and sets it in both
the Edge Function secret (`WA_OTP_FAST_DISPATCH_SECRET`) and the Postgres Vault secret
(`wa_otp_fast_dispatch_secret`), printing only `set`/`failed` for each step, never the value
itself, meant to run on the owner's own machine. Neither has been run.

### 15.5 Status at hand-off

- **WP1**: built, reviewed twice (1 High + 1 Medium + 1 Low found and fixed, no unresolved C/H/M),
  local- and live-rehearsed clean after the fixes, DRYRUN-OK. Not applied.
- **WP2**: built, gates green, flag-off behaviour proven by test. Committed, not pushed.
- **WP3/WP4**: prepared as text/script, not run.
- **Dispatch-queue analysis**: done — the live queue has nothing eligible for automatic retry
  right now, so the org-wide 15-minute test window is safe for existing data; the scoped
  `scope: 'numbers'` alternative is proposed as text only, not built, pending its own review if
  ever needed.
- No live apply, no push to origin, no deploy, no secrets execution, no customer-facing test
  performed by this round.

## 16. WP2 merged onto current main + gates green (push-ready), WP3 deploy-ready, WP4 full text

Owner approved WP1 (already live, independently verified) and gave GO for WP2/WP3/WP4-as-text.
Full detail in `GV_mart\_local_only\reports\customer_otp_link\phase6_wp2_push_ready_wp3_deploy_ready_wp4_text.md`;
summary here.

### 16.1 WP2

`origin/main` had moved to `2fb3d5a` (technician-picker unification, availability-assisted
scheduling, Edit Lead screen, explicit technician picker on create/reassign). Merged into
`feat/customer-otp-link` as commit `44adf97`: took origin/main's `GoogleLinkAccountCard.tsx`/
`LoginPage.tsx` entirely (this branch's old full phone-UI version predates the
`CustomerAutoOnboardGate` flow and is obsolete now that the card lives on Home/Profile instead),
deleted the now-orphaned `GoogleLinkAccountCard.test.ts`, kept both `<LinkPhoneCard />` and
`<LifecyclePartBanner />` in `CustomerHomePage.tsx`, and confirmed this branch's own
`customerApp.linkPhoneCard.*` i18n keys survived the EN/TA merge untouched.

Gates: `tsc -b` clean, lint pre-existing-warnings-only, `npm test` 955 passed/17 skipped,
`LinkPhoneCard.test.ts` 12/12 (proves flag-off hides the card), `npm run build` succeeded with a
new bundle hash (`index-eMpmB7-j.js` vs. the prior `index-_kXWOIg0.js`) that was grepped and
confirmed to contain the new `linkPhoneCard`/`customer_link_otp_card_eligible` strings. Re-fetched
origin afterward: still at `2fb3d5a`, unmoved — fast-forward precondition holds. **Not pushed**,
per the coordinator's division of labor; ready for the coordinator to push directly.

### 16.2 WP3

Confirmed `wa-otp-dispatch` does not exist on `origin/main` at all (wholly new), and that its
`config.toml` diff adds only its own `[functions.wa-otp-dispatch]` block — no other function's
entry touched. The `_shared/*.ts` diffs are real but inert for already-deployed functions:
Supabase bundles each function's `_shared/` snapshot at that function's OWN deploy time, so
deploying only `wa-otp-dispatch` cannot alter any other already-live function's running code.
Deploy command prepared (`npx supabase functions deploy wa-otp-dispatch --project-ref
fsunrjithwcjtsutsgea`) plus a one-line `--use-api` fallback. **Not run.** The 401/fail-closed
read-only post-deploy verification is deferred until the coordinator confirms the deploy
succeeded.

### 16.3 WP4

Full secrets-script text (generates one random value into a single env var, uses it for both the
Edge Function secret and the Vault secret so they can't drift apart, prints only `set`/`failed`,
clears the variable in a `finally` block) and full owner-test-sequence text (allow-list check →
gate on → OTP flag on → test → immediate reverse) produced in the phase-6 report, grounded in the
actual current live flag values (checked read-only): GV Mart's `wa_test_mode_enabled` is already
`true` with `wa_test_allowed_numbers = ['9092766740']`; `wa_dispatch_v2_enabled` is `false` /
`wa_dispatch_v2_scope` is `'numbers'`; `customer_link_otp_settings.enabled` is `false`.

New finding from the read-only count check: exactly one `customers` row already has mobile
`9092766740` — `a71a2965-633e-41ae-aa46-f31e9db5a4cc`, name **"jeshee test trigger"**,
`source='other'`, GV Mart org, not archived. It is itself a leftover test artifact, so the
owner's real Google-sign-in test would merge/claim into it rather than starting from a clean
no-match state. Recommended either renaming/archiving it first or using a dedicated `"ZZ Test
OTP"` customer + a different test number instead, per the owner's own dummy-customer idea — not
executed, read-only recommendation only. Also found a separate `profiles` row (`ranjan`,
`role='technician'`) with `phone = 9092766740`; confirmed this cannot collide with the OTP flow in
practice since the feature matches against `customers.mobile` for the calling user, never against
another person's `profiles.phone`.

Nothing in WP4 was executed: no secret generated, no flag flipped, no customer-facing test run.

### 16.4 Status at hand-off

- WP1: live (unchanged this round). WP2: merged + gates green, not pushed. WP3: diff-confirmed,
  deploy command ready, not run. WP4: full text produced, nothing executed.
- No live apply, no push, no deploy, no secret generation, no flag flip, no customer-facing test
  performed by this round.

## 17. WP2 pushed; WP4 secrets script corrected + owner-test .sql files; critical test-target finding

Owner-directed, this round only: WP2's full fetch→rebase→gates→push cycle run end-to-end
INCLUDING the actual push (coordinator deployed WP3 directly; not repeated here). WP4 remained
text/file-writing only — no secret generated, no flag flipped, no customer-facing test run. Full
detail in `GV_mart\_local_only\reports\customer_otp_link\phase7_wp2_pushed_wp4_scripts_and_owner_test_files.md`.

### 17.1 WP2 — pushed

Origin/main had moved again to `192c206` (3 unrelated referral-incentives commits). Rebase was
attempted first per the literal instruction, aborted immediately once it started replaying
conflicts against the first of 21 historical commits (already resolved once, in `44adf97`'s merge
commit) — used `git merge origin/main --no-edit` instead, same lower-risk approach as the prior
round, conflict-free this time. Gates green (955/972 tests, `LinkPhoneCard.test.ts` 12/12
re-proving flag-off after the merge, new build hash `index-DuGY2PpH.js` containing the card
strings). Origin/main confirmed unmoved after gates (`192c206`) — pushed on attempt 1; no attempt
2/3 needed. Branch `feat/customer-otp-link` now lives on origin at `db351e3`.

### 17.2 WP3

Deployed by the coordinator directly this round (CLI auth fixed by sourcing
`SUPABASE_ACCESS_TOKEN` from `gv-mart/.env`). Read-only verification so far: GET → 405, POST
without the secret configured → 500 "Not configured" (correct fail-closed; the own-secret check
runs before the bearer check). Wrong-bearer-specific 401 verification deferred until WP4's secret
exists.

### 17.3 WP4 — corrected scripts

`set_wa_otp_fast_dispatch_secret.ps1` rewritten and `set_vault_secret.mjs` added (both under
`GV_mart\_local_only\reports\customer_otp_link\`, neither executed), addressing all 5 of the
owner's review points: `$LASTEXITCODE` checked after every `npx`/`node` call (never prints `set`
on a false positive); `psql` (unavailable on this machine) replaced by the Node helper, reusing
`run_rehearsal.mjs`'s own Management-API credential convention; idempotent create-or-update
against `vault.secrets`/`vault.update_secret`/`vault.create_secret` (signatures confirmed live,
not guessed); a digest-only verify step (`vault.decrypted_secrets`'s `decrypted_secret` hashed
inside Postgres, compared against `supabase secrets list`'s own digest column, printing only
`match`/`MISMATCH` — with an honest caveat in the script that the CLI's digest format has not
been empirically confirmed since nothing was executed); the secret variable cleared in a `finally`
block, output limited to `set`/`failed`/`match`/`MISMATCH` lines only.

### 17.4 WP4 — owner-test `.sql` files + critical finding

Five runner-compatible files written (`status_before.sql`, `gate_on.sql`, `otp_on.sql`,
`reverse.sql`, `status_after.sql`), each a single statement (CTEs with `RETURNING` for the three
writes) so `run_rehearsal.mjs` captures a full before/after picture per file. Only
`status_before.sql` was actually run this round (read-only), capturing a real baseline.

**Critical finding, read-only, corrects an earlier round's incomplete answer**: the planned test
target, "jeshee test trigger" (`a71a2965-633e-41ae-aa46-f31e9db5a4cc`, mobile `9092766740`), has
`is_test = true` AND is non-empty (6 `service_tickets`, 1 `amc_contracts` row). Reading
`request_customer_link_code`'s own unchanged branch (a single test-flagged match is a silent
no-op — no send, no flag, no change) means the test as originally planned sends **nothing** and
touches **nothing**, regardless of either feature flag's state. Two alternatives proposed, neither
executed: (a) toggle this row's `is_test` to `false` for the test's duration (one-field, reversible,
lets the owner use their own real number and see the MERGE outcome) or (b) use a fresh number
matching no existing customer, allow-listed separately, to exercise the simpler CLAIM-OWN-NUMBER
outcome instead. Awaiting the owner's choice.

Gate-on window recommended at 15 minutes max (10-minute challenge expiry + buffer). Real-customer
experience during the window confirmed from `wa-test-mode.ts`'s own code (checked at the one
`sendMessage` chokepoint for every sender, independent of `wa_dispatch_v2_scope`): no WhatsApp
message of any kind for any non-allow-listed number, fails closed on a settings-read error too.
Cleanup steps given as text only (challenge-row delete, is_test toggle-back, unlink/archive via
the existing master tool) — no deletes performed, none without the owner's separate approval.

### 17.5 Status at hand-off

- WP1: live. WP2: merged, gates green, **pushed** (`db351e3`). WP3: deployed by the coordinator,
  read-only 405/500 fail-closed checks done, 401-specific check pending the secret. WP4: corrected
  scripts + 5 `.sql` files written, nothing executed except one read-only status query.
- No secret generated, no flag flipped, no customer-facing test run, no deletes performed.
