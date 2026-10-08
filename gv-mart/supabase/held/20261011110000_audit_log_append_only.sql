-- HELD (review F-02 / F-03 / F-05 / F-13): make audit_log genuinely append-only, as ONE unit with the
-- staff-auth.ts change that stops UPDATEing audit rows (start row + separate completion row).
--
--   * BEFORE UPDATE OR DELETE trigger raises. Two exceptions, both narrow:
--       - the FK action "actor_id ON DELETE SET NULL" when the actor's profile no longer exists and nothing
--         else changed (so deleting a profile keeps working; new staff rows also snapshot actor_name in "after");
--       - purge_test_organisation(), below, which sets a transaction-local flag AND must run as the table owner.
--   * BEFORE TRUNCATE trigger raises.
--   * UPDATE / DELETE / TRUNCATE are revoked from anon, authenticated, service_role (and PUBLIC).
--
-- CONSEQUENCE (deliberate): audit_log rows cascade from organisations (org_id ON DELETE CASCADE). A real
-- organisation that has audit rows can no longer be deleted, by anyone, without a DBA first disabling the
-- trigger. Test organisations are removed only through purge_test_organisation(), which refuses any
-- organisation whose name does not start with "__TEST_" and is executable only by the owner role.

create or replace function public._trg_audit_log_append_only()
returns trigger
language plpgsql
set search_path = public   -- SECURITY INVOKER on purpose: current_user must be the calling role
as $$
begin
  if tg_op = 'TRUNCATE' then
    raise exception 'audit_log is append-only: TRUNCATE is not allowed';
  end if;

  -- test-organisation purge: owner role only, flag set by purge_test_organisation() in this transaction
  if tg_op = 'DELETE'
     and current_user = 'postgres'
     and coalesce(current_setting('app.audit_purge_ok', true), '') = '1' then
    return old;
  end if;

  -- profile deletion: FK "actor_id ON DELETE SET NULL" is the only UPDATE ever allowed
  if tg_op = 'UPDATE'
     and old.actor_id is not null and new.actor_id is null
     and not exists (select 1 from public.profiles where id = old.actor_id)
     and (to_jsonb(new) - 'actor_id' - 'updated_at') = (to_jsonb(old) - 'actor_id' - 'updated_at') then
    return new;
  end if;

  raise exception 'audit_log is append-only (% refused)', tg_op;
end;
$$;

drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only
  before update or delete on public.audit_log
  for each row execute function public._trg_audit_log_append_only();

drop trigger if exists audit_log_no_truncate on public.audit_log;
create trigger audit_log_no_truncate
  before truncate on public.audit_log
  for each statement execute function public._trg_audit_log_append_only();

revoke update, delete, truncate on public.audit_log from public, anon, authenticated, service_role;
revoke all on function public._trg_audit_log_append_only() from public, anon, authenticated;

-- ── test cleanup route ──────────────────────────────────────────────────
-- Replaces "delete from audit_log where org_id = <test org>" in throwaway-data cleanup. It refuses any
-- organisation whose name does not start with __TEST_ and runs only as the owner role (no other role has EXECUTE).
-- It removes the rows that must go first (leads and their cascades, lead_outcomes, lead_sources, the audit rows) and then
-- the organisation. The test script still deletes its own other rows (customers, tickets, users ...) beforehand, as before.
create or replace function public.purge_test_organisation(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  select name into v_name from public.organizations where id = p_org;
  if v_name is null then
    raise exception 'purge_test_organisation: organisation not found';
  end if;
  if v_name not like '\_\_TEST\_%' escape '\' then
    raise exception 'purge_test_organisation: refused, "%" is not a __TEST_ organisation', v_name;
  end if;

  perform set_config('app.audit_purge_ok', '1', true);
  delete from public.notifications where org_id = p_org;
  delete from public.audit_log where org_id = p_org;
  delete from public.leads where org_id = p_org;            -- cascades followups, stage log, assignments, activities
  delete from public.lead_outcomes where org_id = p_org;
  delete from public.lead_sources where org_id = p_org;
  delete from public.organizations where id = p_org;        -- cascades the rest; audit rows already gone
  perform set_config('app.audit_purge_ok', '', true);
end;
$$;

revoke all on function public.purge_test_organisation(uuid) from public, anon, authenticated, service_role;
