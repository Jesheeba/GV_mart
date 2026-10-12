-- HELD (review F-08): one checked door for staff-originated WhatsApp messages, plus a master-editable test-mode allow-list.
--
-- BEFORE: any active staff user (incl. sales_admin) could INSERT into whatsapp_outbox directly (policy
-- whatsapp_outbox_insert_staff) or call send_whatsapp_stub (granted to authenticated) with ANY to_mobile and a ref_type the
-- dispatcher sends, so a real message could be queued to an arbitrary number.
--
-- AFTER:
--   1. whatsapp_outbox has no client write path at all: the insert policy is dropped and INSERT/UPDATE/DELETE/TRUNCATE
--      are revoked from anon and authenticated (SELECT stays for the staff screens). Definer functions (milestone triggers,
--      PO flow) and the service role (Edge Functions) are unaffected.
--   2. send_staff_whatsapp(...) is the ONLY function a signed-in staff user can use to queue a message. It is SECURITY DEFINER,
--      needs an active staff caller of the same organisation, accepts only ref types it knows how to verify, requires the record
--      to exist in the caller's organisation and the number to be one of that record's own numbers (PO -> the supplier;
--      ticket / visit / invoice -> the customer or one of the customer's members), logs the sender, and is not executable by
--      PUBLIC/anon.
--   3. send_whatsapp_stub loses its authenticated/anon/PUBLIC grant (still used inside definer functions such as
--      simulate_inbound_whatsapp). create_purchase_order, its only staff-side caller, is repointed to send_staff_whatsapp.
--   4. settings.wa_test_mode_enabled (default OFF) + settings.wa_test_allowed_numbers: when ON, nothing is sent to a number that
--      is not on the list. Enforced at the single real transmission point (sendMessage in the Edge Functions) and here in
--      send_staff_whatsapp. Blocked attempts are written to audit_log (action WA_SEND_BLOCKED). Only a master can change the
--      two settings (existing settings_write_master policy, plus a column guard so the columns cannot be changed any other way).
--
-- Numbers in settings/outbox are stored bare 10-digit (customers.mobile is CHECK ^\d{10}$).

-- ── columns ────────────────────────────────────────────────────────────────────────────────────────────────────────────
alter table public.whatsapp_outbox
  add column if not exists sent_by uuid references public.profiles(id) on delete set null;

create or replace function public._wa_numbers_valid(p_numbers text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(bool_and(n ~ '^[0-9]{10}$'), true) from unnest(p_numbers) as n
$$;

alter table public.settings
  add column if not exists wa_test_mode_enabled boolean not null default false,
  add column if not exists wa_test_allowed_numbers text[] not null default '{}'::text[];

alter table public.settings drop constraint if exists settings_wa_test_numbers_valid;
alter table public.settings
  add constraint settings_wa_test_numbers_valid check (public._wa_numbers_valid(wa_test_allowed_numbers));

-- only a master may change the two columns (the generic write policy already needs is_master(); this closes
-- the case of any future broader settings policy). Service role / owner (migrations) are trusted.
create or replace function public._trg_settings_wa_test_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.wa_test_mode_enabled is distinct from old.wa_test_mode_enabled
          or new.wa_test_allowed_numbers is distinct from old.wa_test_allowed_numbers)
     and not coalesce(public.is_master(), false) then
    raise exception 'settings: only a master can change the WhatsApp test mode';
  end if;
  return new;
end;
$$;
drop trigger if exists settings_wa_test_guard on public.settings;
create trigger settings_wa_test_guard before update on public.settings
  for each row execute function public._trg_settings_wa_test_guard();
revoke all on function public._trg_settings_wa_test_guard() from public, anon, authenticated;

-- ── close the direct write path ────────────────────────────────────────────────────────────────────────────────────────
drop policy if exists whatsapp_outbox_insert_staff on public.whatsapp_outbox;
revoke insert, update, delete, truncate on public.whatsapp_outbox from public, anon, authenticated;

-- ── the one checked staff door ─────────────────────────────────────────────────────────────────────────────────────────
-- Same argument list as send_whatsapp_stub so callers only change the name.
create or replace function public.send_staff_whatsapp(
  p_org_id uuid,
  p_to_mobile text,
  p_customer_id uuid,
  p_milestone text,
  p_template text,
  p_payload jsonb,
  p_ref_type text,
  p_ref_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_to          text;
  v_customer    uuid;
  v_allowed     text[];
  v_test_on     boolean;
  v_test_list   text[];
  v_id          uuid;
  v_found       boolean := false;
begin
  if auth.uid() is null or p_org_id is distinct from public.current_org_id() then
    raise exception 'send_staff_whatsapp: organisation mismatch';
  end if;
  if not public.is_staff() then
    raise exception 'send_staff_whatsapp: caller is not active staff';
  end if;
  if p_ref_type is null or p_ref_id is null then
    raise exception 'send_staff_whatsapp: a record reference is required';
  end if;
  if p_ref_type not in ('purchase_order', 'service_ticket', 'service_visit', 'invoice') then
    raise exception 'send_staff_whatsapp: ref_type % is not supported', p_ref_type;
  end if;

  v_to := right(regexp_replace(coalesce(p_to_mobile, ''), '[^0-9]', '', 'g'), 10);
  if v_to !~ '^[0-9]{10}$' then
    raise exception 'send_staff_whatsapp: a 10-digit mobile number is required';
  end if;

  -- the record must exist in the caller's organisation; collect that record's own numbers
  if p_ref_type = 'purchase_order' then
    select true,
           array_remove(array[right(regexp_replace(coalesce(s.whatsapp, ''), '[^0-9]', '', 'g'), 10),
                              right(regexp_replace(coalesce(s.contact, ''), '[^0-9]', '', 'g'), 10)], '')
      into v_found, v_allowed
      from public.purchase_orders po
      join public.suppliers s on s.id = po.supplier_id and s.org_id = po.org_id
     where po.id = p_ref_id and po.org_id = p_org_id;
    v_customer := null;
  else
    select t.customer_id into v_customer
      from (
        select st.customer_id, st.org_id from public.service_tickets st where p_ref_type = 'service_ticket' and st.id = p_ref_id
        union all
        select st.customer_id, st.org_id from public.service_visits sv
          join public.service_tickets st on st.id = sv.ticket_id
         where p_ref_type = 'service_visit' and sv.id = p_ref_id
        union all
        select i.customer_id, i.org_id from public.invoices i where p_ref_type = 'invoice' and i.id = p_ref_id
      ) t
     where t.org_id = p_org_id
     limit 1;
    v_found := v_customer is not null;
    if v_found then
      select coalesce(array_agg(distinct n), '{}'::text[]) into v_allowed
        from (
          select right(regexp_replace(c.mobile, '[^0-9]', '', 'g'), 10) as n
            from public.customers c where c.id = v_customer and c.org_id = p_org_id
          union
          select right(regexp_replace(m.mobile, '[^0-9]', '', 'g'), 10)
            from public.customer_members m where m.customer_id = v_customer and m.org_id = p_org_id
        ) x
       where n ~ '^[0-9]{10}$';
    end if;
  end if;

  if not v_found then
    raise exception 'send_staff_whatsapp: % record not found in your organisation', p_ref_type;
  end if;
  if v_to <> all (coalesce(v_allowed, '{}'::text[])) or coalesce(array_length(v_allowed, 1), 0) = 0 then
    raise exception 'send_staff_whatsapp: that number does not belong to the referenced record';
  end if;
  if p_customer_id is not null and v_customer is not null and p_customer_id is distinct from v_customer then
    raise exception 'send_staff_whatsapp: customer does not match the referenced record';
  end if;

  -- test mode: block and log anything not on the allow-list
  select s.wa_test_mode_enabled, s.wa_test_allowed_numbers into v_test_on, v_test_list
    from public.settings s where s.org_id = p_org_id;
  if coalesce(v_test_on, false) and not (v_to = any (coalesce(v_test_list, '{}'::text[]))) then
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
    values (p_org_id, auth.uid(), 'WA_SEND_BLOCKED', 'whatsapp_outbox', p_ref_id,
            jsonb_build_object('reason', 'test_mode_not_allow_listed', 'via', 'send_staff_whatsapp',
                               'ref_type', p_ref_type, 'template', p_template, 'to_last4', right(v_to, 4)));
    return null;
  end if;

  insert into public.whatsapp_outbox
         (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status, sent_by)
  values (p_org_id, 'outbound', v_to, coalesce(v_customer, p_customer_id), p_milestone, p_template,
          coalesce(p_payload, '{}'::jsonb), p_ref_type, p_ref_id, 'sent', auth.uid())
  returning id into v_id;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
  values (p_org_id, auth.uid(), 'WA_STAFF_SEND', 'whatsapp_outbox', v_id,
          jsonb_build_object('ref_type', p_ref_type, 'ref_id', p_ref_id, 'template', p_template, 'to_last4', right(v_to, 4)));

  return v_id;
end;
$$;

revoke all on function public.send_staff_whatsapp(uuid, text, uuid, text, text, jsonb, text, uuid) from public, anon;
grant execute on function public.send_staff_whatsapp(uuid, text, uuid, text, text, jsonb, text, uuid) to authenticated, service_role;

-- the unchecked stub is no longer reachable from a client session
revoke execute on function public.send_whatsapp_stub(uuid, text, uuid, text, text, jsonb, text, uuid) from public, anon, authenticated;

-- ── create_purchase_order: only the final call changes (live body otherwise unchanged) ─────────────────────────────────
create or replace function public.create_purchase_order(p_org_id uuid, p_supplier_id uuid, p_items jsonb)
returns uuid
language plpgsql
as $$
declare
  v_po_id uuid;
  v_total numeric(12, 2) := 0;
  v_item record;
  v_threshold numeric(12, 2);
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_purchase_order: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_purchase_order: caller is not ops staff';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'create_purchase_order: at least one item is required';
  end if;

  select po_approval_threshold into v_threshold from public.settings where org_id = p_org_id;

  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (p_org_id, p_supplier_id, 'draft', 0, 'whatsapp')
  returning id into v_po_id;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    if v_item.qty is null or v_item.qty <= 0 then
      continue;
    end if;
    insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
    values (p_org_id, v_po_id, v_item.item_type, v_item.item_id, v_item.qty, coalesce(v_item.price, 0));
    v_total := v_total + (v_item.qty * coalesce(v_item.price, 0));
  end loop;

  update public.purchase_orders set total = v_total, status = 'sent' where id = v_po_id;

  perform public._create_po_payment_reminder_task(v_po_id);

  -- a supplier with no usable WhatsApp number used to get a number-less outbox row (never sent); keep the PO
  -- working in that case instead of failing the whole order on the checked door's number validation
  if length(regexp_replace(coalesce((select whatsapp from public.suppliers where id = p_supplier_id), ''), '[^0-9]', '', 'g')) >= 10 then
    perform public.send_staff_whatsapp(
      p_org_id, (select whatsapp from public.suppliers where id = p_supplier_id), null,
      'po_sent', 'po.sent', jsonb_build_object('po_id', v_po_id, 'total', v_total), 'purchase_order', v_po_id
    );
  end if;

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'po', v_po_id, auth.uid(), 'pending');
  end if;

  return v_po_id;
end;
$$;
