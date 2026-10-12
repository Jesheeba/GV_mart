-- WhatsApp dispatcher v2, step 4: a per-number scope, so v2 can be tried on the test number only while every other
-- recipient of the organisation keeps today's legacy behaviour. Additive and idempotent. NOT applied until approved.
--
--   settings.wa_dispatch_v2_enabled   (existing) master switch, default false
--   settings.wa_dispatch_v2_scope     'numbers' (default) | 'org'
--   settings.wa_dispatch_v2_numbers   bare 10-digit numbers, default empty
--
-- v2 applies to a recipient only when the switch is ON and either scope = 'org' (an explicit, separate choice) or the
-- recipient's last ten digits are in the list. An EMPTY list means nobody: turning the switch on cannot, by itself, turn
-- v2 on for the whole organisation. Master-only to change (the existing settings_write_master policy).
--
-- The Edge Functions apply the same rule (wa-dispatch-scope.ts) in sendMessage, the milestone claim loop and the failed-send
-- retry pass. In the database the only place is the pending-normalisation trigger, replaced below: it now turns an
-- optimistic 'sent' into 'pending' only for recipients v2 applies to.

alter table public.settings
  add column if not exists wa_dispatch_v2_scope text not null default 'numbers',
  add column if not exists wa_dispatch_v2_numbers text[] not null default '{}'::text[];

alter table public.settings drop constraint if exists settings_wa_dispatch_v2_scope_check;
alter table public.settings
  add constraint settings_wa_dispatch_v2_scope_check check (wa_dispatch_v2_scope in ('numbers', 'org'));

alter table public.settings drop constraint if exists settings_wa_dispatch_v2_numbers_check;
alter table public.settings
  add constraint settings_wa_dispatch_v2_numbers_check check (public._wa_numbers_valid(wa_dispatch_v2_numbers));

-- the single rule, in SQL
create or replace function public.wa_dispatch_v2_applies(p_org uuid, p_to text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select s.wa_dispatch_v2_enabled
            and (s.wa_dispatch_v2_scope = 'org'
                 or (right(regexp_replace(coalesce(p_to, ''), '[^0-9]', '', 'g'), 10) ~ '^[0-9]{10}$'
                     and right(regexp_replace(coalesce(p_to, ''), '[^0-9]', '', 'g'), 10) = any (s.wa_dispatch_v2_numbers)))
       from public.settings s
      where s.org_id = p_org),
    false)
$$;
revoke all on function public.wa_dispatch_v2_applies(uuid, text) from public, anon, authenticated;
grant execute on function public.wa_dispatch_v2_applies(uuid, text) to service_role;

-- the normaliser: same rule as before (outbound, 'sent', no WhatsApp id, a dispatched ref type) AND v2 applies to the recipient
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
     and public.wa_dispatch_v2_applies(new.org_id, new.to_mobile)
  then
    new.status := 'pending';
  end if;
  return new;
end;
$$;
