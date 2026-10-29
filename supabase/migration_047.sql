-- =============================================================================
-- migration_047.sql — run ONCE after migration_046.sql
-- Any admin can edit an ADMIN draft (text, photos), not only the admin who created it. Before, drafts made with bulk_create_drafts() under
-- another admin's id could be seen but not saved ("บันทึกไม่สำเร็จ": NOT_FOUND / storage permission).
-- =============================================================================

create or replace function public.draft_save(p_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.application_drafts; d public.application_drafts; v_id uuid;
  v_admin boolean := public.is_admin(); v_agency uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if not v_admin then
    select user_id into v_agency from public.agencies where user_id = auth.uid() and status = 'approved';
    if v_agency is null or not public.agency_active(v_agency) then raise exception 'PLAN_INACTIVE'; end if;
  end if;
  r := jsonb_populate_record(null::public.application_drafts, coalesce(p_data, '{}'::jsonb));
  if r.categories is null or coalesce(array_length(r.categories, 1), 0) = 0 or btrim(coalesce(r.display_name, '')) = '' then raise exception 'BAD_INPUT'; end if;
  -- the province written here is only a temporary guess; the girl confirms her place by GPS when she accepts the link
  r.province := nullif(btrim(coalesce(r.province, '')), '');
  if r.province is not null and not exists (select 1 from public.province_centroids where name = r.province) then raise exception 'BAD_PROVINCE'; end if;

  if p_id is null then
    if (select count(*) from public.application_drafts where created_by = auth.uid() and status in ('draft', 'submitted', 'approved', 'rejected')) >= 40 then
      raise exception 'TOO_MANY_DRAFTS';
    end if;
    insert into public.application_drafts (created_by, source, agency_id, display_name, categories, gender, age, height_cm, weight_kg, measurements,
                                           tags, about, price, price_options, start_rate, service_mode, province, district, nearby, phone, line_id, note)
    values (auth.uid(), case when v_admin then 'admin' else 'agency' end, case when v_admin then null else v_agency end,
            r.display_name, r.categories, r.gender, r.age, r.height_cm, r.weight_kg, r.measurements,
            coalesce(r.tags, '{}'), r.about, coalesce(r.price, 0), coalesce(r.price_options, '[]'::jsonb), r.start_rate, r.service_mode,
            r.province, r.district, r.nearby, nullif(btrim(coalesce(r.phone, '')), ''), nullif(btrim(coalesce(r.line_id, '')), ''), left(r.note, 300))
    returning id into v_id;
    return v_id;
  end if;

  select * into d from public.application_drafts where id = p_id and (created_by = auth.uid() or (public.is_admin() and source = 'admin')) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected', 'approved', 'expired') then raise exception 'LOCKED'; end if;
  update public.application_drafts set
    display_name = r.display_name, categories = r.categories, gender = r.gender, age = r.age, height_cm = r.height_cm, weight_kg = r.weight_kg,
    measurements = r.measurements, tags = coalesce(r.tags, '{}'), about = r.about, price = coalesce(r.price, 0),
    price_options = coalesce(r.price_options, '[]'::jsonb), start_rate = r.start_rate, service_mode = r.service_mode,
    province = coalesce(r.province, d.province), district = r.district, nearby = r.nearby, phone = nullif(btrim(coalesce(r.phone, '')), ''), line_id = nullif(btrim(coalesce(r.line_id, '')), ''),
    note = left(r.note, 300), updated_at = now(),
    -- an agency's change after approval needs a new approval; an admin's own draft keeps its link
    status = case when v_admin then (case when d.status = 'expired' then 'draft' else d.status end) else 'draft' end,
    token = case when v_admin then d.token else null end,
    reject_reason = null
   where id = p_id;
  perform public.sync_managed_profile(p_id);
  return p_id;
end $$;

create or replace function public.draft_attach_photo(p_draft uuid, p_public_url text, p_original_path text)
returns uuid language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_n int; v_id uuid;
begin
  select * into d from public.application_drafts where id = p_draft and (created_by = auth.uid() or (public.is_admin() and source = 'admin')) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected', 'approved', 'expired') then raise exception 'LOCKED'; end if;
  if p_original_path is null or p_original_path not like p_draft::text || '/%' or p_public_url is null then raise exception 'BAD_INPUT'; end if;
  select count(*) into v_n from public.draft_photos where draft_id = p_draft;
  if v_n >= 5 then raise exception 'TOO_MANY_PHOTOS'; end if;
  insert into public.draft_photos (draft_id, sort_no, public_url, original_path) values (p_draft, v_n + 1, p_public_url, p_original_path) returning id into v_id;
  if d.source = 'agency' and d.status <> 'draft' then
    update public.application_drafts set status = 'draft', token = null, updated_at = now() where id = p_draft;
  end if;
  perform public.sync_managed_profile(p_draft);
  return v_id;
end $$;

create or replace function public.draft_remove_photo(p_photo uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_path text; v_draft uuid; d public.application_drafts;
begin
  select dp.original_path, dp.draft_id into v_path, v_draft from public.draft_photos dp where dp.id = p_photo;
  select * into d from public.application_drafts where id = v_draft and (created_by = auth.uid() or (public.is_admin() and source = 'admin')) and status in ('draft', 'rejected', 'approved', 'expired');
  if v_path is null or not found then raise exception 'NOT_FOUND'; end if;
  delete from public.draft_photos where id = p_photo;
  if d.source = 'agency' and d.status <> 'draft' then
    update public.application_drafts set status = 'draft', token = null, updated_at = now() where id = d.id;
  end if;
  perform public.sync_managed_profile(d.id);
  return v_path;
end $$;

revoke all on function public.draft_save(uuid, jsonb), public.draft_attach_photo(uuid, text, text), public.draft_remove_photo(uuid) from public, anon;
grant execute on function public.draft_save(uuid, jsonb), public.draft_attach_photo(uuid, text, text), public.draft_remove_photo(uuid) to authenticated;

do $$
declare b text;
begin
  foreach b in array array['worker-public', 'worker-originals'] loop
    execute format('drop policy if exists "%1$s_insert" on storage.objects', b);
    execute format($p$create policy "%1$s_insert" on storage.objects for insert to authenticated
      with check (bucket_id = %1$L and (
        ((storage.foldername(name))[1] = auth.uid()::text
          and (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'worker')
            or exists (select 1 from public.worker_applications a where a.user_id = auth.uid() and a.status = 'pending')))
        or exists (select 1 from public.application_drafts d where d.id::text = (storage.foldername(name))[1]
                     and (d.created_by = auth.uid() or (public.is_admin() and d.source = 'admin')) and d.status in ('draft', 'rejected', 'approved'))))$p$, b);
    execute format('drop policy if exists "%1$s_delete" on storage.objects', b);
    execute format($p$create policy "%1$s_delete" on storage.objects for delete to authenticated
      using (bucket_id = %1$L and ((storage.foldername(name))[1] = auth.uid()::text
        or exists (select 1 from public.application_drafts d where d.id::text = (storage.foldername(name))[1]
                     and (d.created_by = auth.uid() or (public.is_admin() and d.source = 'admin')))))$p$, b);
  end loop;
end $$;
