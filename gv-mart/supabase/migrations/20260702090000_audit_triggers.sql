-- Phase 4 (ADM-30): "each [master] change writes audit_log."
--
-- Implemented as a trigger rather than requiring every service function to
-- remember an extra RPC call — automatic, can't be bypassed by a caller
-- forgetting a step. SECURITY DEFINER because audit_log has no client-side
-- INSERT policy (Phase 1: writes are system-only, by design).
create or replace function public.audit_master_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_row_id uuid;
begin
  if TG_OP = 'DELETE' then
    v_org_id := old.org_id;
    v_row_id := old.id;
  else
    v_org_id := new.org_id;
    v_row_id := new.id;
  end if;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_org_id,
    auth.uid(),
    TG_OP,
    TG_TABLE_NAME,
    v_row_id,
    case when TG_OP in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when TG_OP in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger audit_brands after insert or update or delete on brands for each row execute function public.audit_master_change();
create trigger audit_models after insert or update or delete on models for each row execute function public.audit_master_change();
create trigger audit_products after insert or update or delete on products for each row execute function public.audit_master_change();
create trigger audit_spares after insert or update or delete on spares for each row execute function public.audit_master_change();
create trigger audit_gifts after insert or update or delete on gifts for each row execute function public.audit_master_change();
create trigger audit_amc_plans after insert or update or delete on amc_plans for each row execute function public.audit_master_change();
create trigger audit_incentive_rules after insert or update or delete on incentive_rules for each row execute function public.audit_master_change();
create trigger audit_settings after insert or update or delete on settings for each row execute function public.audit_master_change();
