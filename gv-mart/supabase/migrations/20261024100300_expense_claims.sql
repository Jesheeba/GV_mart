-- Monthly Expenses spec, Unit 3 — petrol/maintenance bill submission and
-- verification (§1.4/§3.3, and the owner's revision superseding §1.3 — the
-- bill is for validation, and once verified the admin's entered amount IS
-- the payment, for petrol exactly as for maintenance). `verified_amount is
-- null` is the gate: a row with no verified_amount is invisible to salary
-- and the report through any code path, because Units 5-7 only ever read
-- verified rows. There is no separate rejected state — verifying at zero
-- behaves as a rejection, the row and photo survive, `reason` records why.
-- Both claim_types share this exact mechanism; see Unit 6 for how the
-- kilometres x rate figure is kept as a reference the admin checks the bill
-- against, never as the payment formula.
--
-- Write path matches this codebase's `payment_proofs` convention
-- (20260807092000_payment_proofs.sql): no direct client insert/update grant
-- on the table at all — the technician's identity and the claim's shape are
-- resolved and validated entirely inside the two RPCs below, never trusted
-- from client-supplied columns.

create table public.expense_claims (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  period date not null,
  claim_type text not null check (claim_type in ('petrol', 'maintenance')),
  submitted_amount numeric(12, 2) not null check (submitted_amount >= 0),
  bill_photo_path text not null,
  submitted_at timestamptz not null default now(),
  verified_amount numeric(12, 2) check (verified_amount >= 0),
  verified_by uuid references public.profiles (id) on delete set null,
  verified_at timestamptz,
  reason text,
  -- The whole audit trail: a verified figure that differs from what was
  -- submitted must carry a written reason, enforced here so it can never be
  -- bypassed by skipping a frontend form.
  constraint expense_claims_reason_required_if_adjusted check (
    verified_amount is null or verified_amount = submitted_amount or reason is not null
  )
);

create index expense_claims_org_id_idx on public.expense_claims (org_id);
create index expense_claims_technician_id_idx on public.expense_claims (technician_id, period);
create index expense_claims_period_idx on public.expense_claims (org_id, period) where verified_amount is not null;

alter table public.expense_claims enable row level security;

create policy expense_claims_select_staff on public.expense_claims
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy expense_claims_select_own on public.expense_claims
  for select using (technician_id = public.current_technician_id());
-- No insert/update/delete policy on the table — every write goes through
-- submit_expense_claim / verify_expense_claim below.

create trigger audit_expense_claims after insert or update or delete on public.expense_claims
  for each row execute function public.audit_master_change();

-- ── Storage: private bucket, technician-scoped path ───────────────────────
-- Same 5MB/image-only limits as every other photo bucket in this codebase.
-- Path shape `${orgId}/${technicianId}/${uuid}.${ext}` lets the storage
-- policy scope access per-technician without a lookup table, same idea as
-- payment-proofs' `current_technician_id() is not null` but tightened one
-- level further so a technician can't even upload into another technician's
-- folder, let alone read one by guessing a key.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-claim-photos', 'expense-claim-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy expense_claim_photos_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'expense-claim-photos'
  and public.current_technician_id() is not null
  and (storage.foldername(name))[2] = public.current_technician_id()::text
);
create policy expense_claim_photos_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'expense-claim-photos'
  and (
    public.is_ops_staff()
    or (storage.foldername(name))[2] = public.current_technician_id()::text
  )
);
-- No delete policy on the bucket or the table: proofs are permanent, same
-- posture as payment-proofs/technician-documents.

-- ── submit_expense_claim: technician uploads, identity resolved server-side ─
create or replace function public.submit_expense_claim(
  p_org_id uuid,
  p_claim_type text,
  p_submitted_amount numeric,
  p_bill_photo_path text,
  p_period date default current_date
)
returns public.expense_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_claim public.expense_claims;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'submit_expense_claim: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_expense_claim: org mismatch';
  end if;
  if p_claim_type not in ('petrol', 'maintenance') then
    raise exception 'submit_expense_claim: invalid claim_type %', p_claim_type;
  end if;
  if p_submitted_amount < 0 then
    raise exception 'submit_expense_claim: submitted_amount must be non-negative';
  end if;
  if nullif(btrim(p_bill_photo_path), '') is null then
    raise exception 'submit_expense_claim: bill_photo_path is required';
  end if;

  insert into public.expense_claims (org_id, technician_id, period, claim_type, submitted_amount, bill_photo_path)
  values (p_org_id, v_tech_id, date_trunc('month', p_period)::date, p_claim_type, p_submitted_amount, p_bill_photo_path)
  returning * into v_claim;

  return v_claim;
end;
$$;

grant execute on function public.submit_expense_claim(uuid, text, numeric, text, date) to authenticated;
revoke execute on function public.submit_expense_claim(uuid, text, numeric, text, date) from anon;

-- ── verify_expense_claim: master/operation_admin sets the figure that pays ──
-- `verified_amount = 0` with a reason IS the "rejected" state (§1.4) — no
-- separate status column, nothing is deleted. Re-running this on an
-- already-verified claim is allowed (an admin correcting their own earlier
-- verification), and still goes through the same reason-required check.
create or replace function public.verify_expense_claim(
  p_claim_id uuid,
  p_verified_amount numeric,
  p_reason text default null
)
returns public.expense_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claim public.expense_claims;
begin
  if not public.is_ops_staff() then
    raise exception 'verify_expense_claim: master or operation_admin role required';
  end if;
  select * into v_claim from public.expense_claims where id = p_claim_id and org_id = public.current_org_id();
  if v_claim.id is null then
    raise exception 'verify_expense_claim: claim % not found', p_claim_id;
  end if;
  if p_verified_amount is null or p_verified_amount < 0 then
    raise exception 'verify_expense_claim: verified_amount must be a non-negative number';
  end if;
  if p_verified_amount is distinct from v_claim.submitted_amount and nullif(btrim(p_reason), '') is null then
    raise exception 'verify_expense_claim: reason is required when the verified amount differs from the submitted amount';
  end if;

  update public.expense_claims
  set verified_amount = p_verified_amount,
      verified_by = auth.uid(),
      verified_at = now(),
      reason = nullif(btrim(p_reason), '')
  where id = p_claim_id
  returning * into v_claim;

  return v_claim;
end;
$$;

grant execute on function public.verify_expense_claim(uuid, numeric, text) to authenticated;
revoke execute on function public.verify_expense_claim(uuid, numeric, text) from anon;

-- Monthly verified totals per technician, by claim type — the figures Units
-- 6/7 read. Unverified rows are excluded by construction (verified_amount is
-- the gate).
create or replace function public.technician_expense_claims_total(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date,
  p_claim_type text
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(verified_amount), 0)
  from public.expense_claims
  where org_id = p_org_id
    and technician_id = p_technician_id
    and claim_type = p_claim_type
    and period = date_trunc('month', p_period)::date
    and verified_amount is not null;
$$;

grant execute on function public.technician_expense_claims_total(uuid, uuid, date, text) to authenticated;
revoke execute on function public.technician_expense_claims_total(uuid, uuid, date, text) from anon;
