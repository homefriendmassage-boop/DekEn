-- =============================================================================
-- migration_034.sql — run ONCE after migration_033.sql
-- Application drafts: someone else fills in a provider's application and she only confirms.
--   * source 'admin'  : an admin fills it in, issues a link at once (no review needed).
--   * source 'agency' : a modelling agency fills it in -> submits to an admin -> admin approves (the link is issued) or
--                       rejects with a reason -> the agency sends the link to the girl.
--   * The girl opens the link with HER OWN LINE, sees the data, confirms her location (GPS), ticks 20+ / consent to the
--     photos and data / terms, and (admin drafts only) chooses self-application or an agency. That creates a normal
--     pending application (age check + approval as usual). An agency draft always joins that agency (slots are counted then).
--   * A link lives 3 days from when it is issued, works once, and can be re-issued (admin, or the agency for an
--     already approved draft).
--   * Photos are uploaded into the folder <draft id>/ and follow the girl after she claims the draft.
-- =============================================================================

create table if not exists public.application_drafts (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references public.users (id) on delete cascade,
  source text not null check (source in ('admin', 'agency')),
  agency_id uuid references public.agencies (user_id),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'approved', 'rejected', 'claimed', 'expired', 'cancelled')),
  grp text not null default 'night',
  display_name text not null,
  categories text[] not null,
  gender text, age int check (age is null or age between 20 and 70), height_cm int, weight_kg int, measurements text,
  tags text[] not null default '{}', about text,
  price numeric(12,2) not null default 0, price_options jsonb not null default '[]'::jsonb, start_rate text, service_mode text,
  district text, nearby text, phone text, line_id text, note text,
  -- unused here, but the shared profile trigger reads them
  province text, loc_lat double precision, loc_lng double precision, loc_verified_at timestamptz,
  reject_reason text, reviewed_by uuid, reviewed_at timestamptz,
  token text unique, link_issued_at timestamptz, link_expires_at timestamptz,
  claimed_by uuid, claimed_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists application_drafts_idx on public.application_drafts (created_by, status);
alter table public.application_drafts enable row level security;
revoke all on public.application_drafts from anon, authenticated;

drop trigger if exists application_drafts_normalize on public.application_drafts;
create trigger application_drafts_normalize before insert or update on public.application_drafts
  for each row execute function public.normalize_worker_profile();

create table if not exists public.draft_photos (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.application_drafts (id) on delete cascade,
  sort_no smallint not null default 1,
  public_url text not null, original_path text not null,
  created_at timestamptz not null default now()
);
alter table public.draft_photos enable row level security;
revoke all on public.draft_photos from anon, authenticated;

-- a draft's folder belongs to the girl once she has claimed it (storage policy below)
create table if not exists public.draft_owner_map (draft_id uuid primary key, user_id uuid not null);
alter table public.draft_owner_map enable row level security;
revoke all on public.draft_owner_map from anon, authenticated;
create or replace function public.photo_owner(f uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce((select m.user_id from public.draft_owner_map m where m.draft_id = f), f)
$$;
revoke all on function public.photo_owner(uuid) from public, anon;
grant execute on function public.photo_owner(uuid) to authenticated;

-- ---------- storage: the creator uploads into <draft id>/, the girl reads her originals after claiming ----------
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
                     and d.created_by = auth.uid() and d.status in ('draft', 'rejected', 'approved'))))$p$, b);
    execute format('drop policy if exists "%1$s_delete" on storage.objects', b);
    execute format($p$create policy "%1$s_delete" on storage.objects for delete to authenticated
      using (bucket_id = %1$L and ((storage.foldername(name))[1] = auth.uid()::text
        or exists (select 1 from public.application_drafts d where d.id::text = (storage.foldername(name))[1] and d.created_by = auth.uid())))$p$, b);
  end loop;
end $$;
drop policy if exists "worker-originals_select" on storage.objects;
create policy "worker-originals_select" on storage.objects for select to authenticated
  using (bucket_id = 'worker-originals' and public.can_view_worker(public.photo_owner(((storage.foldername(name))[1])::uuid)));

-- ---------- helpers -----------------------------------------------------------------------
create or replace function public.draft_view(d public.application_drafts)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(d) - 'token' - 'province' - 'loc_lat' - 'loc_lng' - 'loc_verified_at'
         || jsonb_build_object(
              'token', case when d.status = 'approved' and d.link_expires_at > now() then d.token end,
              'link_active', d.status = 'approved' and d.link_expires_at > now(),
              'link_expired', d.status = 'expired' or (d.status = 'approved' and d.link_expires_at <= now()),
              'agency_name', (select a.name from public.agencies a where a.user_id = d.agency_id),
              'creator_name', (select u.display_name from public.users u where u.id = d.created_by),
              'photos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'public_url', p.public_url, 'original_path', p.original_path) order by p.sort_no)
                                    from public.draft_photos p where p.draft_id = d.id), '[]'::jsonb))
$$;
revoke all on function public.draft_view(public.application_drafts) from public, anon, authenticated;

create or replace function public.draft_new_token()
returns text language sql volatile as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

-- create / update a draft (admin: any; agency: only while its plan is active)
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

  if p_id is null then
    if (select count(*) from public.application_drafts where created_by = auth.uid() and status in ('draft', 'submitted', 'approved', 'rejected')) >= 40 then
      raise exception 'TOO_MANY_DRAFTS';
    end if;
    insert into public.application_drafts (created_by, source, agency_id, display_name, categories, gender, age, height_cm, weight_kg, measurements,
                                           tags, about, price, price_options, start_rate, service_mode, district, nearby, phone, line_id, note)
    values (auth.uid(), case when v_admin then 'admin' else 'agency' end, case when v_admin then null else v_agency end,
            r.display_name, r.categories, r.gender, r.age, r.height_cm, r.weight_kg, r.measurements,
            coalesce(r.tags, '{}'), r.about, coalesce(r.price, 0), coalesce(r.price_options, '[]'::jsonb), r.start_rate, r.service_mode,
            r.district, r.nearby, nullif(btrim(coalesce(r.phone, '')), ''), nullif(btrim(coalesce(r.line_id, '')), ''), left(r.note, 300))
    returning id into v_id;
    return v_id;
  end if;

  select * into d from public.application_drafts where id = p_id and created_by = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected', 'approved', 'expired') then raise exception 'LOCKED'; end if;
  update public.application_drafts set
    display_name = r.display_name, categories = r.categories, gender = r.gender, age = r.age, height_cm = r.height_cm, weight_kg = r.weight_kg,
    measurements = r.measurements, tags = coalesce(r.tags, '{}'), about = r.about, price = coalesce(r.price, 0),
    price_options = coalesce(r.price_options, '[]'::jsonb), start_rate = r.start_rate, service_mode = r.service_mode,
    district = r.district, nearby = r.nearby, phone = nullif(btrim(coalesce(r.phone, '')), ''), line_id = nullif(btrim(coalesce(r.line_id, '')), ''),
    note = left(r.note, 300), updated_at = now(),
    -- an agency's change after approval needs a new approval; an admin's own draft keeps its link
    status = case when v_admin then (case when d.status = 'expired' then 'draft' else d.status end) else 'draft' end,
    token = case when v_admin then d.token else null end,
    reject_reason = null
   where id = p_id;
  return p_id;
end $$;

-- the creator attaches a picture that is already uploaded under <draft id>/ (max 5)
create or replace function public.draft_attach_photo(p_draft uuid, p_public_url text, p_original_path text)
returns uuid language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_n int; v_id uuid;
begin
  select * into d from public.application_drafts where id = p_draft and created_by = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected', 'approved', 'expired') then raise exception 'LOCKED'; end if;
  if p_original_path is null or p_original_path not like p_draft::text || '/%' or p_public_url is null then raise exception 'BAD_INPUT'; end if;
  select count(*) into v_n from public.draft_photos where draft_id = p_draft;
  if v_n >= 5 then raise exception 'TOO_MANY_PHOTOS'; end if;
  insert into public.draft_photos (draft_id, sort_no, public_url, original_path) values (p_draft, v_n + 1, p_public_url, p_original_path) returning id into v_id;
  if d.source = 'agency' and d.status <> 'draft' then
    update public.application_drafts set status = 'draft', token = null, updated_at = now() where id = p_draft;
  end if;
  return v_id;
end $$;

create or replace function public.draft_remove_photo(p_photo uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_path text; v_draft uuid; d public.application_drafts;
begin
  select dp.original_path, dp.draft_id into v_path, v_draft from public.draft_photos dp where dp.id = p_photo;
  select * into d from public.application_drafts where id = v_draft and created_by = auth.uid() and status in ('draft', 'rejected', 'approved', 'expired');
  if v_path is null or not found then raise exception 'NOT_FOUND'; end if;
  delete from public.draft_photos where id = p_photo;
  if d.source = 'agency' and d.status <> 'draft' then
    update public.application_drafts set status = 'draft', token = null, updated_at = now() where id = d.id;
  end if;
  return v_path;
end $$;

create or replace function public.my_drafts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(public.draft_view(d) order by d.updated_at desc)
                     from (select * from public.application_drafts where created_by = auth.uid() order by updated_at desc limit 100) d), '[]'::jsonb);
end $$;

-- agency: send the finished draft to an admin
create or replace function public.draft_submit(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.application_drafts;
begin
  select * into d from public.application_drafts where id = p_id and created_by = auth.uid() and source = 'agency' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected') then raise exception 'LOCKED'; end if;
  if not exists (select 1 from public.draft_photos where draft_id = p_id) then raise exception 'NO_PHOTO'; end if;
  if not public.agency_active(d.agency_id) then raise exception 'PLAN_INACTIVE'; end if;
  update public.application_drafts set status = 'submitted', reject_reason = null, updated_at = now() where id = p_id;
end $$;

-- issue (or re-issue) the link: 3 days, new token. Admin: own drafts; agency: only a draft an admin already approved.
create or replace function public.draft_issue_link(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_tok text := public.draft_new_token(); v_admin boolean := public.is_admin();
begin
  select * into d from public.application_drafts where id = p_id and (created_by = auth.uid() or v_admin) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.source = 'agency' and not v_admin then
    if d.status not in ('approved', 'expired') then raise exception 'NOT_APPROVED'; end if;
    if not public.agency_active(d.agency_id) then raise exception 'PLAN_INACTIVE'; end if;
  else
    if d.status not in ('draft', 'approved', 'expired') and not (v_admin and d.status = 'submitted') then raise exception 'LOCKED'; end if;
  end if;
  if not exists (select 1 from public.draft_photos where draft_id = p_id) then raise exception 'NO_PHOTO'; end if;
  update public.application_drafts set status = 'approved', token = v_tok, link_issued_at = now(), link_expires_at = now() + interval '3 days',
         reviewed_by = case when v_admin then auth.uid() else reviewed_by end, reviewed_at = case when v_admin then now() else reviewed_at end,
         updated_at = now() where id = p_id;
  return v_tok;
end $$;

create or replace function public.draft_cancel(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.application_drafts set status = 'cancelled', token = null, updated_at = now()
   where id = p_id and (created_by = auth.uid() or public.is_admin()) and status in ('draft', 'submitted', 'approved', 'rejected', 'expired');
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

create or replace function public.expire_drafts()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.application_drafts set status = 'expired', updated_at = now() where status = 'approved' and link_expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.expire_drafts() from public, anon, authenticated;

-- ---------- admin ------------------------------------------------------------------------
create or replace function public.admin_drafts_list(p_filter text default 'review')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(public.draft_view(d) order by d.updated_at desc)
                     from (select * from public.application_drafts x
                            where case p_filter when 'review' then x.status = 'submitted'
                                                when 'links' then x.status in ('approved', 'expired') or (x.status = 'draft' and x.source = 'admin')
                                                else true end
                            order by x.updated_at desc limit 100) d), '[]'::jsonb);
end $$;

create or replace function public.admin_draft_review(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare d public.application_drafts;
begin
  perform public.assert_admin();
  select * into d from public.application_drafts where id = p_id and status = 'submitted' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_approve then
    perform public.draft_issue_link(p_id);
  else
    update public.application_drafts set status = 'rejected', reject_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300),
           reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now() where id = p_id;
  end if;
end $$;

-- ---------- the girl -----------------------------------------------------------------------
create or replace function public.claim_preview(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d public.application_drafts;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into d from public.application_drafts where token = p_token;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status = 'claimed' then raise exception 'USED'; end if;
  if d.status <> 'approved' or d.link_expires_at <= now() then raise exception 'EXPIRED'; end if;
  return jsonb_build_object(
    'source', d.source, 'grp', d.grp, 'display_name', d.display_name, 'categories', d.categories, 'gender', d.gender, 'age', d.age,
    'height_cm', d.height_cm, 'weight_kg', d.weight_kg, 'measurements', d.measurements, 'tags', d.tags, 'about', d.about,
    'price_options', d.price_options, 'start_rate', d.start_rate, 'service_mode', d.service_mode, 'district', d.district, 'nearby', d.nearby,
    'phone', d.phone, 'line_id', d.line_id, 'expires_at', d.link_expires_at,
    'agency_name', (select a.name from public.agencies a where a.user_id = d.agency_id),
    'agency_logo', (select a.logo_path from public.agencies a where a.user_id = d.agency_id),
    'photos', coalesce((select jsonb_agg(p.public_url order by p.sort_no) from public.draft_photos p where p.draft_id = d.id), '[]'::jsonb),
    'already_provider', exists (select 1 from public.workers w where w.user_id = auth.uid() and w.deleted_at is null)
                        or exists (select 1 from public.worker_applications x where x.user_id = auth.uid() and x.status = 'pending'));
end $$;

-- p_choice: 'self' | 'agency' (admin drafts only; an agency draft always joins its agency)
create or replace function public.claim_draft(p_token text, p_lat double precision, p_lng double precision, p_choice text default 'self',
                                              p_agency_code text default null, p_phone text default null, p_line_id text default null,
                                              p_adult boolean default false, p_consent boolean default false, p_terms boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_code text; v_phone text; v_line text; v_app uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into d from public.application_drafts where token = p_token for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status = 'claimed' then raise exception 'USED'; end if;
  if d.status <> 'approved' or d.link_expires_at <= now() then raise exception 'EXPIRED'; end if;
  if not (coalesce(p_adult, false) and coalesce(p_consent, false) and coalesce(p_terms, false)) then raise exception 'CONSENT_REQUIRED'; end if;
  if p_lat is null or p_lng is null then raise exception 'LOCATION_REQUIRED'; end if;
  if exists (select 1 from public.workers w where w.user_id = auth.uid() and w.deleted_at is null)
     or exists (select 1 from public.worker_applications x where x.user_id = auth.uid() and x.status = 'pending') then
    raise exception 'ALREADY_PROVIDER';
  end if;
  if d.source = 'agency' then
    select a.code into v_code from public.agencies a where a.user_id = d.agency_id;
  elsif p_choice = 'agency' then
    v_code := nullif(btrim(coalesce(p_agency_code, '')), '');
    if v_code is null then raise exception 'AGENCY_CODE_REQUIRED'; end if;
  end if;
  v_phone := coalesce(nullif(btrim(coalesce(p_phone, '')), ''), d.phone);
  v_line := coalesce(nullif(btrim(coalesce(p_line_id, '')), ''), d.line_id);
  if v_phone is null and v_line is null then raise exception 'CONTACT_REQUIRED'; end if;

  insert into public.worker_applications (user_id, display_name, categories, price, price_options, start_rate, service_mode, district, nearby,
                                          phone, line_id, note, gender, age, height_cm, weight_kg, measurements, tags, about,
                                          loc_lat, loc_lng, accepted_terms, agency_code)
  values (auth.uid(), d.display_name, d.categories, d.price, d.price_options, d.start_rate, d.service_mode, d.district, d.nearby,
          v_phone, v_line, left(concat_ws(' ', d.note, '[แบบร่างจาก ' || case d.source when 'agency' then 'โมเดลลิ่ง' else 'แอดมิน' end || ']'), 300),
          d.gender, d.age, d.height_cm, d.weight_kg, d.measurements, d.tags, d.about, p_lat, p_lng, true, v_code)
  returning id into v_app;

  insert into public.profile_photos (user_id, state, sort_no, public_url, original_path)
    select auth.uid(), 'application', p.sort_no, p.public_url, p.original_path from public.draft_photos p where p.draft_id = d.id order by p.sort_no;
  insert into public.draft_owner_map (draft_id, user_id) values (d.id, auth.uid()) on conflict (draft_id) do update set user_id = excluded.user_id;
  update public.application_drafts set status = 'claimed', claimed_by = auth.uid(), claimed_at = now(), token = null, updated_at = now() where id = d.id;
  return v_app;
end $$;

revoke all on function public.draft_save(uuid, jsonb), public.draft_attach_photo(uuid, text, text), public.draft_remove_photo(uuid),
  public.my_drafts(), public.draft_submit(uuid), public.draft_issue_link(uuid), public.draft_cancel(uuid), public.admin_drafts_list(text),
  public.admin_draft_review(uuid, boolean, text), public.claim_preview(text),
  public.claim_draft(text, double precision, double precision, text, text, text, text, boolean, boolean, boolean) from public, anon;
grant execute on function public.draft_save(uuid, jsonb), public.draft_attach_photo(uuid, text, text), public.draft_remove_photo(uuid),
  public.my_drafts(), public.draft_submit(uuid), public.draft_issue_link(uuid), public.draft_cancel(uuid), public.admin_drafts_list(text),
  public.admin_draft_review(uuid, boolean, text), public.claim_preview(text),
  public.claim_draft(text, double precision, double precision, text, text, text, text, boolean, boolean, boolean) to authenticated;

do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('expire-application-drafts', '15 * * * *', 'select public.expire_drafts()');
exception when others then
  raise notice 'pg_cron is not enabled (%): links still stop working at their expiry time', sqlerrm;
end $$;
-- =============================================================================
