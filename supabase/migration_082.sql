-- =============================================================================
-- migration_082.sql — run ONCE after migration_081.sql
-- Admin controls per modelling agency (หลังบ้าน -> สังกัด -> อนุมัติแล้ว):
--   * hide from the "show" tab / agency strip (admin_hide_strip) — separate from
--   * hide the agency badge on the girls' pictures, paid or unpaid agency (admin_hide_badge)
--   * delete an agency (its girls are released to be independent; the owner may get a note)
-- agency_directory() is written out in full (migration_073 version + the two switches).
-- =============================================================================

alter table public.agencies add column if not exists admin_hide_strip boolean not null default false, add column if not exists admin_hide_badge boolean not null default false;

CREATE OR REPLACE FUNCTION public.agency_directory()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with ap as (select a.*, public.agency_active(a.user_id) as paid,
                     exists (select 1 from public.agency_boosts b where b.agency_id = a.user_id and b.ends_at > now()) as boosted
                from public.agencies a where a.status = 'approved' and not public.is_suspended(a.user_id)),
       gs as (select w.user_id, w.agency_id, w.categories from public.workers w join ap on ap.user_id = w.agency_id where public.worker_listed(w.user_id)),
       cc as (select gs.agency_id, c, count(*)::int as n from gs, unnest(gs.categories) c group by 1, 2)
  select jsonb_build_object(
    'agencies', coalesce((select jsonb_agg(jsonb_build_object(
         'id', ap.user_id, 'name', ap.name, 'logo', ap.logo_path, 'intro', ap.intro, 'show_badge', ap.show_badge, 'show_count', ap.show_count,
         'boosted', ap.boosted,
         'girls', case when ap.show_count then (select coalesce(jsonb_object_agg(cc.c, cc.n), '{}'::jsonb) from cc where cc.agency_id = ap.user_id) end,
         'cats', (select coalesce(jsonb_agg(cc.c), '[]'::jsonb) from cc where cc.agency_id = ap.user_id))
         order by ap.boosted desc, md5(ap.user_id::text || (now() at time zone 'Asia/Bangkok')::date::text))
       from ap where ap.paid and not ap.admin_hide_strip and exists (select 1 from gs where gs.agency_id = ap.user_id)), '[]'::jsonb),
    'members', coalesce((select jsonb_object_agg(gs.user_id, gs.agency_id) from gs), '{}'::jsonb),
    'badges', coalesce((select jsonb_object_agg(ap.user_id, ap.show_badge and not ap.admin_hide_badge) from ap), '{}'::jsonb),
    'paid', coalesce((select jsonb_object_agg(ap.user_id, ap.paid) from ap), '{}'::jsonb))
$function$;

drop function if exists public.admin_list_agencies(text);
create function public.admin_list_agencies(p_status text default null)
returns table (user_id uuid, user_name text, name text, contact text, logo_path text, status text, reject_reason text, plan_expires_at timestamptz,
               girls int, created_at timestamptz, hide_strip boolean, hide_badge boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select a.user_id, u.display_name, a.name, a.contact, a.logo_path, a.status, a.reject_reason, a.plan_expires_at,
           public.agency_girl_count(a.user_id), a.created_at, a.admin_hide_strip, a.admin_hide_badge
      from public.agencies a join public.users u on u.id = a.user_id
     where p_status is null or a.status = p_status
     order by (a.status = 'pending') desc, a.created_at desc limit 100;
end $$;
revoke all on function public.admin_list_agencies(text) from public, anon;
grant execute on function public.admin_list_agencies(text) to authenticated;

create or replace function public.admin_set_agency_display(p_user uuid, p_hide_strip boolean, p_hide_badge boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.agencies set admin_hide_strip = coalesce(p_hide_strip, admin_hide_strip), admin_hide_badge = coalesce(p_hide_badge, admin_hide_badge) where user_id = p_user;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
revoke all on function public.admin_set_agency_display(uuid, boolean, boolean) from public, anon;
grant execute on function public.admin_set_agency_display(uuid, boolean, boolean) to authenticated;

create or replace function public.admin_delete_agency(p_user uuid, p_note text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform public.assert_admin();
  if not exists (select 1 from public.agencies where user_id = p_user) then raise exception 'NOT_FOUND'; end if;
  -- the girls stay on the platform as independent providers
  update public.workers set agency_id = null where agency_id = p_user;
  get diagnostics v_n = row_count;
  update public.worker_applications set agency_id = null where agency_id = p_user;
  update public.application_drafts set agency_id = null where agency_id = p_user;
  delete from public.agencies where user_id = p_user;       -- seats, invites, boosts, edit requests go with it
  if nullif(btrim(coalesce(p_note, '')), '') is not null then perform public.admin_send_message(p_user, left(btrim(p_note), 1000), true); end if;
  return v_n;
end $$;
revoke all on function public.admin_delete_agency(uuid, text) from public, anon;
grant execute on function public.admin_delete_agency(uuid, text) to authenticated;
