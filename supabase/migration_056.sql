-- =============================================================================
-- migration_056.sql — run ONCE after migration_055.sql
--   * Chat is open to every customer (no package needed): the first message still holds the chat fee from the Wallet, and the app asks
--     for a top-up when the Wallet is short.
--   * Agency: edit the name / logo from its own settings -> goes to an admin for approval (the old name / logo stay until then).
--   * Agency drafts: "cancel" only hides a draft (it never counts against the 40-draft quota); a hidden draft can be restored or deleted for good.
--     The agency's list shows its OWN drafts only: drafts made by a central admin (source = 'admin') no longer appear there.
-- =============================================================================

-- ---------- 1) chat without a package -------------------------------------------------------------------------
create or replace function public.open_thread(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_worker = auth.uid() then raise exception 'SELF_CHAT'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  if not public.worker_listed(p_worker) then raise exception 'LOCKED'; end if;
  if exists (select 1 from public.workers w where w.user_id = p_worker and not w.claimed) then raise exception 'UNCLAIMED'; end if;
  insert into public.chat_threads (customer_id, worker_id) values (auth.uid(), p_worker)
  on conflict (customer_id, worker_id) do nothing;
  select id into v from public.chat_threads where customer_id = auth.uid() and worker_id = p_worker;
  return v;
end $$;

create or replace function public.send_message(p_thread uuid, p_body text, p_accept_fee boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  t   public.chat_threads;
  b   text := btrim(p_body);
  v_msg uuid;
  v_bal numeric;
  v_fee uuid;
  v_worker_side boolean;
  v_digits int;
  v_prior int;
  v_reason text;
  v_n int;
begin
  select * into t from public.chat_threads
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id)) for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  v_worker_side := auth.uid() <> t.customer_id;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  -- Thread suspended / closed by an admin (or by the red flag below)
  if t.status <> 'open' then raise exception 'THREAD_SUSPENDED'; end if;
  -- Contact details (numbers, links, IDs, "line" ...) are refused BEFORE any fee is held. Every attempt is recorded and
  -- raises the thread's flag: 1 = noted, 2 = yellow, 3 = orange, 4 = red (the thread is suspended until an admin decides).
  v_reason := public.chat_problem(b);
  if v_reason is null and public.is_number_only(b) then
    -- a number sent in pieces: this message plus the sender's earlier number-only messages of the last 30 minutes
    select coalesce(sum(char_length(regexp_replace(public.contact_numbers(m.body), '[^0-9]', '', 'g'))), 0) into v_prior
      from (select body from public.chat_messages
             where thread_id = p_thread and sender_id = auth.uid() and created_at > now() - interval '30 minutes'
             order by created_at desc limit 8) m
     where public.is_number_only(m.body);
    v_digits := v_prior + char_length(regexp_replace(public.contact_numbers(b), '[^0-9]', '', 'g'));
    if v_prior > 0 and v_digits >= 9 then v_reason := 'SPLIT_NUMBER'; end if;
  end if;
  if v_reason is not null then
    insert into public.chat_flag_events (thread_id, sender_id, reason, body) values (p_thread, auth.uid(), v_reason, left(b, 200));
    select count(*) into v_n from public.chat_flag_events
     where thread_id = p_thread and sender_id = auth.uid() and created_at > coalesce(t.flag_reset_at, '-infinity');
    update public.chat_threads set flag_level = greatest(flag_level, least(v_n, 4)) where id = p_thread;
    if v_n >= 4 then
      update public.chat_threads set status = 'suspended', suspended_at = now(), suspended_reason = 'auto_flag', last_message_at = now() where id = p_thread;
      insert into public.chat_messages (thread_id, sender_id, body, kind) values (p_thread, auth.uid(), 'ห้องนี้ถูกระงับโดยผู้ดูแล', 'sys_suspended');
      return 'THREAD_SUSPENDED';
    end if;
    return 'CONTACT_BLOCKED:' || v_n;
  end if;
  if (select count(*) from public.chat_messages
       where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;

  perform public.release_chat_holds(null, p_thread);

  if not v_worker_side
     and coalesce(t.paid_until, '-infinity') <= now()
     and not exists (select 1 from public.chat_fees where thread_id = p_thread and status = 'held') then
    if not p_accept_fee then raise exception 'FEE_CONSENT_REQUIRED'; end if;
    select wallet_balance into v_bal from public.users where id = t.customer_id for update;
    if v_bal < public.chat_fee_amount() then raise exception 'INSUFFICIENT_BALANCE'; end if;
    insert into public.chat_fees (thread_id, customer_id, worker_id, amount, worker_amount, platform_amount, hold_expires_at)
    values (p_thread, t.customer_id, t.worker_id, public.chat_fee_amount(), public.chat_fee_to_worker(),
            public.chat_fee_amount() - public.chat_fee_to_worker(), now() + make_interval(hours => public.chat_hold_hours()))
    returning id into v_fee;
    perform set_config('app.ledger_kind', 'chat_hold', true);
    perform set_config('app.ledger_ref', v_fee::text, true);
    update public.users set wallet_balance = wallet_balance - public.chat_fee_amount() where id = t.customer_id;
  end if;

  insert into public.chat_messages (thread_id, sender_id, body) values (p_thread, auth.uid(), b) returning id into v_msg;
  update public.chat_threads
     set last_message_at = now(),
         customer_last_read = case when not v_worker_side then now() else customer_last_read end,
         worker_last_read   = case when v_worker_side     then now() else worker_last_read end
   where id = p_thread;

  if v_worker_side and public.chat_reply_valid(b) then
    perform public.capture_chat_fee(p_thread, v_msg);
  end if;
  return 'OK';
end $$;
revoke all on function public.send_message(uuid, text, boolean), public.open_thread(uuid) from public, anon;
grant execute on function public.send_message(uuid, text, boolean), public.open_thread(uuid) to authenticated;

-- ---------- 2) agency: name / logo change needs an admin ----------------------------------------------------------
create table if not exists public.agency_edit_requests (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies (user_id) on delete cascade,
  new_name text check (new_name is null or char_length(btrim(new_name)) between 2 and 60),
  new_logo_path text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reject_reason text,
  created_at timestamptz not null default now(),
  reviewed_by uuid references public.users (id),
  reviewed_at timestamptz
);
alter table public.agency_edit_requests enable row level security;
revoke all on public.agency_edit_requests from anon, authenticated;
create index if not exists agency_edit_requests_agency on public.agency_edit_requests (agency_id, created_at desc);

-- an approved agency may upload a PENDING logo next to the live one (it never overwrites the live file)
drop policy if exists "agency-logos_insert_pending" on storage.objects;
create policy "agency-logos_insert_pending" on storage.objects for insert to authenticated
  with check (bucket_id = 'agency-logos' and (storage.foldername(name))[1] = auth.uid()::text
              and name like auth.uid()::text || '/pending-%');

create or replace function public.agency_request_edit(p_name text, p_logo_path text)
returns void language plpgsql security definer set search_path = public as $$
declare a public.agencies; v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into a from public.agencies where user_id = auth.uid() and status = 'approved';
  if not found then raise exception 'NOT_APPROVED'; end if;
  if v_name is not null and char_length(v_name) not between 2 and 60 then raise exception 'BAD_INPUT'; end if;
  if p_logo_path is not null and p_logo_path not like auth.uid()::text || '/pending-%' then raise exception 'BAD_INPUT'; end if;
  if v_name is not distinct from a.name then v_name := null; end if;
  if v_name is null and p_logo_path is null then raise exception 'NO_CHANGE'; end if;
  update public.agency_edit_requests set status = 'cancelled' where agency_id = a.user_id and status = 'pending';
  insert into public.agency_edit_requests (agency_id, new_name, new_logo_path) values (a.user_id, v_name, p_logo_path);
end $$;

create or replace function public.agency_my_edit()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(r) - 'agency_id' - 'reviewed_by' from public.agency_edit_requests r
   where r.agency_id = auth.uid() and r.status in ('pending', 'rejected') order by r.created_at desc limit 1
$$;

create or replace function public.agency_cancel_edit()
returns void language sql security definer set search_path = public as $$
  update public.agency_edit_requests set status = 'cancelled' where agency_id = auth.uid() and status = 'pending'
$$;

create or replace function public.trg_admin_agency_edit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then perform public.admin_notify('agency_edit', (select a.name from public.agencies a where a.user_id = new.agency_id)); end if;
  return new;
end $$;
drop trigger if exists agency_edit_requests_admin_notify on public.agency_edit_requests;
create trigger agency_edit_requests_admin_notify after insert on public.agency_edit_requests for each row execute function public.trg_admin_agency_edit();

create or replace function public.admin_agency_edits(p_status text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select r.id, r.agency_id, a.name as old_name, a.logo_path as old_logo, r.new_name, r.new_logo_path, r.status, r.reject_reason, r.created_at,
           u.display_name as user_name
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
    update public.agencies set name = coalesce(r.new_name, name), logo_path = coalesce(r.new_logo_path, logo_path) where user_id = r.agency_id;
  end if;
  update public.agency_edit_requests set status = case when p_approve then 'approved' else 'rejected' end,
         reject_reason = case when p_approve then null else left(nullif(btrim(coalesce(p_reason, '')), ''), 300) end,
         reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
end $$;

create or replace function public.admin_agency_edit_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select count(*)::int from public.agency_edit_requests where status = 'pending');
end $$;

revoke all on function public.agency_request_edit(text, text), public.agency_my_edit(), public.agency_cancel_edit(),
  public.admin_agency_edits(text), public.admin_agency_edit_decide(uuid, boolean, text), public.admin_agency_edit_count() from public, anon;
grant execute on function public.agency_request_edit(text, text), public.agency_my_edit(), public.agency_cancel_edit(),
  public.admin_agency_edits(text), public.admin_agency_edit_decide(uuid, boolean, text), public.admin_agency_edit_count() to authenticated;

-- ---------- 3) drafts: own list only, hide / restore / delete for good ------------------------------------------
drop function if exists public.my_drafts();
create or replace function public.my_drafts(p_hidden boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(public.draft_view(d) order by d.updated_at desc)
                     from (select * from public.application_drafts
                            where created_by = auth.uid() and source = 'agency' and (status = 'cancelled') = coalesce(p_hidden, false)
                            order by updated_at desc limit 100) d), '[]'::jsonb);
end $$;

create or replace function public.admin_drafts_list(p_filter text default 'review')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(public.draft_view(d) order by d.updated_at desc)
                     from (select * from public.application_drafts x
                            where case p_filter when 'review' then x.status = 'submitted'
                                                when 'links' then x.status in ('approved', 'expired') or (x.status = 'draft' and x.source = 'admin')
                                                when 'hidden' then x.status = 'cancelled'
                                                else x.status <> 'cancelled' end
                            order by x.updated_at desc limit 100) d), '[]'::jsonb);
end $$;

-- bring a hidden draft back as a plain draft (a published profile that was taken down is not republished)
create or replace function public.draft_restore(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.application_drafts;
begin
  select * into d from public.application_drafts where id = p_id and (created_by = auth.uid() or public.is_admin()) and status = 'cancelled' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if (select count(*) from public.application_drafts where created_by = d.created_by and status in ('draft', 'submitted', 'approved', 'rejected')) >= 40 then
    raise exception 'TOO_MANY_DRAFTS';
  end if;
  update public.application_drafts set status = 'draft', token = null, reject_reason = null, updated_at = now() where id = p_id;
end $$;

-- delete a hidden draft for good; returns the file paths so the app can remove the pictures too
create or replace function public.draft_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_paths jsonb;
begin
  select * into d from public.application_drafts where id = p_id and (created_by = auth.uid() or public.is_admin()) and status = 'cancelled' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select coalesce(jsonb_agg(original_path), '[]'::jsonb) into v_paths from public.draft_photos where draft_id = p_id;
  delete from public.application_drafts where id = p_id;
  return v_paths;
end $$;

revoke all on function public.my_drafts(boolean), public.admin_drafts_list(text), public.draft_restore(uuid), public.draft_delete(uuid) from public, anon;
grant execute on function public.my_drafts(boolean), public.admin_drafts_list(text), public.draft_restore(uuid), public.draft_delete(uuid) to authenticated;
