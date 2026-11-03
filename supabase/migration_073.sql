-- =============================================================================
-- migration_073.sql — run ONCE after migration_072.sql
-- A PAID agency can put its girls in the order it wants on its own page ("จัดอันดับน้อง"). Without an order the page stays random as before.
--   * only the agency's OWN page is affected: the shared feed and the clear / blurred faces are not touched
--   * girls the agency has not placed (new girls) follow the placed ones, in the normal random order
--   * "reset" clears the order -> back to the automatic random order
-- =============================================================================
alter table public.workers add column if not exists agency_sort int;

-- leaving / changing agency clears her place
create or replace function public.trg_worker_agency_sort_clear()
returns trigger language plpgsql as $$
begin
  if new.agency_id is distinct from old.agency_id then new.agency_sort := null; end if;
  return new;
end $$;
drop trigger if exists workers_agency_sort_clear on public.workers;
create trigger workers_agency_sort_clear before update of agency_id on public.workers
  for each row execute function public.trg_worker_agency_sort_clear();

-- the agency's own list for the ordering sheet
create or replace function public.agency_order_list()
returns table (user_id uuid, display_name text, pos int)
language sql stable security definer set search_path = public as $$
  select w.user_id, w.display_name, w.agency_sort
    from public.workers w
   where w.agency_id = auth.uid() and w.user_id <> auth.uid() and w.deleted_at is null
   order by w.agency_sort nulls last, w.agency_since, w.user_id
$$;

-- save the order (a list of girl ids, first = shown first). Girls left out lose their place and follow the placed ones.
create or replace function public.agency_set_order(p_order uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.agencies a where a.user_id = auth.uid() and a.status = 'approved') then raise exception 'NOT_APPROVED'; end if;
  if not public.agency_active(auth.uid()) then raise exception 'PLAN_INACTIVE'; end if;
  select count(*) into v_n from public.workers w where w.agency_id = auth.uid() and w.user_id = any (coalesce(p_order, '{}'));
  if v_n <> coalesce(array_length(p_order, 1), 0) then raise exception 'BAD_INPUT'; end if;     -- only her own girls, no repeats
  update public.workers set agency_sort = null where agency_id = auth.uid();
  update public.workers w set agency_sort = o.n
    from unnest(p_order) with ordinality as o(id, n) where w.user_id = o.id and w.agency_id = auth.uid();
end $$;

create or replace function public.agency_reset_order()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  update public.workers set agency_sort = null where agency_id = auth.uid();
end $$;

-- what a visitor needs to sort an agency page: the place of each girl, only for agencies that are PAID right now
create or replace function public.agency_girl_order()
returns table (agency_id uuid, worker_id uuid, pos int)
language sql stable security definer set search_path = public as $$
  select w.agency_id, w.user_id, w.agency_sort
    from public.workers w
   where w.agency_sort is not null and w.agency_id is not null and public.agency_active(w.agency_id)
$$;

revoke all on function public.agency_order_list(), public.agency_set_order(uuid[]), public.agency_reset_order(), public.agency_girl_order() from public, anon;
grant execute on function public.agency_order_list(), public.agency_set_order(uuid[]), public.agency_reset_order(), public.agency_girl_order() to authenticated;
