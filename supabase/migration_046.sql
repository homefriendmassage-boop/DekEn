-- =============================================================================
-- migration_046.sql — run ONCE after migration_045.sql
--   * bulk entry of many girls from the SQL Editor (see supabase/bulk_girls_template.sql):
--       bulk_create_drafts()   — one admin draft per pasted row (text fields, prices, tags, province); photos are added afterwards in the
--                                admin tab "➕ แบบร่างให้น้อง" (the face-cover step stays manual, one circle per photo)
--       bulk_publish_drafts()  — publishes every admin draft that already has photos, with ONE age-check / consent attestation
--   * seller panel: my_commission_report also returns the bookings of the customers I invited that paid me nothing (plan lapsed / not a seller)
-- =============================================================================

create or replace function public.bulk_create_drafts(p_admin uuid, p_rows jsonb)
returns table (draft_id uuid, display_name text, grp text)
language plpgsql security definer set search_path = public as $$
declare r jsonb; v_id uuid; v_grp text; v_cats text[]; v_opts jsonb; v_start text; v_price numeric; k text; v_val numeric; v_tags text[];
begin
  if not exists (select 1 from public.admins where user_id = p_admin) then raise exception 'NOT_ADMIN'; end if;
  perform set_config('request.jwt.claim.sub', p_admin::text, true);          -- draft_save() runs as this admin
  for r in select * from jsonb_array_elements(p_rows) loop
    v_grp := coalesce(nullif(r->>'grp', ''), 'night');
    v_cats := string_to_array(replace(coalesce(r->>'category', ''), ' ', ''), ',');
    if v_grp not in ('night', 'spa') then raise exception 'BAD_GROUP: %', r->>'name'; end if;
    if v_grp = 'night' and not (v_cats <@ array['bartender', 'ent']) then raise exception 'BAD_CATEGORY (night = bartender / ent): %', r->>'name'; end if;
    if v_grp = 'spa' and not (v_cats <@ array['masseuse', 'spa']) then raise exception 'BAD_CATEGORY (spa = masseuse / spa): %', r->>'name'; end if;
    v_opts := '[]'::jsonb; v_start := null; v_price := 0;
    foreach k in array case when v_grp = 'night' then array['@4h', '@6h', '1h'] else array['@60', '@90', '@120'] end loop
      v_val := nullif(r->>(case k when '@4h' then 'p4h' when '@6h' then 'p6h' when '1h' then 'p1h' when '@60' then 'p60' when '@90' then 'p90' else 'p120' end), '')::numeric;
      if v_val is not null and v_val > 0 then
        v_opts := v_opts || jsonb_build_array(jsonb_build_object('label', k, 'price', v_val));
        if v_start is null then v_start := k; v_price := v_val; end if;
      end if;
    end loop;
    if v_start is null then raise exception 'NO_PRICE: %', r->>'name'; end if;
    v_tags := string_to_array(replace(coalesce(r->>'tags', ''), ' ', ''), ',');
    v_id := public.draft_save(null, jsonb_strip_nulls(jsonb_build_object(
      'display_name', btrim(r->>'name'), 'categories', to_jsonb(v_cats), 'gender', nullif(r->>'gender', ''), 'age', nullif(r->>'age', '')::int,
      'height_cm', nullif(r->>'height', '')::int, 'weight_kg', nullif(r->>'weight', '')::int, 'measurements', nullif(r->>'measurements', ''),
      'tags', to_jsonb(coalesce(v_tags, '{}')), 'about', nullif(r->>'about', ''), 'price', v_price, 'price_options', v_opts, 'start_rate', v_start,
      'service_mode', case when v_grp = 'spa' then coalesce(nullif(r->>'mode', ''), 'both') end,
      'province', nullif(r->>'province', ''), 'district', nullif(r->>'district', ''), 'nearby', nullif(r->>'nearby', ''),
      'phone', nullif(r->>'phone', ''), 'line_id', nullif(r->>'line_id', ''), 'note', nullif(r->>'note', ''))));
    update public.application_drafts set grp = v_grp where id = v_id;
    draft_id := v_id; display_name := btrim(r->>'name'); grp := v_grp;
    return next;
  end loop;
end $$;

-- every admin draft that has at least one photo and a province becomes a live (not yet claimed) profile
create or replace function public.bulk_publish_drafts(p_admin uuid, p_age_method text, p_consent_note text)
returns table (draft_id uuid, display_name text, result text)
language plpgsql security definer set search_path = public as $$
declare d record;
begin
  if not exists (select 1 from public.admins where user_id = p_admin) then raise exception 'NOT_ADMIN'; end if;
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  for d in select x.id, x.display_name, x.province from public.application_drafts x
            where x.source = 'admin' and x.status = 'draft' and x.managed_user_id is null and x.created_by = p_admin
              and exists (select 1 from public.draft_photos p where p.draft_id = x.id)
            order by x.created_at loop
    draft_id := d.id; display_name := d.display_name;
    begin
      if d.province is null then raise exception 'NO_PROVINCE'; end if;
      perform public.admin_publish_draft(d.id, d.province, p_age_method, p_consent_note);
      result := 'PUBLISHED';
    exception when others then
      result := 'SKIPPED: ' || sqlerrm;
    end;
    return next;
  end loop;
end $$;
revoke all on function public.bulk_create_drafts(uuid, jsonb), public.bulk_publish_drafts(uuid, text, text) from public, anon, authenticated;

-- ---------- seller panel: what the invited customers' bookings paid me nothing ----------------------------------------------------------------
create or replace function public.my_commission_report()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
    'booking_total', coalesce((select sum(amount) from public.booking_shares where beneficiary = auth.uid() and role = 'sales'), 0),
    'package_total', coalesce((select sum(amount) from public.referral_rewards where beneficiary = auth.uid()), 0),
    'missed_count', (select count(*) from public.jobs j join public.users c on c.id = j.customer_id
                      where c.referred_by = auth.uid() and j.sales_vendor is null and j.status in ('matched', 'completed')
                        and not exists (select 1 from public.booking_shares s where s.job_id = j.id and s.role = 'sales')),
    'missed_amount', coalesce((select sum(round(j.booking_fee * public.booking_share_sales_rate(), 2)) from public.jobs j join public.users c on c.id = j.customer_id
                      where c.referred_by = auth.uid() and j.sales_vendor is null and j.status in ('matched', 'completed')
                        and not exists (select 1 from public.booking_shares s where s.job_id = j.id and s.role = 'sales')), 0),
    'bookings', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('at', s.created_at, 'amount', s.amount, 'customer', c.display_name,
               'via', case when j.sales_vendor is not null then 'link' else 'invited' end) as x
          from public.booking_shares s join public.jobs j on j.id = s.job_id join public.users c on c.id = j.customer_id
         where s.beneficiary = auth.uid() and s.role = 'sales' order by s.created_at desc limit 100) q), '[]'::jsonb),
    'packages', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('at', r.created_at, 'amount', r.amount, 'customer', p.display_name) as x
          from public.referral_rewards r join public.users p on p.id = r.payer
         where r.beneficiary = auth.uid() order by r.created_at desc limit 100) q), '[]'::jsonb));
end $$;
