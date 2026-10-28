-- =============================================================================
-- migration_006.sql — run ONCE after migration_005.sql
-- Makes users identifiable in the admin page: LINE profile picture + last seen,
-- and the user search lists recent users even with an empty query.
-- =============================================================================
alter table public.users
  add column if not exists picture_url  text,
  add column if not exists last_seen_at timestamptz;

-- Called by the app on every login. Same call as before still works (picture is optional).
drop function if exists public.touch_profile(text);
create function public.touch_profile(p_name text, p_picture text default null)
returns void language sql security definer set search_path = public as $$
  update public.users
     set display_name = left(p_name, 60),
         picture_url  = case when p_picture ~ '^https://' then left(p_picture, 500) else picture_url end,
         last_seen_at = now()
   where id = auth.uid();
$$;
revoke all on function public.touch_profile(text, text) from public, anon;
grant execute on function public.touch_profile(text, text) to authenticated;

-- Empty query => most recently active users (so the admin can just pick from the list).
drop function if exists public.admin_search_users(text);
create function public.admin_search_users(p_q text default '')
returns table (id uuid, display_name text, line_user_id text, role public.user_role,
               picture_url text, last_seen_at timestamptz, created_at timestamptz,
               wallet_balance numeric, vip_tier smallint, vip_expires_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select u.id, u.display_name, u.line_user_id, u.role, u.picture_url, u.last_seen_at, u.created_at,
           u.wallet_balance, u.vip_tier, u.vip_expires_at
      from public.users u
     where btrim(coalesce(p_q, '')) = ''
        or u.display_name ilike '%' || btrim(p_q) || '%'
        or u.line_user_id ilike '%' || btrim(p_q) || '%'
     order by u.last_seen_at desc nulls last, u.created_at desc
     limit 20;
end $$;
revoke all on function public.admin_search_users(text) from public, anon;
grant execute on function public.admin_search_users(text) to authenticated;
