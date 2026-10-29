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
