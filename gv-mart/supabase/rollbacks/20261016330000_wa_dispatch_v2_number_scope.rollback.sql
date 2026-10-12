-- Rollback for 20261016330000: restores the normaliser exactly as 20261016310000 defined it (flag only, organisation-wide),
-- then removes the helper and the two columns. Run only with wa_dispatch_v2_enabled OFF, or the normaliser change would
-- widen v2 from the listed numbers to the whole organisation.
create or replace function public._trg_wa_outbox_pending_normalise()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.direction = 'outbound'
     and new.status = 'sent'
     and new.wa_message_id is null
     and new.ref_type in ('service_ticket', 'service_visit', 'invoice', 'purchase_quote_request')
     and exists (select 1 from public.settings s where s.org_id = new.org_id and s.wa_dispatch_v2_enabled)
  then
    new.status := 'pending';
  end if;
  return new;
end;
$$;

drop function if exists public.wa_dispatch_v2_applies(uuid, text);
alter table public.settings drop constraint if exists settings_wa_dispatch_v2_numbers_check;
alter table public.settings drop constraint if exists settings_wa_dispatch_v2_scope_check;
alter table public.settings drop column if exists wa_dispatch_v2_numbers, drop column if exists wa_dispatch_v2_scope;
