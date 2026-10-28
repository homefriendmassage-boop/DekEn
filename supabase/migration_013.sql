-- =============================================================================
-- migration_013.sql — run ONCE after migration_012.sql
-- A suspended provider (admin -> สมาชิก -> ⚙️ จัดการ -> ระงับบัญชี) disappears from the feed,
-- cannot be booked or opened in chat, and no longer takes a rank slot (others move up).
-- Lifting the suspension (or its end date passing) brings the provider back automatically.
-- =============================================================================

create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid() or (not public.is_suspended(w) and exists (
    select 1 from (
      select x.user_id, c as category,
             row_number() over (partition by c
               order by x.is_boosted desc, x.is_online desc, x.created_at, x.user_id)::int as rk
        from public.workers x, unnest(x.categories) c
       where not public.is_suspended(x.user_id)
    ) r
    where r.user_id = w and public.can_view_category(r.category, r.rk, public.viewer_tier())
  ))
$$;

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
     where not public.is_suspended(w.user_id)
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

-- Booking a suspended provider, or a suspended side writing in a chat, is refused.
create or replace function public.block_suspended_job()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_suspended(new.customer_id) then raise exception 'SUSPENDED'; end if;
  if public.is_suspended(new.worker_id)   then raise exception 'WORKER_UNAVAILABLE'; end if;
  return new;
end $$;

create or replace function public.block_suspended_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare t public.chat_threads;
begin
  if public.is_suspended(new.sender_id) then raise exception 'SUSPENDED'; end if;
  select * into t from public.chat_threads where id = new.thread_id;
  if found and new.sender_id = t.customer_id and public.is_suspended(t.worker_id) then
    raise exception 'WORKER_UNAVAILABLE';
  end if;
  return new;
end $$;
-- =============================================================================
