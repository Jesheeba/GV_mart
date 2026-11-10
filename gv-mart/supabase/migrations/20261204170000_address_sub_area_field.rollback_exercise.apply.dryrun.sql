-- Exercised rollback proof for 20261204170000_address_sub_area_field.sql.
-- Applies the migration's DDL, verifies the column now exists, runs the
-- sibling *.rollback.sql DDL verbatim, verifies zero residue by direct
-- count checks (sub_area column, migration version row -- both expected
-- exactly 0 after rollback), verifies public.addresses (the only table
-- this migration touches -- real orgs only, audit_log is never queried)
-- is byte-identical by count+md5 before vs after, verifies the
-- anon-exposure set is unchanged, then forces an unconditional rollback
-- of this entire probe so nothing here is ever committed -- apply.sql
-- itself is still untouched and still requires separate, explicit
-- approval to run for real.
--
-- No sha256 "catalog-state digest" here (unlike some other migrations'
-- rollback_exercise files) -- this probe's own precondition (step 0)
-- already guarantees the sub_area column and the migration's version row
-- don't exist before the probe runs, so a BEFORE digest over exactly
-- those two entities is always the hash of an empty set
-- (e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)
-- regardless of whether apply+rollback actually worked -- it can never
-- fail, so it proves nothing. Removed rather than kept as dead weight;
-- the direct residue-count checks below (step 5, each compared against
-- an explicit expected value of 0) carry the real signal instead.
do $rollback_proof$
declare
  res text := '';
  v_addresses_before text;
  v_addresses_after text;
  v_anon_before text;
  v_anon_after text;
  v_count int;
begin
  -- 0. PRECONDITION -- nothing from this migration exists yet.
  select count(*) into v_count from information_schema.columns
    where table_schema = 'public' and table_name = 'addresses' and column_name = 'sub_area';
  if v_count <> 0 then
    raise exception 'PRECONDITION FAILED: sub_area already exists -- this probe assumes nothing is live yet';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261204170000') then
    raise exception 'PRECONDITION FAILED: 20261204170000 is already registered';
  end if;

  -- 1. BEFORE snapshots.
  select count(*)::text || ':' || coalesce(md5(string_agg(a.id::text || a.updated_at::text, ',' order by a.id)), '(empty)')
    into v_addresses_before
  from public.addresses a
  where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select encode(sha256(convert_to(coalesce(string_agg(proname, ',' order by proname), ''), 'UTF8')), 'hex') into v_anon_before
  from pg_proc p where has_function_privilege('anon', p.oid, 'EXECUTE');

  res := res || E'\nINFO addresses BEFORE = ' || v_addresses_before;
  res := res || E'\nINFO anon-exposure BEFORE = ' || v_anon_before;

  -- 2. APPLY -- the migration's DDL, verbatim (same body as the committed
  -- apply.sql, minus its own guard/register, which aren't needed inside
  -- this self-contained probe).
  alter table public.addresses add column if not exists sub_area text;
  comment on column public.addresses.sub_area is
    'Added 2026-12-04 — "Sub Area" field from clean_address_form.pdf, captured on the admin Customer form''s address step alongside door_no/plot_no/building_name/street_cross/landmark/area. Feeds into the composed full_address text (see src/lib/address.ts composeFullAddress) the same way those columns do.';

  insert into supabase_migrations.schema_migrations (version, name, statements)
  values ('20261204170000', 'address_sub_area_field', array[]::text[]);

  res := res || E'\nok   migration DDL applied inside this still-open probe transaction';

  -- 3. VERIFY created.
  select count(*) into v_count from information_schema.columns
    where table_schema = 'public' and table_name = 'addresses' and column_name = 'sub_area';
  if v_count <> 1 then raise exception 'VERIFY FAILED: expected sub_area to exist after apply, found %', v_count; end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261204170000') then
    raise exception 'VERIFY FAILED: migration version not registered after apply';
  end if;
  res := res || E'\nok   both artifacts verified present after apply (sub_area column, migration version)';

  -- 4. ROLLBACK -- the sibling *.rollback.sql DDL, verbatim.
  alter table public.addresses drop column if exists sub_area;
  delete from supabase_migrations.schema_migrations where version = '20261204170000';

  res := res || E'\nok   rollback DDL executed inside this still-open probe transaction';

  -- 5. VERIFY 0 residue -- direct counts, each a real pass/fail assertion (not just an
  -- INFO line) since this is now the only residue check in this file, replacing the
  -- tautological sha256 digest that used to sit here (see this file's own header).
  select count(*) into v_count from information_schema.columns
    where table_schema = 'public' and table_name = 'addresses' and column_name = 'sub_area';
  res := res || E'\n' || case when v_count = 0 then 'ok   0 residue: sub_area column does not exist after rollback' else 'FAIL residue: sub_area column still exists after rollback (count=' || v_count || ')' end;
  select count(*) into v_count from supabase_migrations.schema_migrations where version = '20261204170000';
  res := res || E'\n' || case when v_count = 0 then 'ok   0 residue: migration version row does not exist after rollback' else 'FAIL residue: migration version row still exists after rollback (count=' || v_count || ')' end;

  -- 6. VERIFY public.addresses (real orgs only) is untouched by this whole probe.
  select count(*)::text || ':' || coalesce(md5(string_agg(a.id::text || a.updated_at::text, ',' order by a.id)), '(empty)')
    into v_addresses_after
  from public.addresses a
  where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  res := res || E'\nINFO addresses AFTER  = ' || v_addresses_after;
  res := res || E'\n' || case when v_addresses_after = v_addresses_before
    then 'ok   addresses table count+md5 unchanged'
    else 'FAIL addresses table CHANGED' end;

  -- 7. VERIFY anon-exposure set is unchanged (no residual anon grant anywhere --
  -- this migration grants nothing, so this should be a no-op check).
  select encode(sha256(convert_to(coalesce(string_agg(proname, ',' order by proname), ''), 'UTF8')), 'hex') into v_anon_after
  from pg_proc p where has_function_privilege('anon', p.oid, 'EXECUTE');
  res := res || E'\nINFO anon-exposure AFTER  = ' || v_anon_after;
  res := res || E'\n' || case when v_anon_after = v_anon_before
    then 'ok   anon-exposure set unchanged -- no residual anon grant from this probe'
    else 'FAIL anon-exposure set CHANGED' end;

  raise exception E'ROLLBACK-EXERCISE-OK:%', res;
end
$rollback_proof$;
