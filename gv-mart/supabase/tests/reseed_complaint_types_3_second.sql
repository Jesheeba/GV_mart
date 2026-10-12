insert into rs_run select 'second', (select count(*) from complaint_types where org_id = (select org from rs_ctx)),
  (select count(*) from complaint_types ct join organizations r on r.id = ct.org_id where r.name not like '\_\_TEST\_%' escape '\');
do $t$
declare c rs_ctx; f rs_run; s rs_run; res text;
begin
  select * into c from rs_ctx; select * into f from rs_run where step = 'first'; select * into s from rs_run where step = 'second';
  res := format('org before=%s, after first run=%s, after second run=%s; real org rows before=%s, after first=%s, after second=%s',
                c.n_org_before, f.n_org, s.n_org, c.n_real_before, f.n_real, s.n_real);
  res := res || E'\n' || case when f.n_org > c.n_org_before and s.n_org = f.n_org then 'ok   idempotent: the second run added 0 rows to the throwaway organisation'
                              else 'FAIL second run changed the throwaway organisation' end;
  res := res || E'\n' || case when f.n_real = c.n_real_before and s.n_real = c.n_real_before then 'ok   the real organisation gained 0 rows (all default labels already present)'
                              else 'FAIL the real organisation changed' end;
  raise exception E'RESULTS:%', res;
end $t$;
