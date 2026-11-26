-- Tests for 20261229100000_address_choice_not_set. Runs after the fixtures + migration in one rolled-back
-- transaction and ENDS IN AN UNCONDITIONAL RAISE, so nothing persists.
do $t$
declare
  v_org uuid := pg_temp.fx('org');
  v_cust uuid; v_type text; v_own text; v_n int; v_err text;
  v_sig regprocedure := 'public.create_customer_with_details(uuid,text,text,jsonb,jsonb,uuid)'::regprocedure;
begin
  -- AC-1 columns: nullable, no default
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'addresses' and column_name in ('address_type', 'ownership')
     and is_nullable = 'YES' and column_default is null;
  perform pg_temp.chk('AC-1 address_type + ownership nullable with no default', v_n = 2, v_n::text);

  -- AC-2 existing rows untouched (real orgs + fixture)
  select count(*) into v_n from pg_temp.real_before b join public.addresses a using (id)
   where a.address_type is distinct from b.address_type or a.ownership is distinct from b.ownership;
  perform pg_temp.chk('AC-2 real-org addresses unchanged', v_n = 0, v_n || ' changed');
  select address_type::text, ownership::text into v_type, v_own from addresses where id = pg_temp.fx('a_old');
  perform pg_temp.chk('AC-2 fixture keeps commercial/rental', v_type = 'commercial' and v_own = 'rental');

  -- AC-3 RPC as staff: keys missing -> null
  perform pg_temp.as_user(pg_temp.fx('sales'));
  v_cust := public.create_customer_with_details(v_org, '', 'other',
    jsonb_build_array(jsonb_build_object('name', '__TEST_ ac n1', 'mobile', '9000000511', 'is_primary', true)),
    jsonb_build_object('area', '__TEST_ Anna Nagar'));
  perform pg_temp.as_pg();
  select address_type::text, ownership::text into v_type, v_own from addresses where customer_id = v_cust;
  perform pg_temp.chk('AC-3 RPC: missing type/ownership saved as null (not residential/own)', v_type is null and v_own is null,
    coalesce(v_type, 'null') || '/' || coalesce(v_own, 'null'));

  -- AC-4 explicit JSON null and empty string -> null
  perform pg_temp.as_user(pg_temp.fx('sales'));
  v_cust := public.create_customer_with_details(v_org, '', 'other',
    jsonb_build_array(jsonb_build_object('name', '__TEST_ ac n2', 'mobile', '9000000512', 'is_primary', true)),
    jsonb_build_object('area', '__TEST_ x', 'address_type', null, 'ownership', ''));
  perform pg_temp.as_pg();
  select address_type::text, ownership::text into v_type, v_own from addresses where customer_id = v_cust;
  perform pg_temp.chk('AC-4 RPC: JSON null and empty string saved as null', v_type is null and v_own is null,
    coalesce(v_type, 'null') || '/' || coalesce(v_own, 'null'));

  -- AC-5 chosen values pass through
  perform pg_temp.as_user(pg_temp.fx('sales'));
  v_cust := public.create_customer_with_details(v_org, '', 'other',
    jsonb_build_array(jsonb_build_object('name', '__TEST_ ac n3', 'mobile', '9000000513', 'is_primary', true)),
    jsonb_build_object('area', '__TEST_ y', 'address_type', 'commercial', 'ownership', 'rental'));
  perform pg_temp.as_pg();
  select address_type::text, ownership::text into v_type, v_own from addresses where customer_id = v_cust;
  perform pg_temp.chk('AC-5 RPC: chosen commercial/rental saved', v_type = 'commercial' and v_own = 'rental');

  -- AC-6 invalid enum value still rejected
  begin
    perform pg_temp.as_user(pg_temp.fx('sales'));
    perform public.create_customer_with_details(v_org, '', 'other',
      jsonb_build_array(jsonb_build_object('name', '__TEST_ ac n4', 'mobile', '9000000514', 'is_primary', true)),
      jsonb_build_object('area', '__TEST_ z', 'address_type', 'industrial'));
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC-6 RPC: invalid address_type rejected', v_err is not null, coalesce(v_err, 'accepted'));

  -- AC-7 no address details at all: still no address row (has_address ignores the two keys)
  perform pg_temp.as_user(pg_temp.fx('sales'));
  v_cust := public.create_customer_with_details(v_org, '', 'other',
    jsonb_build_array(jsonb_build_object('name', '__TEST_ ac n5', 'mobile', '9000000515', 'is_primary', true)),
    jsonb_build_object('address_type', null, 'ownership', null));
  perform pg_temp.as_pg();
  select count(*) into v_n from addresses where customer_id = v_cust;
  perform pg_temp.chk('AC-7 RPC: no address details -> no address row', v_n = 0, v_n::text);

  -- AC-8 direct writes (admin edit / customer app paths): explicit null clears; insert without the columns stores null
  perform pg_temp.as_user(pg_temp.fx('master'));
  update addresses set address_type = null, ownership = null where id = pg_temp.fx('a_old');
  perform pg_temp.as_pg();
  select address_type::text, ownership::text into v_type, v_own from addresses where id = pg_temp.fx('a_old');
  perform pg_temp.chk('AC-8 staff edit to Not set clears the stored answer', v_type is null and v_own is null);
  insert into addresses (org_id, customer_id, full_address, is_primary)
    values (v_org, pg_temp.fx('c_old'), '__TEST_ second', false) returning address_type::text, ownership::text into v_type, v_own;
  perform pg_temp.chk('AC-8 insert without the columns stores null (no default)', v_type is null and v_own is null);

  -- AC-9 grants unchanged: authenticated can execute, anon cannot
  perform pg_temp.chk('AC-9 authenticated can execute the RPC', has_function_privilege('authenticated', v_sig, 'execute'));
  perform pg_temp.chk('AC-9 anon cannot execute the RPC', not has_function_privilege('anon', v_sig, 'execute'));
end $t$;

do $r$
declare v_pass int; v_fail int; v_lines text;
begin
  select count(*) filter (where line like 'PASS%'), count(*) filter (where line like 'FAIL%'), string_agg(line, E'\n' order by n)
    into v_pass, v_fail, v_lines from pg_temp.res;
  raise exception E'RESULTS (% pass / % fail) -- rolled back, nothing persists\n%', v_pass, v_fail, v_lines;
end $r$;
