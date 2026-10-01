-- The tier-promotion earning window must restart whenever a technician's tier
-- changes, however it changed: approval, a master's manual override from the
-- edit form, a demotion, or a service-role/SQL fix. 20261001150000 keyed the
-- reset off tier_promotion_history, which manual overrides never write. The
-- reset point now lives on the technician row itself.
--
-- null = tier has never changed since the technician was created, so the
-- window falls back to created_at as before.
alter table public.technicians add column tier_changed_at timestamptz;

-- Backfill BEFORE the trigger exists (it would otherwise overwrite this).
update public.technicians t
set tier_changed_at = h.last_promoted
from (
  select technician_id, max(promoted_at) as last_promoted
  from public.tier_promotion_history
  group by technician_id
) h
where h.technician_id = t.id;

-- tier_changed_at is system-maintained: it is stamped only by an actual
-- tier_id change, and no client write (ops admins can update technician rows)
-- can set or clear it directly.
create or replace function public.stamp_technician_tier_changed_at()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.tier_changed_at := null;
  elsif new.tier_id is distinct from old.tier_id then
    new.tier_changed_at := now();
  else
    new.tier_changed_at := old.tier_changed_at;
  end if;
  return new;
end;
$$;

create trigger stamp_technician_tier_changed_at before insert or update on public.technicians
  for each row execute function public.stamp_technician_tier_changed_at();

-- Window start: later of creation, N months back, and the last tier change.
-- Same signature as before, so the detector and progress RPC pick it up as is.
create or replace function public._tier_window_start(
  p_technician_id uuid,
  p_created_at timestamptz,
  p_months int
)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    p_created_at,
    now() - make_interval(months => p_months),
    coalesce((select t.tier_changed_at from public.technicians t where t.id = p_technician_id), '-infinity'::timestamptz)
  );
$$;
