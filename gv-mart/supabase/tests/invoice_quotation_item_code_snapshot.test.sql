-- Rolled-back DB tests for 20261104110000_invoice_quotation_item_code_snapshot (P4 part 2).
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

do $t$
declare
  v_org uuid; v_brand uuid; v_model uuid; v_cust uuid; v_product uuid; v_spare uuid;
  v_inv uuid; v_quo uuid; v_ii uuid; v_qi uuid; v_code text; v_ii_first uuid;
begin
  insert into public.organizations(name) values ('__TEST_p4b') returning id into v_org;
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

  -- U: BEFORE INSERT only — an UPDATE of the line's own item_id/item_type does not re-stamp
  update public.invoice_items set item_type = 'spare', item_id = v_spare where id = v_ii;
  select item_code into v_code from public.invoice_items where id = v_ii;
  perform pg_temp.chk('U1 the trigger is insert-only; updating item_type/item_id on an existing line leaves item_code as it was', v_code is null, coalesce(v_code, 'null'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
