-- Rollback for 20261010140000_drop_generate_enquiry_lead_6arg.sql: recreate the 6-argument overload
-- exactly as it was (same body, SECURITY INVOKER) with the ACL that preceded the drop
-- (authenticated + service_role; no PUBLIC, no anon, after 20261010130000).
create or replace function public.generate_enquiry_lead(p_org_id uuid, p_customer_id uuid, p_name text, p_mobile text, p_enquiry_type public.enquiry_type, p_note text)
 returns uuid
 language plpgsql
as $function$
declare
  v_tech_id uuid;
  v_lead_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'generate_enquiry_lead: caller is not a technician';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'generate_enquiry_lead: name is required';
  end if;

  insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, status, owner_id)
  values (p_org_id, p_customer_id, p_name, nullif(p_mobile, ''), 'field', p_enquiry_type, 'new', v_tech_id)
  returning id into v_lead_id;

  if p_note is not null and btrim(p_note) <> '' then
    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'enquiry_captured', p_note);
  end if;

  return v_lead_id;
end;
$function$;

revoke all on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text) from public, anon;
grant execute on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text) to authenticated;
