-- Rough, rolled-back timing check for the automation emit triggers (migration 20261017100000).
-- Run AFTER the migration inside one transaction (the runner concatenates them). Inserts N tickets and N leads with the
-- seven zz_automation_emit_* triggers ENABLED and DISABLED, alternating rounds so cache warm-up does not bias one side,
-- once with no rules and once with three matching live rules per event. Everything (including the throwaway org) is rolled
-- back by the final RAISE; nothing is sent (no sender exists in this migration) and no real customer is touched.
-- Wall-clock time inside one transaction on a shared database: treat as a ballpark, not a benchmark.
do $t$
declare
  v_org uuid; v_cust uuid; v_i int; v_n int := 150; v_round int; v_t0 timestamptz; v_ms numeric;
  r_on_t numeric[] := '{}'; r_off_t numeric[] := '{}'; r_on_l numeric[] := '{}'; r_off_l numeric[] := '{}';
  q_on_t numeric[] := '{}'; q_off_t numeric[] := '{}'; q_on_l numeric[] := '{}'; q_off_l numeric[] := '{}';
  v_phase text; v_out text := ''; v_trg text[] := array['ticket','visit','invoice','lead','amc','warranty','quotation'];
  x text;
begin
  insert into organizations (name) values ('__TEST_automation_timing') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ timing', '9400000040') returning id into v_cust;

  for v_phase in select unnest(array['no rules', 'three live rules per event']) loop
    if v_phase <> 'no rules' then
      insert into public.automation_rules (org_id, event_key, recipient_role, channel, status, conditions)
      select v_org, e, 'customer', 'whatsapp', 'live', '{}'::jsonb
        from unnest(array['ticket.created','ticket.created','ticket.created','lead.created','lead.created','lead.created']) e;
    end if;
    r_on_t := '{}'; r_off_t := '{}'; r_on_l := '{}'; r_off_l := '{}';
    for v_round in 1..4 loop
      -- odd rounds: triggers ON, even rounds: OFF (ON first)
      foreach x in array v_trg loop
        if v_round % 2 = 1 then
          execute format('alter table %s enable trigger zz_automation_emit_%s',
            case x when 'ticket' then 'public.service_tickets' when 'visit' then 'public.service_visits' when 'invoice' then 'public.invoices'
                   when 'lead' then 'public.leads' when 'amc' then 'public.amc_contracts' when 'warranty' then 'public.warranties'
                   else 'public.quotations' end, x);
        else
          execute format('alter table %s disable trigger zz_automation_emit_%s',
            case x when 'ticket' then 'public.service_tickets' when 'visit' then 'public.service_visits' when 'invoice' then 'public.invoices'
                   when 'lead' then 'public.leads' when 'amc' then 'public.amc_contracts' when 'warranty' then 'public.warranties'
                   else 'public.quotations' end, x);
        end if;
      end loop;

      v_t0 := clock_timestamp();
      for v_i in 1..v_n loop
        insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ timing ' || v_round || '-' || v_i);
      end loop;
      v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000 / v_n;
      if v_round % 2 = 1 then r_on_t := r_on_t || v_ms; else r_off_t := r_off_t || v_ms; end if;

      v_t0 := clock_timestamp();
      for v_i in 1..v_n loop
        insert into leads (org_id, customer_id, name, mobile, source, status, kind)
        values (v_org, v_cust, '__TEST_ timing lead ' || v_round || '-' || v_i, '94000' || lpad(((v_round * 1000) + v_i)::text, 5, '0'), 'customer_app', 'new', 'service');
      end loop;
      v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000 / v_n;
      if v_round % 2 = 1 then r_on_l := r_on_l || v_ms; else r_off_l := r_off_l || v_ms; end if;
    end loop;

    v_out := v_out || format(E'\n[%s] per insert, ms (avg of rounds, N=%s per round)', v_phase, v_n)
      || format(E'\n  service_tickets  triggers ON %s   OFF %s   overhead %s ms',
           round((select avg(u) from unnest(r_on_t) u), 3), round((select avg(u) from unnest(r_off_t) u), 3),
           round((select avg(u) from unnest(r_on_t) u) - (select avg(u) from unnest(r_off_t) u), 3))
      || format(E'\n  leads            triggers ON %s   OFF %s   overhead %s ms',
           round((select avg(u) from unnest(r_on_l) u), 3), round((select avg(u) from unnest(r_off_l) u), 3),
           round((select avg(u) from unnest(r_on_l) u) - (select avg(u) from unnest(r_off_l) u), 3));
    -- leave the triggers enabled for the next phase
    for v_round in 1..1 loop
      foreach x in array v_trg loop
        execute format('alter table %s enable trigger zz_automation_emit_%s',
          case x when 'ticket' then 'public.service_tickets' when 'visit' then 'public.service_visits' when 'invoice' then 'public.invoices'
                 when 'lead' then 'public.leads' when 'amc' then 'public.amc_contracts' when 'warranty' then 'public.warranties'
                 else 'public.quotations' end, x);
      end loop;
    end loop;
  end loop;

  raise exception 'TIMING%', v_out;
end $t$;
