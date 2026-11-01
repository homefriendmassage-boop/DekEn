-- =============================================================================
-- migration_071.sql — run ONCE after migration_070.sql
-- How-to videos (YouTube): a small list the admin manages. The files live on YouTube; the app only keeps the link.
--   spot     : where a one-tap bar shows ('apply' before choosing a category, 'topup', 'book', 'withdraw', 'share'); empty = only in the "วิธีใช้งาน" list
--   audience : 'customer' | 'worker' | 'seller' | 'agency' | 'all'  (the group in the "วิธีใช้งาน" list)
-- =============================================================================
create table if not exists public.help_videos (
  id         uuid primary key default gen_random_uuid(),
  title      text not null check (char_length(title) between 1 and 80),
  url        text not null check (url ~ '^https://((www|m)\.)?(youtube\.com|youtu\.be)/'),
  spot       text check (spot in ('apply', 'topup', 'book', 'withdraw', 'share')),
  audience   text not null default 'all' check (audience in ('customer', 'worker', 'seller', 'agency', 'all')),
  sort_no    int not null default 100,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.help_videos enable row level security;
revoke all on public.help_videos from anon, authenticated;

create or replace function public.help_videos_list()
returns table (id uuid, title text, url text, spot text, audience text)
language sql stable security definer set search_path = public as $$
  select v.id, v.title, v.url, v.spot, v.audience from public.help_videos v where v.active order by v.sort_no, v.created_at
$$;

create or replace function public.admin_help_videos()
returns setof public.help_videos
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select * from public.help_videos order by sort_no, created_at;
end $$;

create or replace function public.admin_help_save(p_id uuid, p_title text, p_url text, p_spot text, p_audience text, p_sort int, p_active boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.assert_admin();
  if p_id is null then
    insert into public.help_videos (title, url, spot, audience, sort_no, active)
    values (btrim(p_title), btrim(p_url), nullif(p_spot, ''), coalesce(nullif(p_audience, ''), 'all'), coalesce(p_sort, 100), coalesce(p_active, true)) returning id into v_id;
  else
    update public.help_videos set title = btrim(p_title), url = btrim(p_url), spot = nullif(p_spot, ''), audience = coalesce(nullif(p_audience, ''), 'all'),
           sort_no = coalesce(p_sort, 100), active = coalesce(p_active, true) where id = p_id returning id into v_id;
    if v_id is null then raise exception 'NOT_FOUND'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.admin_help_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  delete from public.help_videos where id = p_id;
end $$;

revoke all on function public.help_videos_list(), public.admin_help_videos(), public.admin_help_save(uuid, text, text, text, text, int, boolean),
  public.admin_help_delete(uuid) from public, anon;
grant execute on function public.help_videos_list(), public.admin_help_videos(), public.admin_help_save(uuid, text, text, text, text, int, boolean),
  public.admin_help_delete(uuid) to authenticated;

-- the first clip: how to fill in the application (shown before a girl chooses her category)
insert into public.help_videos (title, url, spot, audience, sort_no)
select 'วิธีกรอกใบสมัคร', 'https://youtube.com/shorts/sdzU6Anj7fI', 'apply', 'worker', 10
 where not exists (select 1 from public.help_videos where spot = 'apply');
