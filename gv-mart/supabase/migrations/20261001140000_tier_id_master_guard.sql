-- technicians_write_ops lets operation_admin edit technician rows, but a
-- tier decides pay: only master may change tier_id (manual override or via
-- approve_tier_promotion, which runs as the master's session). Service-role /
-- migration writes (auth.uid() is null) are unaffected.
create or replace function public.guard_technician_tier_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.tier_id is distinct from old.tier_id and auth.uid() is not null and not public.is_master() then
    raise exception 'Only master can change a technician''s tier';
  end if;
  return new;
end;
$$;

create trigger guard_technician_tier_change before update of tier_id on public.technicians
  for each row execute function public.guard_technician_tier_change();

-- Tier definitions set pay: audit them like the other master-data tables.
create trigger audit_technician_tiers after insert or update or delete on public.technician_tiers
  for each row execute function public.audit_master_change();
