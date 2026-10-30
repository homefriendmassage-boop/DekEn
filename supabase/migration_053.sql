-- =============================================================================
-- migration_053.sql — run ONCE after migration_052.sql
--   * a provider is ONLINE as soon as her profile goes live: approval of an application (approve_worker) and the girl accepting a profile an
--     admin published (claim_draft). She can still switch herself offline.
--   * Flex pushes to the ADMINS (central OA) with a button into the right admin tab: new application, profile edit / removal request,
--     agency application, agency draft waiting, chat flag (orange / red), user reports, slip waiting for a check.
--   * Flex to the person who applied when it is approved / rejected: provider application, agency, profile edit.
--   Both go through the Edge Function notify-chat (types 'admin' and 'approval'); same URL and secret as the other pushes.
-- =============================================================================

create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications; v_first public.profile_photos;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.agency_id is not null and a.agency_status is distinct from 'accepted' then raise exception 'AGENCY_NOT_CONFIRMED'; end if;
  if a.age_check_status <> 'verified' then raise exception 'AGE_NOT_VERIFIED'; end if;
  if not exists (select 1 from public.profile_photos where user_id = a.user_id and state = 'application') and a.original_path is null then
    raise exception 'NO_PHOTO';
  end if;
  update public.users set role = 'worker' where id = a.user_id;
  perform set_config('app.no_fuzz', 'on', true);
  insert into public.workers (user_id, display_name, categories, price, province, district, nearby,
                              profile_image, original_path, recruiter_id, recruiter_until, agency_id, agency_since,
                              gender, age, height_cm, weight_kg, measurements, tags, about, price_options,
                              loc_lat, loc_lng, loc_verified_at, start_rate, service_mode, is_online)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path, a.recruiter_id,
          case when a.recruiter_id is not null then now() + make_interval(days => public.recruiter_window_days()) end,
          a.agency_id, case when a.agency_id is not null then now() end,
          a.gender, a.age, a.height_cm, a.weight_kg, a.measurements, a.tags, a.about, a.price_options,
          a.loc_lat, a.loc_lng, a.loc_verified_at, a.start_rate, a.service_mode, true)       -- a new provider is online as soon as she is approved
  on conflict (user_id) do update
    set display_name = excluded.display_name, categories = excluded.categories, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby,
        profile_image = coalesce(excluded.profile_image, public.workers.profile_image),
        original_path = coalesce(excluded.original_path, public.workers.original_path),
        agency_id = coalesce(excluded.agency_id, public.workers.agency_id),
        agency_since = case when excluded.agency_id is not null and excluded.agency_id is distinct from public.workers.agency_id
                            then now() else public.workers.agency_since end,
        gender = coalesce(excluded.gender, public.workers.gender), age = coalesce(excluded.age, public.workers.age),
        height_cm = coalesce(excluded.height_cm, public.workers.height_cm), weight_kg = coalesce(excluded.weight_kg, public.workers.weight_kg),
        measurements = coalesce(excluded.measurements, public.workers.measurements),
        tags = excluded.tags, about = coalesce(excluded.about, public.workers.about),
        price_options = case when jsonb_array_length(excluded.price_options) > 0 then excluded.price_options else public.workers.price_options end,
        loc_lat = coalesce(excluded.loc_lat, public.workers.loc_lat), loc_lng = coalesce(excluded.loc_lng, public.workers.loc_lng),
        loc_verified_at = coalesce(excluded.loc_verified_at, public.workers.loc_verified_at),
        start_rate = excluded.start_rate, service_mode = excluded.service_mode,
        is_online = case when public.workers.deleted_at is not null then true else public.workers.is_online end,   -- registering again after a removal = new
        deleted_at = null, delete_requested_at = null;

  -- the application's pictures become the live ones; picture no. 1 is the card photo
  if exists (select 1 from public.profile_photos where user_id = a.user_id and state = 'application') then
    delete from public.profile_photos where user_id = a.user_id and state = 'live';
    update public.profile_photos set state = 'live' where user_id = a.user_id and state = 'application';
    select * into v_first from public.profile_photos where user_id = a.user_id and state = 'live' order by sort_no limit 1;
    update public.workers set profile_image = v_first.public_url, original_path = v_first.original_path where user_id = a.user_id;
  end if;
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

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

  if d.managed_user_id is not null then
    -- the profile an admin published for her is hers now: it moves to her account and the placeholder disappears
    update public.workers set user_id = auth.uid() where user_id = d.managed_user_id;
    update public.profile_photos set user_id = auth.uid() where user_id = d.managed_user_id;
    update public.users set role = 'worker' where id = auth.uid();
    update public.workers set claimed = true, claim_deadline = null, is_online = true, booking_phone = v_phone, booking_line_id = v_line,
           loc_lat = p_lat, loc_lng = p_lng
     where user_id = auth.uid();
    delete from auth.users where id = d.managed_user_id;
    insert into public.draft_owner_map (draft_id, user_id) values (d.id, auth.uid()) on conflict (draft_id) do update set user_id = excluded.user_id;
    update public.application_drafts set status = 'claimed', claimed_by = auth.uid(), claimed_at = now(), token = null, managed_user_id = null, updated_at = now() where id = d.id;
    if p_choice = 'agency' then perform public.worker_join_agency(v_code); end if;
    return auth.uid();
  end if;

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
revoke all on function public.claim_draft(text, double precision, double precision, text, text, text, text, boolean, boolean, boolean) from public, anon;
grant execute on function public.claim_draft(text, double precision, double precision, text, text, text, text, boolean, boolean, boolean) to authenticated;

-- ---------- push helpers -------------------------------------------------------------------------------------------------------------
create or replace function public.push_notify(p_body jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return; end if;
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)', v_url,
    jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text, p_body::text);
exception when others then
  return;
end $$;
revoke all on function public.push_notify(jsonb) from public, anon, authenticated;

create or replace function public.admin_notify(p_event text, p_detail text default null)
returns void language sql security definer set search_path = public as $$
  select public.push_notify(jsonb_build_object('type', 'admin', 'event', p_event, 'detail', left(coalesce(p_detail, ''), 80)))
$$;
create or replace function public.approval_notify(p_kind text, p_user uuid, p_event text, p_detail text default null)
returns void language sql security definer set search_path = public as $$
  select public.push_notify(jsonb_build_object('type', 'approval', 'kind', p_kind, 'event', p_event, 'user_id', p_user, 'detail', left(coalesce(p_detail, ''), 120)))
$$;
revoke all on function public.admin_notify(text, text), public.approval_notify(text, uuid, text, text) from public, anon, authenticated;

-- ---------- to the admins ------------------------------------------------------------------------------------------------------------------
create or replace function public.trg_admin_application() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then perform public.admin_notify('application', new.display_name); end if;
  return new;
end $$;
drop trigger if exists worker_applications_admin_notify on public.worker_applications;
create trigger worker_applications_admin_notify after insert on public.worker_applications for each row execute function public.trg_admin_application();

create or replace function public.trg_admin_edit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then
    perform public.admin_notify('edit', (select display_name from public.users where id = new.user_id));
  end if;
  return new;
end $$;
drop trigger if exists profile_edit_requests_admin_notify on public.profile_edit_requests;
create trigger profile_edit_requests_admin_notify after insert on public.profile_edit_requests for each row execute function public.trg_admin_edit();

create or replace function public.trg_admin_deletion() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.delete_requested_at is not null and old.delete_requested_at is null then perform public.admin_notify('deletion', new.display_name); end if;
  return new;
end $$;
drop trigger if exists workers_admin_notify_deletion on public.workers;
create trigger workers_admin_notify_deletion after update of delete_requested_at on public.workers for each row execute function public.trg_admin_deletion();

create or replace function public.trg_admin_agency() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then perform public.admin_notify('agency', new.name); end if;
  return new;
end $$;
drop trigger if exists agencies_admin_notify on public.agencies;
create trigger agencies_admin_notify after insert on public.agencies for each row execute function public.trg_admin_agency();

create or replace function public.trg_admin_draft() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted' and new.source = 'agency' then perform public.admin_notify('draft', new.display_name); end if;
  return new;
end $$;
drop trigger if exists application_drafts_admin_notify on public.application_drafts;
create trigger application_drafts_admin_notify after update of status on public.application_drafts for each row execute function public.trg_admin_draft();

create or replace function public.trg_admin_flag() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.flag_level >= 3 and new.flag_level > coalesce(old.flag_level, 0) then
    perform public.admin_notify('flag', new.flag_level::text);
  end if;
  return new;
end $$;
drop trigger if exists chat_threads_admin_notify on public.chat_threads;
create trigger chat_threads_admin_notify after update of flag_level on public.chat_threads for each row execute function public.trg_admin_flag();

create or replace function public.trg_admin_chat_report() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.admin_notify('report', 'ห้องแชต'); return new; end $$;
drop trigger if exists chat_reports_admin_notify on public.chat_reports;
create trigger chat_reports_admin_notify after insert on public.chat_reports for each row execute function public.trg_admin_chat_report();

create or replace function public.trg_admin_profile_report() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.admin_notify('report', coalesce((select display_name from public.workers where user_id = new.worker_id), 'โปรไฟล์')); return new; end $$;
drop trigger if exists profile_reports_admin_notify on public.profile_reports;
create trigger profile_reports_admin_notify after insert on public.profile_reports for each row execute function public.trg_admin_profile_report();

create or replace function public.trg_admin_slip() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then perform public.admin_notify('slip', (select display_name from public.users where id = new.user_id)); end if;
  return new;
end $$;
drop trigger if exists payment_reviews_admin_notify on public.payment_reviews;
create trigger payment_reviews_admin_notify after insert on public.payment_reviews for each row execute function public.trg_admin_slip();

-- ---------- to the applicant: approved / rejected ---------------------------------------------------------------------------------------------
create or replace function public.trg_approval() returns trigger language plpgsql security definer set search_path = public as $$
declare v_kind text := tg_argv[0]; v_user uuid; v_reason text;
begin
  if new.status is not distinct from old.status or new.status not in ('approved', 'rejected') then return new; end if;
  v_user := case v_kind when 'agency' then new.user_id else new.user_id end;
  v_reason := new.reject_reason;
  perform public.approval_notify(v_kind, v_user, new.status, v_reason);
  return new;
end $$;
drop trigger if exists worker_applications_approval on public.worker_applications;
create trigger worker_applications_approval after update of status on public.worker_applications for each row execute function public.trg_approval('worker');
drop trigger if exists agencies_approval on public.agencies;
create trigger agencies_approval after update of status on public.agencies for each row execute function public.trg_approval('agency');
drop trigger if exists profile_edit_requests_approval on public.profile_edit_requests;
create trigger profile_edit_requests_approval after update of status on public.profile_edit_requests for each row execute function public.trg_approval('edit');
