insert into rs_run select 'first', (select count(*) from complaint_types where org_id = (select org from rs_ctx)),
  (select count(*) from complaint_types ct join organizations r on r.id = ct.org_id where r.name not like '\_\_TEST\_%' escape '\');
