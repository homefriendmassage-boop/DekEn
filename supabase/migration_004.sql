-- =============================================================================
-- migration_004.sql — run ONCE after migration_003.sql
-- 1) Providers can serve several categories (workers.categories text[])
-- 2) Applications: separate phone / LINE ID, editable while pending, promo photo
-- =============================================================================

-- ---------- 1) Multi-category ------------------------------------------------
alter table public.workers add column if not exists categories text[] not null default '{}';
alter table public.worker_applications add column if not exists categories text[] not null default '{}';

-- Backfill from the old single column, then drop it (its check constraint goes with it).
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'workers' and column_name = 'category') then
    update public.workers set categories = array[category] where cardinality(categories) = 0;
    alter table public.workers drop column category;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'worker_applications' and column_name = 'category') then
    update public.worker_applications set categories = array[category] where cardinality(categories) = 0;
    alter table public.worker_applications drop column category;
  end if;
end $$;

alter table public.workers alter column categories drop default;
alter table public.worker_applications alter column categories drop default;
alter table public.workers drop constraint if exists workers_categories_check;
alter table public.workers add constraint workers_categories_check
  check (cardinality(categories) >= 1 and categories <@ array['bartender','ent','masseuse','spa']);
alter table public.worker_applications drop constraint if exists worker_applications_categories_check;
alter table public.worker_applications add constraint worker_applications_categories_check
  check (cardinality(categories) >= 1 and categories <@ array['bartender','ent','masseuse','spa']);

-- A provider may be visible through any of their categories (rank is per category).
create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid() or exists (
    select 1 from (
      select x.user_id, c as category,
             row_number() over (partition by c
               order by x.is_boosted desc, x.is_online desc, x.created_at, x.user_id)::int as rk
        from public.workers x, unnest(x.categories) c
    ) r
    where r.user_id = w and public.can_view_category(r.category, r.rk, public.viewer_tier())
  )
$$;

-- One row per (provider, category). `category` = the category being browsed.
drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t),
  r as (
    select w.*, c as cat,
           row_number() over (partition by c
             order by w.is_boosted desc, w.is_online desc, w.created_at, w.user_id)::int as rk
      from public.workers w, unnest(w.categories) c
  )
  select r.user_id, r.display_name, r.cat, r.categories, r.price, r.profile_image,
         case when public.can_view_category(r.cat, r.rk, tier.t) then r.original_path end,
         r.is_online, r.is_boosted, r.rk,
         public.can_view_category(r.cat, r.rk, tier.t),
         r.province, r.district, r.nearby
    from r, tier
   where p_category is null or r.cat = p_category
   order by r.cat, r.rk
$$;
revoke all on function public.list_workers(text) from public, anon;
grant execute on function public.list_workers(text) to authenticated;

-- ---------- 2) Applications --------------------------------------------------
alter table public.worker_applications
  add column if not exists phone         text,
  add column if not exists line_id       text,
  add column if not exists profile_image text,
  add column if not exists original_path text;

-- Keep whatever was typed in the old single "contact" field, in the note.
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'worker_applications' and column_name = 'contact') then
    update public.worker_applications
       set note = concat_ws(E'\n', note, 'contact: ' || contact) where contact is not null;
    alter table public.worker_applications drop column contact;
  end if;
end $$;

alter table public.worker_applications drop constraint if exists app_contact_check;
alter table public.worker_applications add constraint app_contact_check check (
  (phone is not null or line_id is not null)
  and (phone is null or phone ~ '^[0-9+ -]{8,20}$')
  and (line_id is null or char_length(line_id) between 2 and 40)
) not valid;  -- NOT VALID: rows created before this migration are not re-checked

-- Applicants may edit their own application while it is still pending.
grant insert (user_id, display_name, categories, price, province, district, nearby, phone, line_id, note)
  on public.worker_applications to authenticated;
grant update (display_name, categories, price, province, district, nearby, phone, line_id, note,
              profile_image, original_path)
  on public.worker_applications to authenticated;     -- status is NOT updatable by clients

drop policy if exists app_update_own on public.worker_applications;
create policy app_update_own on public.worker_applications
  for update to authenticated
  using (user_id = auth.uid() and status = 'pending')
  with check (user_id = auth.uid() and status = 'pending');

-- Approval copies everything except the private contact details.
create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.users set role = 'worker' where id = a.user_id;
  insert into public.workers (user_id, display_name, categories, price, province, district, nearby,
                              profile_image, original_path)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path)
  on conflict (user_id) do update
    set display_name = excluded.display_name, categories = excluded.categories, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby,
        profile_image = coalesce(excluded.profile_image, public.workers.profile_image),
        original_path = coalesce(excluded.original_path, public.workers.original_path);
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

-- Photo upload: workers OR applicants with a pending application may write to their own folder.
do $$
declare b text;
begin
  foreach b in array array['worker-public', 'worker-originals'] loop
    execute format('drop policy if exists "%1$s_insert" on storage.objects', b);
    execute format($p$create policy "%1$s_insert" on storage.objects for insert to authenticated
      with check (bucket_id = %1$L and (storage.foldername(name))[1] = auth.uid()::text
        and (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'worker')
          or exists (select 1 from public.worker_applications a where a.user_id = auth.uid() and a.status = 'pending')))$p$, b);
  end loop;
end $$;
