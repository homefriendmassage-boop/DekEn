-- =============================================================================
-- migration_058.sql — run ONCE after migration_057.sql
-- Agency page for customers: a strip of agencies on the provider list, a page per agency (its girls), badge on the cards.
--   * only an agency with an approved, PAID (active) plan appears, with its listed girls only
--   * the agency chooses to show / hide its badge on the cards and the number of girls (agencies.show_badge / show_count)
--   * a short introduction (agencies.intro, max 200 characters) goes through the same admin approval as the name and the logo
-- =============================================================================

alter table public.agencies
  add column if not exists show_badge boolean not null default true,
  add column if not exists show_count boolean not null default true,
  add column if not exists intro text check (intro is null or char_length(intro) <= 200);
alter table public.agency_edit_requests add column if not exists new_intro text check (new_intro is null or char_length(new_intro) <= 200);

-- ---------- what customers may see -------------------------------------------------------------------------------------------------------------
create or replace function public.agency_directory()
returns jsonb language sql stable security definer set search_path = public as $$
  with ag as (select a.* from public.agencies a where a.status = 'approved' and public.agency_active(a.user_id)),
       gs as (select w.user_id, w.agency_id, w.categories from public.workers w join ag on ag.user_id = w.agency_id where public.worker_listed(w.user_id)),
       cc as (select gs.agency_id, c, count(*)::int as n from gs, unnest(gs.categories) c group by 1, 2)
  select jsonb_build_object(
    'agencies', coalesce((select jsonb_agg(jsonb_build_object(
         'id', ag.user_id, 'name', ag.name, 'logo', ag.logo_path, 'intro', ag.intro, 'show_badge', ag.show_badge, 'show_count', ag.show_count,
         'girls', case when ag.show_count then (select coalesce(jsonb_object_agg(cc.c, cc.n), '{}'::jsonb) from cc where cc.agency_id = ag.user_id) end,
         'cats', (select coalesce(jsonb_agg(cc.c), '[]'::jsonb) from cc where cc.agency_id = ag.user_id)) order by ag.name)
       from ag where exists (select 1 from gs where gs.agency_id = ag.user_id)), '[]'::jsonb),
    'members', coalesce((select jsonb_object_agg(gs.user_id, gs.agency_id) from gs), '{}'::jsonb))
$$;
revoke all on function public.agency_directory() from public, anon;
grant execute on function public.agency_directory() to authenticated;

-- ---------- the agency's own switches ------------------------------------------------------------------------------------------------------------
create or replace function public.agency_display()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('show_badge', a.show_badge, 'show_count', a.show_count, 'intro', a.intro) from public.agencies a where a.user_id = auth.uid()
$$;

create or replace function public.agency_set_display(p_badge boolean, p_count boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  update public.agencies set show_badge = coalesce(p_badge, show_badge), show_count = coalesce(p_count, show_count) where user_id = auth.uid() and status = 'approved';
  if not found then raise exception 'NOT_APPROVED'; end if;
end $$;

-- ---------- name / logo / introduction -> admin approval ----------------------------------------------------------------------------------------
drop function if exists public.agency_request_edit(text, text);
create or replace function public.agency_request_edit(p_name text, p_logo_path text, p_intro text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a public.agencies; v_name text := nullif(btrim(coalesce(p_name, '')), ''); v_intro text := case when p_intro is null then null else btrim(p_intro) end;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into a from public.agencies where user_id = auth.uid() and status = 'approved';
  if not found then raise exception 'NOT_APPROVED'; end if;
  if v_name is not null and char_length(v_name) not between 2 and 60 then raise exception 'BAD_INPUT'; end if;
  if v_intro is not null and char_length(v_intro) > 200 then raise exception 'BAD_INPUT'; end if;
  if p_logo_path is not null and p_logo_path not like auth.uid()::text || '/pending-%' then raise exception 'BAD_INPUT'; end if;
  if v_name is not distinct from a.name then v_name := null; end if;
  if v_intro is not null and v_intro = coalesce(a.intro, '') then v_intro := null; end if;
  if v_name is null and p_logo_path is null and v_intro is null then raise exception 'NO_CHANGE'; end if;
  update public.agency_edit_requests set status = 'cancelled' where agency_id = a.user_id and status = 'pending';
  insert into public.agency_edit_requests (agency_id, new_name, new_logo_path, new_intro) values (a.user_id, v_name, p_logo_path, v_intro);
end $$;

create or replace function public.admin_agency_edits(p_status text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select r.id, r.agency_id, a.name as old_name, a.logo_path as old_logo, a.intro as old_intro, r.new_name, r.new_logo_path, r.new_intro,
           r.status, r.reject_reason, r.created_at, u.display_name as user_name
      from public.agency_edit_requests r join public.agencies a on a.user_id = r.agency_id join public.users u on u.id = r.agency_id
     where r.status = p_status order by r.created_at desc limit 100) x), '[]'::jsonb);
end $$;

create or replace function public.admin_agency_edit_decide(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.agency_edit_requests;
begin
  perform public.assert_admin();
  select * into r from public.agency_edit_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_approve then
    update public.agencies set name = coalesce(r.new_name, name), logo_path = coalesce(r.new_logo_path, logo_path),
           intro = case when r.new_intro is null then intro else nullif(r.new_intro, '') end where user_id = r.agency_id;
  end if;
  update public.agency_edit_requests set status = case when p_approve then 'approved' else 'rejected' end,
         reject_reason = case when p_approve then null else left(nullif(btrim(coalesce(p_reason, '')), ''), 300) end,
         reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
end $$;

revoke all on function public.agency_display(), public.agency_set_display(boolean, boolean), public.agency_request_edit(text, text, text),
  public.admin_agency_edits(text), public.admin_agency_edit_decide(uuid, boolean, text) from public, anon;
grant execute on function public.agency_display(), public.agency_set_display(boolean, boolean), public.agency_request_edit(text, text, text),
  public.admin_agency_edits(text), public.admin_agency_edit_decide(uuid, boolean, text) to authenticated;
