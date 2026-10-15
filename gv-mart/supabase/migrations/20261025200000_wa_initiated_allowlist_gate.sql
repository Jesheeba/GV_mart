-- Design B: gate on INITIATED WhatsApp sends only.
--
-- settings.wa_initiated_allowlist_only (default TRUE): while true, a message the system starts on its own (milestone
-- dispatch, scheduled tasks, failed-send retries) may only go to a number on settings.wa_test_allowed_numbers. Replies to
-- an inbound message are not affected. Setting the column to FALSE is the go-live switch.
--
-- The column is read by evaluateInitiatedGate (supabase/functions/_shared/wa-test-mode.ts), which fails closed on any
-- doubt, including this column not existing. Apply this migration BEFORE deploying the functions that read it.
--
-- Additive only: one column, one trigger function, one trigger. No existing function, policy or grant is changed.

alter table public.settings
  add column if not exists wa_initiated_allowlist_only boolean not null default true;

comment on column public.settings.wa_initiated_allowlist_only is
  'true: initiated WhatsApp sends (milestone dispatch, scheduled tasks, retries) go only to settings.wa_test_allowed_numbers. false is the go-live switch.';

-- Same protection as the test-mode columns (_trg_settings_wa_test_guard): only a master can change it from the app.
create or replace function public._trg_settings_wa_initiated_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and new.wa_initiated_allowlist_only is distinct from old.wa_initiated_allowlist_only
     and not coalesce(public.is_master(), false) then
    raise exception 'settings: only a master can change the initiated-send gate';
  end if;
  return new;
end;
$$;

-- This project auto-grants EXECUTE on new public functions to anon/authenticated; a trigger function must not be callable.
revoke all on function public._trg_settings_wa_initiated_guard() from public, anon, authenticated;

drop trigger if exists settings_wa_initiated_guard on public.settings;
create trigger settings_wa_initiated_guard
  before update on public.settings
  for each row
  execute function public._trg_settings_wa_initiated_guard();
