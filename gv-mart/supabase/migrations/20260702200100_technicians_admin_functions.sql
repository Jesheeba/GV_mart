-- Phase 10 (Technicians admin) — RPCs.
--
-- ADM-17 "handover form with quantities" needs to insert one
-- `spare_handovers` row + N `spare_handover_items` rows atomically. Both
-- tables already grant `is_ops_staff()` full write access under RLS
-- (20260701091300_rls.sql: spare_handovers_write_ops /
-- spare_handover_items_write_ops), so this is SECURITY INVOKER — it relies
-- entirely on RLS for authorization, same shape as confirm_spare_handover /
-- generate_enquiry_lead in 20260702120000_technician_phase7_functions.sql.
-- Wrapping it as one RPC just keeps "header + lines" atomic instead of two
-- round trips that could leave an orphaned header on partial failure.

create or replace function public.create_spare_handover(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date,
  p_items jsonb -- [{spare_id, qty_given}, ...]
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_handover_id uuid;
  v_item record;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_spare_handover: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_spare_handover: caller is not ops staff';
  end if;

  insert into public.spare_handovers (org_id, technician_id, date, status)
  values (p_org_id, p_technician_id, p_date, 'pending')
  on conflict do nothing
  returning id into v_handover_id;

  -- date has no unique constraint (a technician can have more than one
  -- handover per day in principle), so on_conflict above never actually
  -- fires today — kept defensive in case a future migration adds one.
  if v_handover_id is null then
    insert into public.spare_handovers (org_id, technician_id, date, status)
    values (p_org_id, p_technician_id, p_date, 'pending')
    returning id into v_handover_id;
  end if;

  if p_items is not null and jsonb_array_length(p_items) > 0 then
    for v_item in select * from jsonb_to_recordset(p_items) as x(spare_id uuid, qty_given integer)
    loop
      if v_item.qty_given is null or v_item.qty_given <= 0 then
        continue;
      end if;
      insert into public.spare_handover_items (org_id, handover_id, spare_id, qty_given)
      values (p_org_id, v_handover_id, v_item.spare_id, v_item.qty_given);
    end loop;
  end if;

  return v_handover_id;
end;
$$;

grant execute on function public.create_spare_handover(uuid, uuid, date, jsonb) to authenticated;

-- Admin counter-signs an already-technician-signed (or still-pending)
-- handover. `spare_handovers_write_ops` already allows a plain UPDATE, but
-- wrapping keeps the "set admin_sign_url, confirm if both signatures are
-- now present" rule in one place shared with the technician-side
-- confirm_spare_handover RPC's semantics.
create or replace function public.admin_sign_spare_handover(
  p_handover_id uuid,
  p_admin_sign_url text
)
returns void
language plpgsql
security invoker
as $$
declare
  v_row public.spare_handovers;
begin
  if not public.is_ops_staff() then
    raise exception 'admin_sign_spare_handover: caller is not ops staff';
  end if;
  if nullif(p_admin_sign_url, '') is null then
    raise exception 'admin_sign_spare_handover: signature is required';
  end if;

  select * into v_row from public.spare_handovers where id = p_handover_id and org_id = public.current_org_id();
  if v_row is null then
    raise exception 'admin_sign_spare_handover: handover % not found', p_handover_id;
  end if;

  update public.spare_handovers
    set admin_sign_url = p_admin_sign_url,
        status = case when tech_sign_url is not null then 'confirmed' else status end
    where id = p_handover_id;
end;
$$;

grant execute on function public.admin_sign_spare_handover(uuid, text) to authenticated;
