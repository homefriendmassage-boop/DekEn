-- =============================================================================
-- migration_074.sql — run ONCE after migration_073.sql
-- Admin: check every public (mosaicked) teaser photo.
--   * list the photos of all providers (search, "flagged only"), zoom, flag a photo ("แจ้งแก้": a LINE Flex to the girl and / or her agency),
--     close a flag, or place the mosaic himself from the private original (the new public file replaces the old one)
--   * the girl sees a notice on her page while a flag is open; the agency sees a badge on that girl
-- =============================================================================
create table if not exists public.teaser_flags (
  id          uuid primary key default gen_random_uuid(),
  worker_id   uuid not null,
  note        text,
  notify      text,
  flagged_by  uuid,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid
);
create unique index if not exists teaser_flags_one_open on public.teaser_flags (worker_id) where resolved_at is null;
alter table public.teaser_flags enable row level security;
revoke all on public.teaser_flags from anon, authenticated;

create or replace function public.admin_teaser_list(p_q text default null, p_flagged boolean default false, p_limit int default 30, p_offset int default 0)
returns table (worker_id uuid, display_name text, agency_name text, photo_id uuid, sort_no int, public_url text, original_path text,
               is_cover boolean, flag_note text, flagged_at timestamptz, rn int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
  with ws as (
    select w.user_id, w.display_name, w.agency_id, w.profile_image, f.note, f.created_at as fat,
           (row_number() over (order by (f.id is not null) desc, w.created_at desc, w.user_id))::int as rn
      from public.workers w
      left join public.teaser_flags f on f.worker_id = w.user_id and f.resolved_at is null
     where w.deleted_at is null
       and (p_q is null or btrim(p_q) = '' or w.display_name ilike '%' || btrim(p_q) || '%')
       and (not coalesce(p_flagged, false) or f.id is not null)
     order by 6
     limit least(greatest(coalesce(p_limit, 30), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
  )
  select ws.user_id, ws.display_name, a.name, pp.id, pp.sort_no::int, pp.public_url, pp.original_path,
         (pp.public_url = ws.profile_image), ws.note, ws.fat, ws.rn
    from ws
    join public.profile_photos pp on pp.user_id = ws.user_id and pp.state = 'live'
    left join public.agencies a on a.user_id = ws.agency_id
   order by ws.rn, pp.sort_no;
end $$;

-- p_notify: 'girl' | 'agency' | 'both'
create or replace function public.admin_teaser_flag(p_worker uuid, p_note text, p_notify text)
returns void language plpgsql security definer set search_path = public as $$
declare w public.workers; v_note text := nullif(left(btrim(coalesce(p_note, '')), 100), '');
begin
  perform public.assert_admin();
  if p_notify not in ('girl', 'agency', 'both') then raise exception 'BAD_INPUT'; end if;
  select * into w from public.workers where user_id = p_worker and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.teaser_flags (worker_id, note, notify, flagged_by) values (p_worker, v_note, p_notify, auth.uid())
  on conflict (worker_id) where resolved_at is null do update set note = excluded.note, notify = excluded.notify, flagged_by = excluded.flagged_by, created_at = now();
  if p_notify in ('girl', 'both') then perform public.approval_notify('mosaic', p_worker, 'flagged', v_note); end if;
  if p_notify in ('agency', 'both') and w.agency_id is not null and w.agency_id <> p_worker then
    perform public.approval_notify('mosaic', w.agency_id, 'flagged_agency', left(concat_ws(': ', w.display_name, v_note), 120));
  end if;
end $$;

create or replace function public.admin_teaser_resolve(p_worker uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.teaser_flags set resolved_at = now(), resolved_by = auth.uid() where worker_id = p_worker and resolved_at is null;
end $$;

-- the admin placed the mosaic: the new public file replaces the old one (same photo, same private original)
create or replace function public.admin_teaser_replace(p_photo uuid, p_public_url text)
returns void language plpgsql security definer set search_path = public as $$
declare pp public.profile_photos;
begin
  perform public.assert_admin();
  select * into pp from public.profile_photos where id = p_photo and state = 'live' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_public_url is null or position('/storage/v1/object/public/worker-public/' || pp.user_id::text || '/' in p_public_url) = 0 then raise exception 'BAD_INPUT'; end if;
  update public.profile_photos set public_url = p_public_url where id = pp.id;
  update public.workers set profile_image = p_public_url where user_id = pp.user_id and profile_image = pp.public_url;
  update public.teaser_flags set resolved_at = now(), resolved_by = auth.uid() where worker_id = pp.user_id and resolved_at is null;
end $$;

create or replace function public.my_teaser_flag()
returns table (note text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select f.note, f.created_at from public.teaser_flags f where f.worker_id = auth.uid() and f.resolved_at is null
$$;

create or replace function public.agency_flagged_girls()
returns table (worker_id uuid, note text)
language sql stable security definer set search_path = public as $$
  select f.worker_id, f.note from public.teaser_flags f
    join public.workers w on w.user_id = f.worker_id and w.agency_id = auth.uid()
   where f.resolved_at is null
$$;

-- the admin may write (and replace) files in worker-public, inside the girl's own folder name
drop policy if exists "worker-public_admin_insert" on storage.objects;
create policy "worker-public_admin_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'worker-public' and public.is_admin());
drop policy if exists "worker-public_admin_delete" on storage.objects;
create policy "worker-public_admin_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'worker-public' and public.is_admin());

revoke all on function public.admin_teaser_list(text, boolean, int, int), public.admin_teaser_flag(uuid, text, text), public.admin_teaser_resolve(uuid),
  public.admin_teaser_replace(uuid, text), public.my_teaser_flag(), public.agency_flagged_girls() from public, anon;
grant execute on function public.admin_teaser_list(text, boolean, int, int), public.admin_teaser_flag(uuid, text, text), public.admin_teaser_resolve(uuid),
  public.admin_teaser_replace(uuid, text), public.my_teaser_flag(), public.agency_flagged_girls() to authenticated;
