-- HELD (review F-01): after a staff password reset, evict anyone already signed in with the old password.
-- admin-reset-staff-password calls this through the service role (supabase-js admin.rpc) after
-- updateUserById succeeds. Deleting auth.sessions also removes (by FK cascade, current GoTrue) the session's
-- refresh tokens; the explicit refresh_tokens delete covers older schemas that key tokens by user_id only.
--
-- Nothing else may call it: EXECUTE is revoked from PUBLIC/anon/authenticated and granted to service_role only.
-- SECURITY DEFINER with an EMPTY search_path and fully qualified names, so no object can be shadowed.

create or replace function public.revoke_user_sessions(p_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sessions integer;
begin
  if p_user_id is null then
    raise exception 'revoke_user_sessions: user id is required';
  end if;

  delete from auth.refresh_tokens where user_id::text = p_user_id::text;
  delete from auth.sessions where user_id = p_user_id;
  get diagnostics v_sessions = row_count;
  return v_sessions;
end;
$$;

revoke all on function public.revoke_user_sessions(uuid) from public, anon, authenticated;
grant execute on function public.revoke_user_sessions(uuid) to service_role;
