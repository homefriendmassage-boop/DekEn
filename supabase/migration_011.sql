-- =============================================================================
-- migration_011.sql — run ONCE after migration_010.sql
-- 1) create_payment_intent is idempotent: asking again for the same plan / top-up amount returns the
--    SAME open request (same amount, same expiry) instead of a new one. Leaving the app to pay and coming
--    back no longer changes the amount you must match.
-- 2) A genuine slip that arrives after the request expired is reviewed by the admin (not lost):
--    the review is linked to the user's latest request from the last 24 hours, whatever its status.
-- =============================================================================

create or replace function public.create_payment_intent(p_kind text, p_tier int default null, p_amount numeric default null)
returns table (intent_id uuid, intent_amount numeric, intent_expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_base   numeric;
  v_amount numeric;
  v_id     uuid;
  v_exp    timestamptz := now() + interval '30 minutes';
  v_tries  int := 0;
  e        public.payment_intents;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;

  if p_kind = 'membership' then
    if coalesce(p_tier, 0) not between 1 and 3 then raise exception 'BAD_INPUT'; end if;
    v_base := public.plan_price(p_tier);
  elsif p_kind = 'wallet_topup' then
    if p_amount is null or p_amount < 100 or p_amount > 10000 or p_amount <> trunc(p_amount) then
      raise exception 'BAD_INPUT';
    end if;
    v_base := p_amount;
  else
    raise exception 'BAD_INPUT';
  end if;

  -- Same request still open? Hand it back unchanged (amount AND expiry stay as they were).
  select * into e from public.payment_intents
   where user_id = auth.uid() and status = 'pending' and expires_at > now()
     and kind = p_kind and base_amount = v_base
     and tier is not distinct from (case when p_kind = 'membership' then p_tier::smallint end)
   order by created_at desc limit 1;
  if found then
    return query select e.id, e.amount, e.expires_at;
    return;
  end if;

  -- Housekeeping: expire lapsed intents, and keep at most the 2 newest pending ones per user.
  update public.payment_intents set status = 'expired' where status = 'pending' and expires_at < now();
  update public.payment_intents set status = 'expired'
   where id in (select id from public.payment_intents
                 where user_id = auth.uid() and status = 'pending'
                 order by created_at desc offset 2);

  loop
    v_amount := v_base + (1 + floor(random() * 99))::int / 100.0;
    begin
      insert into public.payment_intents (user_id, kind, tier, days, base_amount, amount, expires_at)
      values (auth.uid(), p_kind,
              case when p_kind = 'membership' then p_tier end,
              case when p_kind = 'membership' then 30 end,
              v_base, v_amount, v_exp)
      returning id into v_id;
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries > 25 then raise exception 'BUSY'; end if;
    end;
  end loop;

  return query select v_id, v_amount, v_exp;
end $$;

-- Review keeps the user's latest request of the last 24h even if it has expired (so the admin sees what they wanted).
create or replace function public.submit_payment_review(p_user uuid, p_trans_ref text, p_amount numeric, p_detail jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_review uuid;
  v_intent public.payment_intents;
  v_thread uuid;
  v_exp    numeric[];
begin
  if exists (select 1 from public.payments where reference = p_trans_ref) then raise exception 'DUPLICATE_SLIP'; end if;
  if exists (select 1 from public.payment_reviews where trans_ref = p_trans_ref) then
    if exists (select 1 from public.payment_reviews where trans_ref = p_trans_ref and user_id = p_user and status = 'pending')
      then raise exception 'ALREADY_UNDER_REVIEW'; end if;
    raise exception 'DUPLICATE_SLIP';
  end if;

  select * into v_intent from public.payment_intents
   where user_id = p_user and created_at > now() - interval '24 hours'
   order by (status = 'pending' and expires_at > now()) desc, created_at desc limit 1;
  select coalesce(array_agg(amount order by created_at desc), '{}') into v_exp
    from public.payment_intents where user_id = p_user and status = 'pending' and expires_at > now();

  begin
    insert into public.payment_reviews (user_id, intent_id, trans_ref, paid_amount, expected, detail)
    values (p_user, v_intent.id, p_trans_ref, p_amount, v_exp, p_detail)
    returning id into v_review;
  exception when unique_violation then
    raise exception 'DUPLICATE_SLIP';
  end;

  insert into public.support_threads (user_id) values (p_user) on conflict (user_id) do nothing;
  select id into v_thread from public.support_threads where user_id = p_user;
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body)
  values (v_thread, p_user, false, 'system',
          '📎 ส่งสลิปให้แอดมินตรวจสอบ — ยอดในสลิป ' || to_char(p_amount, 'FM999G990D00')
          || ' บาท, ' || case when coalesce(array_length(v_exp, 1), 0) > 0
                              then 'ยอดที่ต้องโอน ' || to_char(v_exp[1], 'FM999G990D00') || ' บาท'
                              else 'รายการชำระหมดอายุแล้ว' end
          || ' (ref ' || p_trans_ref || ')');
  update public.support_threads set last_message_at = now(), user_last_read = now() where id = v_thread;
  return v_review;
end $$;
