-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): invoice/quotation item_code snapshot trigger (P4 part 2): 20261104100000_product_item_code.sql then 20261104110000_invoice_quotation_item_code_snapshot.sql + its tests
-- This run changes no real data: every statement below runs inside one rolled-back transaction and the embedded
-- test file itself ends in an unconditional RAISE, so nothing is ever committed, on the real org or anywhere else.
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()),
-- (2) recomputes the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) recomputes
-- a RELATIVE fingerprint of the real organisation (its id + name, picking the earliest non-__TEST-named row — not an
-- exact snapshot of the whole table, so it survives new test orgs being added later) and refuses on any mismatch,
-- confirming this rehearsal is pointed at the real project, (4) executes the migrations in order (20261104100000_product_item_code.sql then 20261104110000_invoice_quotation_item_code_snapshot.sql)
-- and then the test file, (5) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- migrations/20261104100000_product_item_code.sql is embedded here a SECOND time (it was already typed in full in the first wrapper of this
-- package) because nothing persists between separate rehearsal runs — this test file needs the column that
-- migration adds, so this wrapper must apply it first, inside the same rolled-back transaction, every time.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with
-- test code outside this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure
-- and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c  gv-mart/supabase/migrations/20261104100000_product_item_code.sql
--   4acedd9092e5fc40009709dcda9f65405c29c314913341ff32e24e6f25678a8d  gv-mart/supabase/migrations/20261104110000_invoice_quotation_item_code_snapshot.sql
--   4bb51b88237f487303085e670f1cd9ed26817e3fbe3ba6060fce2bfb3521424e  gv-mart/supabase/tests/invoice_quotation_item_code_snapshot.test.sql
-- Pinned (relative fingerprint of the real organisation; read-only, confirmed against the live project):
--   6f891cf85011f08c2f22fb4a208d21bd  md5(organizations.id || '|' || organizations.name) of the earliest non-__TEST row

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
  v_check text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  select md5(o.id::text || '|' || o.name) into v_check
    from public.organizations o
   where o.name not like '\_\_TEST%'
   order by o.created_at asc
   limit 1;
  if v_check is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected the real GV Mart org, got %)', coalesce(v_check, 'null');
  end if;

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
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261104100000_product_item_code.sql: %', v_hash;
  end if;
  execute v_text;

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
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '4acedd9092e5fc40009709dcda9f65405c29c314913341ff32e24e6f25678a8d' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261104110000_invoice_quotation_item_code_snapshot.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh2$-- Rolled-back DB tests for 20261104110000_invoice_quotation_item_code_snapshot (P4 part 2).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisation only.
-- Exercises the trigger directly via a raw insert into invoice_items/quotation_items (not through create_sale/
-- create_quotation, which were confirmed NOT edited and insert with a plain INSERT — so the trigger fires under
-- them exactly as it does here; see the migration's own header comment for the confirmation).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
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
  v_org uuid; v_brand uuid; v_model uuid; v_cust uuid; v_product uuid; v_spare uuid;
  v_inv uuid; v_quo uuid; v_ii uuid; v_qi uuid; v_code text; v_ii_first uuid; s uuid; x text;
begin
  insert into public.organizations(name) values ('__TEST_p4b') returning id into v_org;
  s := pg_temp.mkuser('sales_admin', v_org);
  insert into public.brands(org_id, name, category) values (v_org, '__TEST_brand', 'ro') returning id into v_brand;
  insert into public.models(org_id, brand_id, name) values (v_org, v_brand, '__TEST_model') returning id into v_model;
  insert into public.customers(org_id, name, mobile) values (v_org, '__TEST_cust', '9000000020') returning id into v_cust;
  insert into public.products(org_id, brand_id, model_id, name, category, price, item_code) values (v_org, v_brand, v_model, '__TEST_product', 'ro', 1000, 'RO-STD-01') returning id into v_product;
  insert into public.spares(org_id, name, price, sku) values (v_org, '__TEST_spare', 100, 'SPR-AB-01') returning id into v_spare;
  insert into public.invoices(org_id, customer_id, type, subtotal, total) values (v_org, v_cust, 'product', 0, 0) returning id into v_inv;
  insert into public.quotations(org_id, customer_id) values (v_org, v_cust) returning id into v_quo;

  -- S: the trigger stamps on insert, from the catalog, ignoring a client-supplied value
  insert into public.invoice_items(org_id, invoice_id, item_type, item_id, qty, price) values (v_org, v_inv, 'product', v_product, 1, 1000) returning id into v_ii;
  v_ii_first := v_ii;
  select item_code into v_code from public.invoice_items where id = v_ii;
  perform pg_temp.chk('S1 a product line is stamped with products.item_code', v_code = 'RO-STD-01', coalesce(v_code, 'null'));

  insert into public.invoice_items(org_id, invoice_id, item_type, item_id, qty, price, item_code) values (v_org, v_inv, 'spare', v_spare, 2, 100, '__TEST_SPOOFED') returning id into v_ii;
  select item_code into v_code from public.invoice_items where id = v_ii;
  perform pg_temp.chk('S2 a spare line is stamped with spares.sku, and a client-supplied item_code is IGNORED (not spoofable)', v_code = 'SPR-AB-01', coalesce(v_code, 'null'));

  insert into public.quotation_items(org_id, quotation_id, item_type, item_id, qty, price) values (v_org, v_quo, 'product', v_product, 1, 1000) returning id into v_qi;
  select item_code into v_code from public.quotation_items where id = v_qi;
  perform pg_temp.chk('S3 a quotation line (product) is stamped the same way', v_code = 'RO-STD-01', coalesce(v_code, 'null'));

  insert into public.quotation_items(org_id, quotation_id, item_type, item_id, qty, price) values (v_org, v_quo, 'spare', v_spare, 1, 100) returning id into v_qi;
  select item_code into v_code from public.quotation_items where id = v_qi;
  perform pg_temp.chk('S4 a quotation line (spare) is stamped the same way', v_code = 'SPR-AB-01', coalesce(v_code, 'null'));

  -- N: no catalog code -> line stays null, not an error
  update public.products set item_code = null where id = v_product;
  insert into public.invoice_items(org_id, invoice_id, item_type, item_id, qty, price) values (v_org, v_inv, 'product', v_product, 1, 1000) returning id into v_ii;
  select item_code into v_code from public.invoice_items where id = v_ii;
  perform pg_temp.chk('N1 a product with no item_code set yields a null line code (not an error)', v_code is null);
  update public.products set item_code = 'RO-STD-01' where id = v_product;

  -- F: it is a SNAPSHOT — editing the catalog afterwards does not change the already-created line
  update public.products set item_code = 'RO-STD-02' where id = v_product;
  select item_code into v_code from public.invoice_items where id = v_ii_first;
  perform pg_temp.chk('F1 changing the product''s code afterwards does NOT change an already-created line (the whole point of a snapshot)', v_code = 'RO-STD-01', coalesce(v_code, 'null'));

  -- U: the trigger ALSO fires BEFORE UPDATE, and there it always restores old.item_code — a line's code never
  -- changes after creation, whatever the UPDATE touches.
  update public.invoice_items set item_type = 'spare', item_id = v_spare where id = v_ii;
  select item_code into v_code from public.invoice_items where id = v_ii;
  perform pg_temp.chk('U1 updating item_type/item_id on an existing line leaves item_code as it was (still null here)', v_code is null, coalesce(v_code, 'null'));

  -- U2: a direct client UPDATE of item_code itself is a no-op — BEFORE UPDATE overwrites it back to old.item_code
  -- before the row is written, as a sales_admin (invoice_items_write_sales), not just as superuser.
  x := pg_temp.act(s, format('update public.invoice_items set item_code = ''HACKED'' where id = %L', v_ii_first));
  perform pg_temp.chk('U2a the UPDATE itself succeeds (RLS allows it; only item_code is defended)', x = 'ok:1', x);
  select item_code into v_code from public.invoice_items where id = v_ii_first;
  perform pg_temp.chk('U2b ...but item_code is unchanged — still the original snapshot, not ''HACKED''', v_code = 'RO-STD-01', coalesce(v_code, 'null'));

  x := pg_temp.act(s, format('update public.quotation_items set item_code = ''HACKED'' where id = %L', v_qi));
  select item_code into v_code from public.quotation_items where id = v_qi;
  perform pg_temp.chk('U3 the same no-op holds for quotation_items', v_code = 'SPR-AB-01', coalesce(v_code, 'null'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh2$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '4bb51b88237f487303085e670f1cd9ed26817e3fbe3ba6060fce2bfb3521424e' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for invoice_quotation_item_code_snapshot.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
