-- Enquiry-video resolver (queue item 3, part 1). Design: docs/automations-flows-design.md sections 2.3, 7 (decisions 2, 3, 11) and 9.
-- READ-ONLY helpers: no table, no column, no trigger, no state or audit value is added here, and nothing is sent.
--
--   _automation_enquiry_video(org, product_id, spare_id, language, max_url_length)
--       Picks the one video link to put in the "enquiry video" message for an item.
--   _automation_lead_enquiry_video(org, lead_id, item_key, language, max_url_length)
--       Same, starting from a lead: the item is the event's item_key when given (enquiry.item_added carries the added item),
--       otherwise the lead's own first item (leads.product_id, else leads.spare_id).
--
-- Rules, as decided by the owner (docs/automations-flows-design.md section 7):
--   * Decision 3  first item only: one item per lead, never one message per item.
--   * Decision 2  an item with no usable video is a skip (ok = false), never a topic-video fallback: video_library is NOT read.
--   * Language (section 9, decision 11): the caller passes the message language (customer's preferred language, else login
--     language, else rule language, else English). Order: a video in that language, then a language-neutral (NULL) video, then the
--     English one. It never skips just because the Tamil video is missing; language_fallback tells the caller the customer's
--     language was not available (used for the master's "no Tamil video, English sent" note).
--   * Within a language, the first active video by sort_order, then created_at.
--   * The link must be https, trimmed, free of whitespace and at most p_max_url_length characters (default 60: WhatsApp template
--     variable hygiene, short links such as youtu.be). A video that fails this is not used; if that leaves nothing the reason is
--     'url_unusable', so the master can tell it from 'no_video'.
--
-- Result: ok = true with the video, or ok = false with a reason: no_item | item_not_found | lead_not_found | no_video | url_unusable.
-- Everything is org-scoped: a lead, product, spare or video of another organisation is never read.
-- Callers: the hand-off (service role). EXECUTE is revoked from PUBLIC, anon and authenticated.
-- Rollback: supabase/rollbacks/20261028100000_enquiry_video_resolver.rollback.sql

create function public._automation_enquiry_video(
  p_org_id         uuid,
  p_product_id     uuid,
  p_spare_id       uuid,
  p_language       text default 'en',
  p_max_url_length integer default 60
)
returns table (
  ok                boolean,
  reason            text,
  video_id          uuid,
  video_url         text,
  video_source      text,
  video_language    text,
  language_fallback boolean,
  item_kind         text,
  item_id           uuid,
  item_name         text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_lang     text := case when p_language in ('en', 'ta') then p_language else 'en' end;
  v_max      integer := greatest(coalesce(p_max_url_length, 60), 10);
  v_kind     text;
  v_id       uuid;
  v_name     text;
  v_vid      uuid;
  v_url      text;
  v_vlang    text;
  v_eligible integer;
begin
  if p_org_id is null then
    return query select false, 'no_item'::text, null::uuid, null::text, null::text, null::text, false, null::text, null::uuid, null::text;
    return;
  end if;

  if p_product_id is not null then
    select p.id, p.name into v_id, v_name from public.products p where p.id = p_product_id and p.org_id = p_org_id;
    v_kind := 'product';
  elsif p_spare_id is not null then
    select s.id, s.name into v_id, v_name from public.spares s where s.id = p_spare_id and s.org_id = p_org_id;
    v_kind := 'spare';
  else
    return query select false, 'no_item'::text, null::uuid, null::text, null::text, null::text, false, null::text, null::uuid, null::text;
    return;
  end if;

  if v_id is null then
    return query select false, 'item_not_found'::text, null::uuid, null::text, null::text, null::text, false, v_kind,
                        coalesce(p_product_id, p_spare_id), null::text;
    return;
  end if;

  -- item name for the template variable: control characters and runs of whitespace become one space, at most 60 characters
  v_name := left(btrim(regexp_replace(regexp_replace(coalesce(v_name, ''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g')), 60);

  if v_kind = 'product' then
    select count(*) into v_eligible from public.product_videos v
     where v.org_id = p_org_id and v.product_id = v_id and v.is_active
       and (v.language is null or v.language = v_lang or v.language = 'en');
    select v.id, btrim(v.url), v.language into v_vid, v_url, v_vlang
      from public.product_videos v
     where v.org_id = p_org_id and v.product_id = v_id and v.is_active
       and (v.language is null or v.language = v_lang or v.language = 'en')
       and btrim(v.url) ~* '^https://[^[:space:]]+$' and char_length(btrim(v.url)) <= v_max
     order by case when v.language = v_lang then 0 when v.language is null then 1 else 2 end, v.sort_order, v.created_at, v.id
     limit 1;
  else
    select count(*) into v_eligible from public.spare_videos v
     where v.org_id = p_org_id and v.spare_id = v_id and v.is_active
       and (v.language is null or v.language = v_lang or v.language = 'en');
    select v.id, btrim(v.url), v.language into v_vid, v_url, v_vlang
      from public.spare_videos v
     where v.org_id = p_org_id and v.spare_id = v_id and v.is_active
       and (v.language is null or v.language = v_lang or v.language = 'en')
       and btrim(v.url) ~* '^https://[^[:space:]]+$' and char_length(btrim(v.url)) <= v_max
     order by case when v.language = v_lang then 0 when v.language is null then 1 else 2 end, v.sort_order, v.created_at, v.id
     limit 1;
  end if;

  if v_vid is null then
    return query select false, case when v_eligible > 0 then 'url_unusable' else 'no_video' end, null::uuid, null::text,
                        null::text, null::text, false, v_kind, v_id, v_name;
    return;
  end if;

  return query select true, null::text, v_vid, v_url,
                      case when v_kind = 'product' then 'product_videos' else 'spare_videos' end,
                      v_vlang, (v_lang = 'ta' and v_vlang is distinct from 'ta'), v_kind, v_id, v_name;
end;
$$;
revoke all on function public._automation_enquiry_video(uuid, uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public._automation_enquiry_video(uuid, uuid, uuid, text, integer) to service_role;

create function public._automation_lead_enquiry_video(
  p_org_id         uuid,
  p_lead_id        uuid,
  p_item_key       text default null,
  p_language       text default 'en',
  p_max_url_length integer default 60
)
returns table (
  ok                boolean,
  reason            text,
  video_id          uuid,
  video_url         text,
  video_source      text,
  video_language    text,
  language_fallback boolean,
  item_kind         text,
  item_id           uuid,
  item_name         text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_lead    public.leads;
  v_key     uuid;
  v_product uuid;
  v_spare   uuid;
begin
  select * into v_lead from public.leads l where l.id = p_lead_id and l.org_id = p_org_id;
  if not found then
    return query select false, 'lead_not_found'::text, null::uuid, null::text, null::text, null::text, false, null::text, null::uuid, null::text;
    return;
  end if;

  if nullif(btrim(coalesce(p_item_key, '')), '') is not null then
    begin
      v_key := btrim(p_item_key)::uuid;
    exception when others then
      return query select false, 'item_not_found'::text, null::uuid, null::text, null::text, null::text, false, null::text, null::uuid, null::text;
      return;
    end;
    if exists (select 1 from public.products p where p.id = v_key and p.org_id = p_org_id) then
      v_product := v_key;
    elsif exists (select 1 from public.spares s where s.id = v_key and s.org_id = p_org_id) then
      v_spare := v_key;
    else
      return query select false, 'item_not_found'::text, null::uuid, null::text, null::text, null::text, false, null::text, v_key, null::text;
      return;
    end if;
  else
    v_product := v_lead.product_id;
    v_spare := case when v_lead.product_id is null then v_lead.spare_id end;
  end if;

  return query select * from public._automation_enquiry_video(p_org_id, v_product, v_spare, p_language, p_max_url_length);
end;
$$;
revoke all on function public._automation_lead_enquiry_video(uuid, uuid, text, text, integer) from public, anon, authenticated;
grant execute on function public._automation_lead_enquiry_video(uuid, uuid, text, text, integer) to service_role;
