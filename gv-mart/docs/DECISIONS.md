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
