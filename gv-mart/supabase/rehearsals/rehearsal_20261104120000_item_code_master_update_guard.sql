-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): item_code master-only update guard (P4 part 3):
-- 20261104100000_product_item_code.sql then 20261104110000_invoice_quotation_item_code_snapshot.sql then
-- 20261104120000_item_code_master_update_guard.sql + its tests
--
-- LOCK WARNING: the embedded test file's G-block runs `alter table public.products disable row level security`
-- and, later, `alter table public.products enable row level security`, inside this same rolled-back transaction.
-- Each ALTER TABLE takes an ACCESS EXCLUSIVE lock on products, and Postgres holds that lock for the rest of the
-- transaction regardless of the later re-enable — not just for the instant of the statement. From that first
-- ALTER TABLE until this whole DO block's final RAISE EXCEPTION rolls everything back, every other session's
-- read or write against products (the live app included, if this is ever run against a project taking real
-- traffic) blocks waiting for that lock. This is deliberate (see the test file's own header: it is the only way
-- to isolate the new trigger's own guard from products_write_master's RLS), but it is real production impact for
-- however long the rest of this rehearsal takes to run, not a free isolation technique — run it at a quiet moment.
-- A lock_timeout of 5s is set as the very first statement in this DO block (review fix, this round): if that
-- ACCESS EXCLUSIVE lock is ever contended (another session already holds a conflicting lock on products when
-- this rehearsal tries to take it), this rehearsal fails fast with a lock_timeout error instead of queuing
-- indefinitely behind it and, in turn, becoming the thing everyone else queues behind.
--
-- This run changes no real data: every statement below runs inside one rolled-back transaction and the embedded
-- test file's own RESULTS exception is caught (not let propagate) so this wrapper can append the real-organisation
-- fingerprint comparison below to it; this whole DO block still always ends in ONE unconditional RAISE EXCEPTION,
-- so nothing is ever committed. One request, one DO block. It: (1) sets lock_timeout to 5s, (2) refuses to run
-- before 18:00 IST (the clock is read from clock_timestamp()), (3) recomputes the sha256 of every embedded file
-- and refuses on any mismatch with the pinned value, (4) recomputes a RELATIVE fingerprint of the real
-- organisation (its id + name, picking the earliest non-__TEST-named row — not an exact snapshot of the whole
-- table, so it survives new test orgs being added later) and refuses on any mismatch, confirming this rehearsal
-- is pointed at the real project, (5) takes a BEFORE fingerprint of that same real organisation's customers,
-- service_tickets, invoices and products (count + an md5 checksum of their ids each, review fix this round — the
-- new trigger only ever touches throwaway __TEST_ rows, so these four real-org tables must read back byte-for-byte
-- identical at every checkpoint below; this is an independent cross-check on top of "the whole transaction rolls
-- back regardless", not a substitute for it), (6) executes the three migrations in order (20261104100000, then
-- 20261104110000, then 20261104120000), (7) takes the SAME fingerprint again immediately after the three
-- migrations and refuses on any difference (migrations are pure DDL — new column/trigger/revoke — touching no
-- existing row in any of those four tables, so this must be identical by construction), (8) runs the test file
-- in a nested BEGIN/EXCEPTION, catching its own terminal RESULTS/other exception into a variable rather than
-- letting it end the DO block, (9) takes the fingerprint a THIRD time, after the test file ran, and refuses on
-- any difference (the test file only ever creates/mutates its own throwaway __TEST_ organisation), (10) always
-- ends in ONE unconditional RAISE EXCEPTION carrying the test file's own RESULTS text with the two fingerprint
-- comparisons appended, so nothing is ever committed.
-- supabase/migrations/20261104100000_product_item_code.sql and 20261104110000_invoice_quotation_item_code_snapshot.sql
-- are embedded here a SECOND time (both were already typed in full in the first two wrappers of this package)
-- because nothing persists between separate rehearsal runs — this test file needs the columns and trigger those
-- migrations add, so this wrapper must apply all three, in order, inside the same rolled-back transaction, every
-- time. This run changes no real data, same as the earlier two P4 wrappers.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with
-- test code outside this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure
-- and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c  gv-mart/supabase/migrations/20261104100000_product_item_code.sql
--   4acedd9092e5fc40009709dcda9f65405c29c314913341ff32e24e6f25678a8d  gv-mart/supabase/migrations/20261104110000_invoice_quotation_item_code_snapshot.sql
--   b5fac0cfb851f31735e1f02cec04e4ce22aab9e7a8176c51c15353ce6be66f4f  gv-mart/supabase/migrations/20261104120000_item_code_master_update_guard.sql
--   8b82114daf5e0009ec3a98db6a77e164febec8df1fcc4c4695e8b7240312ef36  gv-mart/supabase/tests/item_code_master_update_guard.test.sql
-- Pinned (relative fingerprint of the real organisation; read-only, confirmed against the live project):
--   6f891cf85011f08c2f22fb4a208d21bd  md5(organizations.id || '|' || organizations.name) of the earliest non-__TEST row

do $rehearsal$
declare
  v_ist time;
  v_text text;
  v_hash text;
  v_check text;
  v_org uuid;
  v_fp_before text;
  v_fp_after_migrations text;
  v_fp_final text;
  v_test_result text;
begin
  perform set_config('lock_timeout', '5s', true);

  v_ist := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  select o.id, md5(o.id::text || '|' || o.name) into v_org, v_check
    from public.organizations o
   where o.name not like '\_\_TEST%'
   order by o.created_at asc
   limit 1;
  if v_check is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected the real GV Mart org, got %)', coalesce(v_check, 'null');
  end if;

  -- BEFORE fingerprint of the real organisation's customers/service_tickets/invoices/products — count + md5
  -- checksum of each table's ids, so this catches not just a row-count drift but any swap of which rows exist.
  select format('customers=%s ids_md5=%s | service_tickets=%s ids_md5=%s | invoices=%s ids_md5=%s | products=%s ids_md5=%s',
      (select count(*) from public.customers where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.customers where org_id = v_org),
      (select count(*) from public.service_tickets where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.service_tickets where org_id = v_org),
      (select count(*) from public.invoices where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.invoices where org_id = v_org),
      (select count(*) from public.products where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.products where org_id = v_org))
    into v_fp_before;

  v_text := $rh0$-- P4: an identification code per PRODUCT (spares already have one — `spares.sku`, 20260701090300). This is a
-- code SET by master in Inventory/Masters, printed on invoice and quotation lines — NOT a per-unit serial/IMEI.
-- Per-unit tracking (one row per physical unit, captured at sale and tied to the warranty) is a separate, larger
-- design and is explicitly held pending the owner's answer; nothing here anticipates it.
--
-- Same shape as spares.sku: plain nullable text, no DB-level check — sku itself has none either; the
-- alphanumeric/hyphen/underscore format is validated client-side only (ProductsTab.tsx), matching SparesTab.tsx's
-- own sku field exactly. Master-write only (products_write_master already covers this column — no RLS change).
--
-- A case-insensitive PARTIAL unique index: two products in the same org cannot share a code, but any number may
-- leave it null (not yet coded). Safe to add in this same migration — item_code is a brand-new column with no
-- existing rows to conflict (no backfill), so there is nothing for the index to reject at creation time.

alter table public.products
  add column item_code text;

comment on column public.products.item_code is
  'Master-set identification code for the product (not a per-unit serial). Printed on invoice/quotation lines alongside the item name.';

create unique index products_item_code_unique_idx on public.products (org_id, lower(item_code)) where item_code is not null;
$rh0$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261104100000_product_item_code.sql: %', v_hash;
  end if;
  execute replace(v_text, E'\r', '');

  v_text := $rh1$-- P4 part 2: a SNAPSHOT of the item's identification code on each invoice/quotation LINE, stamped at line-creation
-- time — not read from the live catalog at print time (that was the first cut of this package; replaced here).
--
-- invoice_items and quotation_items reference their item by (item_type, item_id): item_type is the enum
-- 'product' | 'spare' (20260701090000_extensions_and_enums.sql), item_id is a bare uuid with NO foreign key —
-- it is polymorphic, pointing at products.id or spares.id depending on item_type (confirmed: neither table's
-- Relationships list in the generated types names item_id; only org_id/invoice_id/quotation_id are real FKs).
-- There is no name-only matching anywhere in this path.
--
-- A BEFORE INSERT trigger on both tables resolves item_code from the catalog the moment the line is created:
-- products.item_code when item_type = 'product', spares.sku when item_type = 'spare'. It ALWAYS overwrites
-- whatever the client sent in that column (the same pattern _meeting_issue_attribution and other
-- stamp-from-session triggers in this schema use for their own column) so a line's code cannot be spoofed by a
-- direct insert.
--
-- The SAME trigger also fires BEFORE UPDATE, where it does the opposite: new.item_code := old.item_code,
-- unconditionally. A line's code is a snapshot of what was true at creation; it must never be rewritten by a
-- later UPDATE — not by a client-supplied value, and not by re-deriving it even if item_type/item_id also change
-- in that UPDATE (invoice_items_write_sales/quotation_items_write_sales already allow a staff UPDATE of other
-- columns on these rows, and that must not have this side effect).
--
-- create_sale and create_quotation are NOT edited — both insert into these tables with plain INSERT statements,
-- so the trigger fires under them exactly as it does under a direct client insert; nothing in either RPC's own
-- body needs to change. No backfill: existing rows (there are none yet in this org, since item_code on products
-- itself was only added in the previous migration) get the column but it is only ever stamped on a NEW row.
--
-- SECURITY INVOKER: a plain read of products/spares, which is already org-wide SELECT for everyone
-- (products_select_org / spares_select_org), so no elevated privilege is needed regardless of which path
-- (create_sale's own SECURITY DEFINER context, or a direct insert_sales write under invoice_items_write_sales)
-- fires the trigger.

alter table public.invoice_items add column item_code text;
alter table public.quotation_items add column item_code text;

comment on column public.invoice_items.item_code is
  'Snapshot of products.item_code or spares.sku at the moment this line was created. Stamped by a trigger, never read live.';
comment on column public.quotation_items.item_code is
  'Snapshot of products.item_code or spares.sku at the moment this line was created. Stamped by a trigger, never read live.';

create or replace function public._stamp_item_code()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    new.item_code := old.item_code;
    return new;
  end if;
  if new.item_type = 'product' then
    select p.item_code into new.item_code from public.products p where p.id = new.item_id;
  elsif new.item_type = 'spare' then
    select s.sku into new.item_code from public.spares s where s.id = new.item_id;
  else
    new.item_code := null;
  end if;
  return new;
end;
$$;

drop trigger if exists aa_stamp_item_code on public.invoice_items;
create trigger aa_stamp_item_code
  before insert or update on public.invoice_items
  for each row execute function public._stamp_item_code();

drop trigger if exists aa_stamp_item_code on public.quotation_items;
create trigger aa_stamp_item_code
  before insert or update on public.quotation_items
  for each row execute function public._stamp_item_code();
$rh1$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '4acedd9092e5fc40009709dcda9f65405c29c314913341ff32e24e6f25678a8d' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261104110000_invoice_quotation_item_code_snapshot.sql: %', v_hash;
  end if;
  execute replace(v_text, E'\r', '');

  v_text := $rh2$-- P4 part 3: a defense-in-depth UPDATE guard on products.item_code, same shape as guard_technician_tier_change /
-- tier_id_master_guard (20261001140000).
--
-- Today products_write_master already restricts EVERY write on products (insert/update/delete, every column,
-- item_code included) to master: `using (org_id = current_org_id() and is_master())` /
-- `with check (...)` (20260701091300_rls.sql). No role other than master can reach an UPDATE of this row at
-- all right now, so under today's policy set this trigger has nothing of its own to block that RLS does not
-- already block first.
--
-- It exists anyway, scoped to item_code only, for the same reason tier_id_master_guard exists even though
-- technicians_write_ops already gates technicians by org: that policy covers a WHOLE TABLE. If products_write_master
-- is ever loosened to let operation_admin (or any non-master role) edit other product fields — stock, pricing,
-- description — item_code does not silently come along for the ride; it stays master-only unless this trigger is
-- deliberately loosened too. Other columns on products are completely untouched by this migration; they remain
-- exactly as editable (or not) as products_write_master already makes them today.
--
-- SECURITY INVOKER (not SECURITY DEFINER, unlike tier_id_master_guard): the only thing evaluated is
-- public.is_master(), which is already SECURITY DEFINER and self-contained — this trigger needs no elevated
-- privilege of its own, and running as invoker means it can never do more than the session already could.
-- search_path is still pinned, as every function in this schema does.
--
-- auth.uid() is null for service-role / migration writes (and for anon, which per 20261016500000 has NO table
-- privilege on products at all — not UPDATE, not even SELECT — so an anon connection can never reach this trigger
-- in the first place; the auth.uid() is null bypass below is for service-role/migration writes only and is not a
-- path anon can use). Fires only when item_code actually changes value (BEFORE UPDATE OF item_code, plus an
-- explicit IS DISTINCT FROM so touching the column in the SET list without changing its value is still a no-op).

create or replace function public.guard_item_code_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.item_code is distinct from old.item_code and auth.uid() is not null and not public.is_master() then
    raise exception 'Only master can change a product''s item_code';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_item_code_update on public.products;
create trigger guard_item_code_update before update of item_code on public.products
  for each row execute function public.guard_item_code_update();

-- Explicit, even though a trigger function is invoked by the executor regardless of EXECUTE grants on it (and a
-- direct `select guard_item_code_update()` outside trigger context is already refused by Postgres itself,
-- "trigger functions can only be called as triggers") — belt-and-suspenders, matching this schema's convention of
-- not relying on a function's shape to keep it un-callable.
revoke all on function public.guard_item_code_update() from public, anon, authenticated;
$rh2$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> 'b5fac0cfb851f31735e1f02cec04e4ce22aab9e7a8176c51c15353ce6be66f4f' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261104120000_item_code_master_update_guard.sql: %', v_hash;
  end if;
  execute replace(v_text, E'\r', '');

  -- AFTER-MIGRATIONS fingerprint: must be identical to the before fingerprint. True by construction — all three
  -- migrations are pure DDL (new column, new trigger, revoke) and touch no existing row in any of these four
  -- tables.
  select format('customers=%s ids_md5=%s | service_tickets=%s ids_md5=%s | invoices=%s ids_md5=%s | products=%s ids_md5=%s',
      (select count(*) from public.customers where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.customers where org_id = v_org),
      (select count(*) from public.service_tickets where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.service_tickets where org_id = v_org),
      (select count(*) from public.invoices where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.invoices where org_id = v_org),
      (select count(*) from public.products where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.products where org_id = v_org))
    into v_fp_after_migrations;
  if v_fp_after_migrations is distinct from v_fp_before then
    raise exception 'REHEARSAL_REFUSED: real-organisation fingerprint changed by the three migrations alone, before the test ran (before=%, after=%) -- this should be impossible for a pure schema/trigger/grant change', v_fp_before, v_fp_after_migrations;
  end if;

  v_text := $rh3$-- Rolled-back DB tests for 20261104120000_item_code_master_update_guard (P4 part 3).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies all three P4 migrations and
-- then this file in ONE request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway
-- __TEST_ organisation only.
--
-- RLS note read before the G-block below: products_write_master already restricts the WHOLE products row to
-- master (is_master() in USING and WITH CHECK). Under today's policies, operation_admin/sales_admin's own UPDATE
-- never reaches this trigger at all — RLS's USING clause makes the row invisible for UPDATE, so the statement
-- succeeds with 0 rows affected, not an exception (see R-block). To prove the TRIGGER itself (not RLS) refuses a
-- non-master change — the thing that actually matters if products_write_master is ever loosened later — the
-- G-block below temporarily disables row level security on products, inside this same rolled-back transaction,
-- so the row is reachable and only the trigger is left standing. RLS is re-enabled immediately after. Nothing here
-- is ever committed regardless (the whole file still ends in an unconditional RAISE).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) runs `alter default privileges for role postgres revoke execute on functions from public`, globally. That also
-- removes PUBLIC execute from the helper functions below, which live in pg_temp and are called after `set local role authenticated`. This default
-- makes every function created here executable again, including helpers added later. (pg_temp is not a name ALTER DEFAULT PRIVILEGES accepts, so
-- the session's real temporary schema is looked up. The setting is rolled back with the wrapper, and disappears with the session otherwise.)
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.act(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    get diagnostics n = row_count;
    execute 'reset role';
    return 'ok:' || n;
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $f$;

do $t$
declare
  v_org uuid; m uuid; o uuid; s uuid; v_brand uuid; v_model uuid; v_product uuid; x text; v_code text;
  v_proc record;
begin
  -- F: the function itself is SECURITY INVOKER with a pinned search_path, as specified (not SECURITY DEFINER).
  select p.prosecdef, p.proconfig into v_proc
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'guard_item_code_update';
  perform pg_temp.chk('F1 guard_item_code_update is SECURITY INVOKER (prosecdef = false)', v_proc.prosecdef = false, v_proc.prosecdef::text);
  perform pg_temp.chk('F2 guard_item_code_update has search_path pinned to public',
    v_proc.proconfig is not null and 'search_path=public' = any(v_proc.proconfig), coalesce(v_proc.proconfig::text, 'null'));
  perform pg_temp.chk('F3 neither anon nor authenticated holds EXECUTE on guard_item_code_update() (explicit revoke; belt-and-suspenders on top of it being un-callable outside trigger context anyway)',
    not has_function_privilege('anon', 'public.guard_item_code_update()', 'execute')
    and not has_function_privilege('authenticated', 'public.guard_item_code_update()', 'execute'));

  -- T: the trigger is BEFORE UPDATE OF item_code specifically, not a blanket BEFORE UPDATE.
  -- (review fix: compared via the TEXT form of tgattr/attnum, not tgattr::int2[] = array_agg(...)::int2[] --
  -- int2vector::int2[] keeps a zero-based lower bound while array_agg(...)::int2[] is one-based, and Postgres
  -- array equality compares bounds too, so the array-form comparison was false even for a correctly-scoped
  -- trigger. tgattr is a vector of the column numbers the trigger is scoped to; this trigger is scoped to one
  -- column, so comparing its text form to that one column's attnum, as text, is exact for this trigger's shape.)
  perform pg_temp.chk('T1 guard_item_code_update trigger exists on products, fires only when item_code is in the UPDATE''s column list',
    exists (
      select 1 from pg_trigger tg
      join pg_attribute a on a.attrelid = tg.tgrelid and a.attname = 'item_code'
      where tg.tgrelid = 'public.products'::regclass and tg.tgname = 'guard_item_code_update'
        and tg.tgattr::text = a.attnum::text));

  insert into public.organizations(name) values ('__TEST_p4c') returning id into v_org;
  m := pg_temp.mkuser('master', v_org); o := pg_temp.mkuser('operation_admin', v_org); s := pg_temp.mkuser('sales_admin', v_org);
  insert into public.brands(org_id, name, category) values (v_org, '__TEST_brand', 'ro') returning id into v_brand;
  insert into public.models(org_id, brand_id, name) values (v_org, v_brand, '__TEST_model') returning id into v_model;
  insert into public.products(org_id, brand_id, model_id, name, category, price, item_code) values (v_org, v_brand, v_model, '__TEST_product', 'ro', 1000, 'RO-STD-01') returning id into v_product;

  -- W: master, unaffected by this migration — can still change item_code, and every other column stays editable.
  x := pg_temp.act(m, format('update public.products set item_code = ''RO-STD-02'' where id = %L', v_product));
  perform pg_temp.chk('W1 master can still change item_code (the guard allows master through)', x = 'ok:1', x);
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('W1b the value round-trips', v_code = 'RO-STD-02', coalesce(v_code, 'null'));
  x := pg_temp.act(m, format('update public.products set price = 1234 where id = %L', v_product));
  perform pg_temp.chk('W2 master can still change a column OTHER than item_code (the guard only fires on item_code, never blocked a thing here)', x = 'ok:1', x);
  x := pg_temp.act(m, format('update public.products set name = ''__TEST_product'', item_code = ''RO-STD-02'' where id = %L', v_product));
  perform pg_temp.chk('W3 re-sending the SAME item_code value in an UPDATE''s SET list is a no-op for the guard (IS DISTINCT FROM), and still succeeds', x = 'ok:1', x);

  -- R: today, before this trigger is even reached, products_write_master''s RLS already makes the row invisible
  -- to a non-master UPDATE — the statement succeeds with 0 rows affected, not an exception. This is EXISTING
  -- behaviour (product_item_code.test.sql''s W2/W3), restated here only to set up the contrast with the G-block.
  x := pg_temp.act(o, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('R1 operation_admin''s UPDATE affects 0 rows under normal RLS (RLS, not this trigger, is what blocks it today)', x = 'ok:0', x);
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('R2 the value is unchanged by R1', v_code = 'RO-STD-02', coalesce(v_code, 'null'));

  -- G: isolate the TRIGGER itself from RLS, so a non-master write actually reaches it. This is the guard this
  -- migration adds; it must raise on its own, independent of whatever products_write_master does or will do.
  alter table public.products disable row level security;
  x := pg_temp.act(o, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('G1 with RLS OUT OF THE WAY, operation_admin''s item_code change is refused by the TRIGGER itself', x like 'err:%Only master can change%', x);
  x := pg_temp.act(s, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('G2 same for sales_admin', x like 'err:%Only master can change%', x);
  x := pg_temp.act(o, format('update public.products set price = 999 where id = %L', v_product));
  perform pg_temp.chk('G3 ...but operation_admin can still change a column OTHER than item_code once RLS is out of the way (the guard is scoped to item_code only)', x = 'ok:1', x);
  x := pg_temp.act(m, format('update public.products set item_code = ''RO-STD-03'' where id = %L', v_product));
  perform pg_temp.chk('G4 master still succeeds with RLS disabled too (is_master() does not depend on RLS)', x = 'ok:1', x);
  alter table public.products enable row level security;
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('G5 after re-enabling RLS, the value reflects only what master (G4) actually set', v_code = 'RO-STD-03', coalesce(v_code, 'null'));

  -- S0: explicitly reset the session's claims before S1 — the G-block above ran pg_temp.act calls that each set
  -- request.jwt.claims via set_config(..., true) (transaction-local), and 'reset role' only resets the ROLE, not
  -- that GUC. Clearing it here, and proving auth.uid() actually reads back null afterward, is what makes S1 below
  -- a genuine service-role/migration-write case rather than an accidental leftover claim from G4's master call.
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.chk('S0 request.jwt.claims is cleared and auth.uid() reads back null before the service-role/migration-write case below', auth.uid() is null, coalesce(auth.uid()::text, 'null'));

  -- S: service-role / migration writes (auth.uid() is null in this session — no request.jwt.claims was ever set
  -- for it) bypass the guard, exactly as specified. This is the plain test-runner session itself, not pg_temp.act.
  update public.products set item_code = 'RO-STD-04' where id = v_product;
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('S1 a service-role/migration write (auth.uid() is null) changes item_code without hitting the guard', v_code = 'RO-STD-04', coalesce(v_code, 'null'));

  -- A: anon cannot reach this trigger at all — it holds no table privilege on products whatsoever (20261016500000
  -- revoked all of it directly), so the auth.uid() is null bypass above is never reachable from an anon connection.
  perform pg_temp.chk('A1 anon has no UPDATE privilege on products at all',
    not has_table_privilege('anon', 'public.products', 'UPDATE'));
  perform pg_temp.chk('A2 ...nor SELECT, INSERT or DELETE (fully revoked, not just UPDATE)',
    not has_table_privilege('anon', 'public.products', 'SELECT')
    and not has_table_privilege('anon', 'public.products', 'INSERT')
    and not has_table_privilege('anon', 'public.products', 'DELETE'));

  -- I: a role that can write today (master) can still insert a brand-new product with item_code set; this
  -- migration adds no BEFORE INSERT trigger, so insert is completely untouched by it.
  x := pg_temp.act(m, format(
    'insert into public.products(org_id, brand_id, model_id, name, category, price, item_code) values (%L, %L, %L, ''__TEST_product_new'', ''ro'', 500, ''RO-NEW-01'')',
    v_org, v_brand, v_model));
  perform pg_temp.chk('I1 master can still insert a new product with item_code set (insert is untouched by this migration)', x = 'ok:1', x);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh3$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '8b82114daf5e0009ec3a98db6a77e164febec8df1fcc4c4695e8b7240312ef36' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for item_code_master_update_guard.test.sql: %', v_hash;
  end if;
  begin
    execute replace(v_text, E'\r', '');
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;

  -- FINAL fingerprint, after the test file ran: must still be identical to the before fingerprint. True by
  -- construction — the test file only ever creates/mutates its own throwaway __TEST_ organisation.
  select format('customers=%s ids_md5=%s | service_tickets=%s ids_md5=%s | invoices=%s ids_md5=%s | products=%s ids_md5=%s',
      (select count(*) from public.customers where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.customers where org_id = v_org),
      (select count(*) from public.service_tickets where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.service_tickets where org_id = v_org),
      (select count(*) from public.invoices where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.invoices where org_id = v_org),
      (select count(*) from public.products where org_id = v_org),
      (select md5(coalesce(string_agg(id::text, ',' order by id), '')) from public.products where org_id = v_org))
    into v_fp_final;
  if v_fp_final is distinct from v_fp_before then
    raise exception 'REHEARSAL_REFUSED: CHANGED -- final real-organisation fingerprint differs from before (before=%, final=%) -- something in this rehearsal touched real data', v_fp_before, v_fp_final;
  end if;

  raise exception 'RESULTS%', v_test_result
    || E'\n\n=== real-organisation fingerprint (customers/service_tickets/invoices/products) ==='
    || E'\nbefore:            ' || v_fp_before
    || E'\nafter migrations:  ' || v_fp_after_migrations || ' -- identical to before: true'
    || E'\nfinal (post-test): ' || v_fp_final || ' -- identical to before: true';
end
$rehearsal$;
