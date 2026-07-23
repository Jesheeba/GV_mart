-- GV.md §2 "OTP job completion — APPROVED, keep + build the flow":
-- "Keep OTP as completion confirmation: OTP generated in the customer app
-- per work order; customer gives it to the technician to confirm
-- completion. Build the full flow (generate → customer sees code →
-- technician enters it → job confirmed complete)."
--
-- This was previously a blocked DECISION item (recommended three-tier
-- fallback: OTP → signature-on-technician-phone → photo "unverified") —
-- GV.md's own newer §2 text does not repeat that fallback, only the core
-- 4-step flow, so only the core flow is built here. See "Admin override"
-- below for the one small escape hatch that IS built, and the report for
-- why the full 3-tier alternative was deliberately NOT built.
--
-- ── Design decisions (documented per the build spec's instruction not to
-- leave any of this ambiguous) ──────────────────────────────────────────
--
-- 1. CODE FORMAT: 4-digit numeric (0000–9999, leading zeros kept), stored
--    server-side only. Chosen over 6 digits because this is a low-value,
--    single-use, visit-scoped code read aloud by a customer (often standing
--    in a doorway, sometimes elderly/non-technical) to a technician typing
--    on a small phone screen — the primary defense against guessing is
--    attempt-limiting (below), not raw entropy, so the extra 2 digits buy
--    negligible real security at a real UX cost. With a 5-attempt cap, a
--    blind guesser has at most a 5/10000 = 0.05% chance of landing the code
--    before lockout.
--
-- 2. GATE POINT: verify_visit_otp() below is BOTH the OTP check AND the
--    function that closes the visit (sets service_visits.timer_end) —
--    "never trust a client-supplied code, verify server-side in the RPC
--    that actually flips status" per the build spec. This replaces the old
--    client-side queueEndVisit()/service_visit.arrive patch that used to
--    close timer_end from OnSiteVisitPage's Payment step "Complete" button
--    (see services/technician.ts — queueEndVisit is removed by this
--    change). generate_visit_otp() is called automatically the moment the
--    technician reaches the Payment step (last step, right after
--    Signatures), so the customer sees the code with the most possible lead
--    time before the technician actually needs it.
--
-- 3. THE service_tickets.status = 'completed' TIMING QUESTION (flagged by
--    the build spec as "a real design call"): create_service_invoice()
--    (called from the earlier Invoice step, well before Signatures/
--    Payment/OTP) already flips service_tickets.status to 'completed' and
--    appointments.status to 'completed' — see
--    20260716130000_amc_price_per_year_and_covered_spares.sql. This
--    migration DELIBERATELY DOES NOT MOVE that flip to gate on OTP
--    verification. Reasoning:
--      a. service_tickets.status is read pervasively across the app
--         (SLA/report queries, isTicketClosed() gates on Map/JobDetail/
--         OnSiteVisitPage, getTodaysJobCounts' appointment-status count,
--         AMC next_service_date recalculation) — moving its transition
--         point is a systemic behaviour change far outside "build the OTP
--         flow," with real regression surface in modules this task's
--         BOUNDARIES explicitly puts out of scope.
--      b. GV.md's own phrase "customer gives it to the technician to
--         confirm completion" scopes OTP to the SERVICE VISIT being
--         confirmed complete, not the ticket's broader lifecycle status —
--         and service_visits.otp_verified (a column that has existed,
--         unused, since the very first schema migration
--         20260701090600_service.sql) is itself visit-scoped, reinforcing
--         that reading. The visit is the natural unit OTP gates.
--      c. Practically: gating the ACTUAL end-of-service moment technician
--         and customer both experience as "job done" — timer_end closing —
--         behind OTP, while leaving the pre-existing (unrelated to this
--         task) early status flip exactly as it already behaved, is the
--         minimal-blast-radius change that satisfies GV.md's literal ask
--         ("job confirmed complete" happens once the correct OTP is
--         entered) without silently rewriting ticket-status semantics that
--         other, unrelated code depends on.
--    Net effect: a ticket can now sit at status='completed' for the few
--    minutes between Invoice and the technician actually collecting the
--    OTP — this pre-existing quirk in the invoice→signatures→payment
--    ordering is NOT something this migration introduces (it already
--    existed), and is called out explicitly rather than silently left.
--
-- 4. RETRY / EXPIRY POLICY: a code expires 15 minutes after it is
--    (re)generated (comfortably covers Signatures + Payment-field entry
--    without leaving a long-lived code lying around) and allows 5 wrong
--    attempts before locking. A locked or expired code is never
--    auto-renewed — the technician must explicitly tap "Resend", which
--    mints a brand-new code and resets both the expiry and the attempt
--    counter (see generate_visit_otp's p_force parameter). Reaching the
--    Payment step again without tapping Resend reuses the still-valid code
--    unchanged, so the digits the customer already has stay correct.
--
-- 5. ADMIN OVERRIDE (the one safety valve built, and ONLY this one — not
--    the older doc's 3-tier signature/photo fallback): if a technician
--    genuinely cannot get a code to the customer (phone dead, customer
--    already left, etc.), a master or operation_admin can bypass OTP from
--    the ticket's admin detail screen, logged (bypassed_by/reason/at below)
--    and clearly distinguished from a real customer-confirmed completion —
--    service_visits.otp_verified stays FALSE on a bypassed visit; only
--    service_visit_otps.bypassed_at being set marks it as an override, so
--    reporting can always tell the two apart. This is exactly the "minimal
--    admin-override... acceptable minimal safety valve" the build spec
--    pre-authorized. See the report for why the fuller 3-tier fallback was
--    flagged instead of built.
--
-- 6. OFFLINE ARCHITECTURE NOTE: every other on-site write in this app
--    (photos, signatures, SOP steps, the invoice itself) queues through the
--    Dexie outbox (src/lib/offline/sync.ts) and syncs on a ~20s timer or on
--    reconnect — fire-and-forget by design. OTP verification cannot follow
--    that pattern: "never trust a client-supplied code" means the
--    right/wrong answer MUST come from a live round-trip to the server, not
--    a queued write that silently succeeds or fails minutes later with no
--    way to tell the technician "wrong code, try again" in the moment. So
--    generate_visit_otp/verify_visit_otp (wired in services/technician.ts)
--    are called directly, not enqueued — mirroring the existing precedent
--    for logCall()'s "not queued offline" doc comment. If the technician is
--    offline at the Payment step, the UI surfaces that plainly and lets
--    them retry once back online; every step before Payment remains fully
--    offline-capable exactly as before.

create table public.service_visit_otps (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  -- One row per visit — regenerating ("Resend") replaces the row's own code
  -- in place (see generate_visit_otp's upsert) rather than accumulating a
  -- history of past codes, which nothing in this build needs to keep.
  visit_id uuid not null unique references public.service_visits (id) on delete cascade,
  -- Nullable: a pure admin-override row (no real customer-confirmed code
  -- ever existed for it) is inserted with code = null — see
  -- admin_override_visit_completion.
  code text,
  generated_at timestamptz not null default now(),
  expires_at timestamptz not null default now(),
  verified_at timestamptz,
  attempts integer not null default 0,
  max_attempts integer not null default 5,
  last_attempt_at timestamptz,
  bypassed_by uuid references public.profiles (id) on delete set null,
  bypassed_reason text,
  bypassed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_visit_otps_org_id_idx on public.service_visit_otps (org_id);

-- 20260701091200_functions_triggers.sql only wires public.set_updated_at()
-- onto tables that existed AT THAT TIME (a one-off DO-block scan, not an
-- ongoing mechanism) — every table created since must add its own trigger
-- explicitly (see e.g. 20260723100000_step4_booking_model_schema.sql for
-- the same pattern), and this table's rows are genuinely mutated after
-- insert (attempts/verified_at/bypassed_* all update in place).
create trigger set_updated_at
  before update on public.service_visit_otps
  for each row execute function public.set_updated_at();

alter table public.service_visit_otps enable row level security;

-- Customer reads their own ticket's code — this is the entire point of the
-- table: the code must reach the customer's own screen so they can read it
-- aloud to the technician standing in front of them.
create policy service_visit_otps_select_customer on public.service_visit_otps
  for select using (
    exists (
      select 1 from public.service_visits v join public.service_tickets t on t.id = v.ticket_id
      where v.id = visit_id and t.customer_id = public.current_customer_id()
    )
  );

-- Staff (master/operation_admin/sales_admin — is_staff(), see
-- 20260701091200_functions_triggers.sql) get read visibility for
-- support/audit. This deliberately EXCLUDES the technician role: is_staff()
-- never includes 'technician', and no policy of any kind is granted to
-- current_technician_id() on this table — a technician must ask the
-- customer for the code, never read it off their own session. Every bit of
-- technician interaction with an OTP goes through generate_visit_otp /
-- verify_visit_otp below (both SECURITY DEFINER, neither ever returns the
-- plaintext code to its caller), never a direct table read or write.
create policy service_visit_otps_select_staff on public.service_visit_otps
  for select using (org_id = public.current_org_id() and public.is_staff());

-- No insert/update/delete policy for ANY client role on purpose — every
-- write happens inside the three SECURITY DEFINER functions below, which
-- perform their own explicit authorization checks before writing.

-- Realtime: the customer app subscribes to postgres_changes on this table
-- (CustomerBookingDetailPage) so the code appears within moments of
-- generation rather than waiting for the existing 20s ticket-detail poll —
-- same reasoning/pattern as
-- 20260704100000_technician_locations_realtime.sql for technician_locations.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'service_visit_otps'
  ) then
    alter publication supabase_realtime add table service_visit_otps;
  end if;
end $$;

-- ── generate_visit_otp: mints (or reuses) the code for a visit ──────────
create or replace function public.generate_visit_otp(
  p_org_id uuid,
  p_visit_id uuid,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_existing service_visit_otps;
  v_code text;
  v_now timestamptz := now();
  v_expires timestamptz;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'generate_visit_otp: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'generate_visit_otp: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'generate_visit_otp: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'generate_visit_otp: visit % does not belong to the calling technician', p_visit_id;
  end if;
  if v_visit.timer_end is not null then
    raise exception 'generate_visit_otp: visit % is already closed', p_visit_id;
  end if;

  select * into v_existing from public.service_visit_otps where visit_id = p_visit_id;

  -- Reuse the current code (no rotation, no attempt reset) when it's still
  -- usable and the caller isn't explicitly asking for a fresh one — calling
  -- this again every time the technician revisits the Payment step must not
  -- invalidate a code the customer already has in front of them.
  if not p_force and v_existing.id is not null and v_existing.verified_at is null and v_existing.bypassed_at is null
     and v_existing.expires_at > v_now and v_existing.attempts < v_existing.max_attempts then
    return jsonb_build_object('generated_at', v_existing.generated_at, 'expires_at', v_existing.expires_at, 'reused', true);
  end if;

  v_code := lpad(floor(random() * 10000)::int::text, 4, '0');
  v_expires := v_now + interval '15 minutes';

  insert into public.service_visit_otps (org_id, visit_id, code, generated_at, expires_at, attempts, verified_at, bypassed_by, bypassed_reason, bypassed_at)
  values (p_org_id, p_visit_id, v_code, v_now, v_expires, 0, null, null, null, null)
  on conflict (visit_id) do update set
    org_id = excluded.org_id,
    code = excluded.code,
    generated_at = excluded.generated_at,
    expires_at = excluded.expires_at,
    attempts = 0,
    verified_at = null,
    bypassed_by = null,
    bypassed_reason = null,
    bypassed_at = null;

  return jsonb_build_object('generated_at', v_now, 'expires_at', v_expires, 'reused', false);
end;
$$;

grant execute on function public.generate_visit_otp(uuid, uuid, boolean) to authenticated;

-- ── verify_visit_otp: the ONLY way a visit's timer_end gets set now ─────
-- Combines the OTP check and the actual completion transition in one
-- SECURITY DEFINER call, so the completion can never happen with an
-- unverified (or client-fabricated) code — see design decision #2 above.
create or replace function public.verify_visit_otp(
  p_org_id uuid,
  p_visit_id uuid,
  p_code text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_otp service_visit_otps;
  v_now timestamptz := now();
  v_remaining integer;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'verify_visit_otp: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'verify_visit_otp: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'verify_visit_otp: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'verify_visit_otp: visit % does not belong to the calling technician', p_visit_id;
  end if;
  if v_visit.timer_end is not null then
    raise exception 'verify_visit_otp: visit % is already closed', p_visit_id;
  end if;

  select * into v_otp from public.service_visit_otps where visit_id = p_visit_id;
  if v_otp.id is null then
    raise exception 'verify_visit_otp: otp_missing — no code has been generated for visit %', p_visit_id;
  end if;
  if v_otp.bypassed_at is not null then
    raise exception 'verify_visit_otp: otp_bypassed — visit % was already completed via admin override', p_visit_id;
  end if;
  if v_otp.expires_at <= v_now then
    raise exception 'verify_visit_otp: otp_expired — the code for visit % has expired', p_visit_id;
  end if;
  if v_otp.attempts >= v_otp.max_attempts then
    raise exception 'verify_visit_otp: otp_locked — too many incorrect attempts for visit %', p_visit_id;
  end if;

  if v_otp.code is not null and btrim(p_code) = v_otp.code then
    update public.service_visit_otps set verified_at = v_now where id = v_otp.id;
    -- The actual completion transition — timer_end only ever closes here or
    -- in admin_override_visit_completion below, never from a queued client
    -- patch anymore (see design decision #2/#6 above).
    update public.service_visits
      set timer_end = v_now, notes = coalesce(nullif(btrim(p_notes), ''), notes), otp_verified = true
      where id = p_visit_id;
    return jsonb_build_object('ok', true, 'visit_id', p_visit_id, 'timer_end', v_now);
  end if;

  update public.service_visit_otps set attempts = attempts + 1, last_attempt_at = v_now where id = v_otp.id
  returning (max_attempts - attempts) into v_remaining;

  return jsonb_build_object('ok', false, 'reason', 'incorrect', 'remaining_attempts', greatest(v_remaining, 0));
end;
$$;

grant execute on function public.verify_visit_otp(uuid, uuid, text, text) to authenticated;

-- ── admin_override_visit_completion: the one sanctioned safety valve ────
-- master/operation_admin only. Closes the visit without a correct OTP, but
-- ALWAYS requires and logs a reason, and never sets service_visits.
-- otp_verified — a bypassed completion must stay distinguishable from a
-- real customer-confirmed one in every report/query that reads that column.
create or replace function public.admin_override_visit_completion(
  p_org_id uuid,
  p_visit_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_visit service_visits;
  v_now timestamptz := now();
  v_reason text := nullif(btrim(p_reason), '');
begin
  if not public.is_ops_staff() then
    raise exception 'admin_override_visit_completion: only master or operation_admin may bypass OTP completion';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'admin_override_visit_completion: org mismatch';
  end if;
  if v_reason is null then
    raise exception 'admin_override_visit_completion: a reason is required';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'admin_override_visit_completion: visit % not found', p_visit_id;
  end if;
  if v_visit.timer_end is not null then
    raise exception 'admin_override_visit_completion: visit % is already closed', p_visit_id;
  end if;

  insert into public.service_visit_otps (org_id, visit_id, code, generated_at, expires_at, attempts, bypassed_by, bypassed_reason, bypassed_at)
  values (p_org_id, p_visit_id, null, v_now, v_now, 0, auth.uid(), v_reason, v_now)
  on conflict (visit_id) do update set
    bypassed_by = excluded.bypassed_by,
    bypassed_reason = excluded.bypassed_reason,
    bypassed_at = excluded.bypassed_at;

  update public.service_visits set timer_end = v_now where id = p_visit_id;

  return jsonb_build_object('ok', true, 'visit_id', p_visit_id, 'timer_end', v_now, 'bypassed', true);
end;
$$;

grant execute on function public.admin_override_visit_completion(uuid, uuid, text) to authenticated;
