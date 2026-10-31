-- =============================================================================
-- migration_059.sql — run ONCE after migration_058.sql
--   * Spa / massage form: a new set of "introduce yourself" choices (girlfriend feel, fun talk, playful, sweet, attentive, relaxing massage,
--     drinks, no drinks, not picky, anything). The old massage choices stay accepted so nothing already saved is lost.
--   * Admin: the applicant's LINE profile picture on the application card (admin_user_pictures).
--   * Agencies can buy the FIRST places of the agency strip (agency_boosts): 3 places at a time, bonus wallet first then Wallet.
--     Boosted agencies come first (rotated daily among themselves), the others follow in a daily rotation.
-- =============================================================================

-- ---------- 1) spa tags ------------------------------------------------------------------------------------------------------------------------
do $$
declare d text;
begin
  d := pg_get_functiondef('public.normalize_worker_profile()'::regprocedure);
  d := replace(d, 'array[''thai_massage'', ''oil'', ''foot'', ''aroma'', ''sports'', ''scrub'', ''polite'', ''punctual'', ''experienced'']',
    'array[''girlfriend_feel'', ''fun_talk'', ''playful'', ''sweet'', ''attentive'', ''relax_massage'', ''drinks'', ''no_drink'', ''not_picky'', ''anything'', '
    || '''thai_massage'', ''oil'', ''foot'', ''aroma'', ''sports'', ''scrub'', ''polite'', ''punctual'', ''experienced'']');
  if d not like '%girlfriend_feel%' then raise exception 'normalize_worker_profile() was not patched: the tag list was not found'; end if;
  execute d;
end $$;

-- ---------- 2) the applicant's LINE picture for the admin -----------------------------------------------------------------------------------
create or replace function public.admin_user_pictures(p_ids uuid[])
returns table (id uuid, picture_url text) language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select u.id, u.picture_url from public.users u where u.id = any (p_ids) and u.picture_url is not null;
end $$;
revoke all on function public.admin_user_pictures(uuid[]) from public, anon;
grant execute on function public.admin_user_pictures(uuid[]) to authenticated;

-- ---------- 3) agency strip boost ----------------------------------------------------------------------------------------------------------------
create or replace function public.agency_boost_price() returns numeric language sql immutable as $$ select 100::numeric $$;   -- per day
create or replace function public.agency_boost_slots() returns int language sql immutable as $$ select 3 $$;

create table if not exists public.agency_boosts (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies (user_id) on delete cascade,
  ends_at timestamptz not null,
  paid numeric not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists agency_boosts_end on public.agency_boosts (ends_at);
alter table public.agency_boosts enable row level security;
revoke all on public.agency_boosts from anon, authenticated;

create or replace function public.agency_boost_status()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'price_day', public.agency_boost_price(), 'price_3', public.agency_boost_price() * 3, 'price_7', public.agency_boost_price() * 5,
    'slots', public.agency_boost_slots(),
    'used', (select count(*) from public.agency_boosts b join public.agencies a on a.user_id = b.agency_id where b.ends_at > now()),
    'mine_until', (select max(b.ends_at) from public.agency_boosts b where b.agency_id = auth.uid() and b.ends_at > now()))
$$;

create or replace function public.agency_buy_boost(p_days int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  a public.agencies; v_price numeric; v_bonus numeric; v_wallet numeric; v_from_bonus numeric; v_from_wallet numeric;
  cur public.agency_boosts; v_ends timestamptz;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_days not in (1, 3, 7) then raise exception 'BAD_INPUT'; end if;
  select * into a from public.agencies where user_id = auth.uid() and status = 'approved';
  if not found then raise exception 'NOT_APPROVED'; end if;
  if not public.agency_active(a.user_id) then raise exception 'PLAN_INACTIVE'; end if;
  v_price := public.agency_boost_price() * case when p_days = 7 then 5 else p_days end;

  perform pg_advisory_xact_lock(hashtext('agency_boost'));
  select * into cur from public.agency_boosts where agency_id = a.user_id and ends_at > now() order by ends_at desc limit 1;
  if not found and (select count(*) from public.agency_boosts where ends_at > now()) >= public.agency_boost_slots() then raise exception 'SLOTS_FULL'; end if;

  select bonus_balance, wallet_balance into v_bonus, v_wallet from public.users where id = auth.uid() for update;
  v_from_bonus := least(v_bonus, v_price);
  v_from_wallet := v_price - v_from_bonus;
  if v_wallet < v_from_wallet then raise exception 'INSUFFICIENT_BALANCE'; end if;
  if v_from_bonus > 0 then
    perform set_config('app.ledger_kind', 'agency_boost', true);
    perform set_config('app.ledger_ref', a.user_id::text, true);
    update public.users set bonus_balance = bonus_balance - v_from_bonus where id = auth.uid();
  end if;
  if v_from_wallet > 0 then
    perform set_config('app.ledger_kind', 'agency_boost', true);
    perform set_config('app.ledger_ref', a.user_id::text, true);
    update public.users set wallet_balance = wallet_balance - v_from_wallet where id = auth.uid();
  end if;
  if cur.id is not null then
    v_ends := cur.ends_at + make_interval(days => p_days);
    update public.agency_boosts set ends_at = v_ends, paid = paid + v_price where id = cur.id;
  else
    v_ends := now() + make_interval(days => p_days);
    insert into public.agency_boosts (agency_id, ends_at, paid) values (a.user_id, v_ends, v_price);
  end if;
  return v_ends;
end $$;
revoke all on function public.agency_boost_status(), public.agency_buy_boost(int) from public, anon;
grant execute on function public.agency_boost_status(), public.agency_buy_boost(int) to authenticated;

-- the directory: boosted agencies first (rotating daily among themselves), then the rest in a daily rotation
create or replace function public.agency_directory()
returns jsonb language sql stable security definer set search_path = public as $$
  with ag as (select a.*, exists (select 1 from public.agency_boosts b where b.agency_id = a.user_id and b.ends_at > now()) as boosted
                from public.agencies a where a.status = 'approved' and public.agency_active(a.user_id)),
       gs as (select w.user_id, w.agency_id, w.categories from public.workers w join ag on ag.user_id = w.agency_id where public.worker_listed(w.user_id)),
       cc as (select gs.agency_id, c, count(*)::int as n from gs, unnest(gs.categories) c group by 1, 2)
  select jsonb_build_object(
    'agencies', coalesce((select jsonb_agg(jsonb_build_object(
         'id', ag.user_id, 'name', ag.name, 'logo', ag.logo_path, 'intro', ag.intro, 'show_badge', ag.show_badge, 'show_count', ag.show_count,
         'boosted', ag.boosted,
         'girls', case when ag.show_count then (select coalesce(jsonb_object_agg(cc.c, cc.n), '{}'::jsonb) from cc where cc.agency_id = ag.user_id) end,
         'cats', (select coalesce(jsonb_agg(cc.c), '[]'::jsonb) from cc where cc.agency_id = ag.user_id))
         order by ag.boosted desc, md5(ag.user_id::text || (now() at time zone 'Asia/Bangkok')::date::text))
       from ag where exists (select 1 from gs where gs.agency_id = ag.user_id)), '[]'::jsonb),
    'members', coalesce((select jsonb_object_agg(gs.user_id, gs.agency_id) from gs), '{}'::jsonb))
$$;
