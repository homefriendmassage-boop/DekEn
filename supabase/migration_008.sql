-- =============================================================================
-- migration_008.sql — run ONCE after migration_007.sql
-- Admin payment entry is idempotent: each form submission carries a request id,
-- so a double tap / retry can never apply the same entry twice.
-- =============================================================================
alter table public.payments add column if not exists request_id uuid;
create unique index if not exists payments_request_unique on public.payments (request_id) where request_id is not null;

drop function if exists public.admin_record_payment(uuid, text, int, int, numeric, text, text, text);
create function public.admin_record_payment(
  p_user uuid, p_kind text, p_tier int, p_days int, p_amount numeric,
  p_method text, p_request_id uuid, p_reference text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v uuid;
  v_idx text;
begin
  perform public.assert_admin();
  if p_request_id is null then raise exception 'BAD_INPUT'; end if;
  if not exists (select 1 from public.users where id = p_user) then raise exception 'USER_NOT_FOUND'; end if;
  if p_kind = 'membership' and (coalesce(p_tier, 0) not between 1 and 3 or coalesce(p_days, 0) not between 1 and 365) then
    raise exception 'BAD_INPUT';
  end if;

  -- The same submission arriving twice (double tap, retry after a slow network): refuse, change nothing.
  if exists (select 1 from public.payments where request_id = p_request_id) then
    raise exception 'DUPLICATE_REQUEST';
  end if;

  begin
    insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, request_id)
    values (p_user, p_kind,
            case when p_kind = 'membership' then p_tier end,
            case when p_kind = 'membership' then p_days end,
            p_amount, p_method, nullif(btrim(p_reference), ''), nullif(btrim(p_note), ''), auth.uid(), p_request_id)
    returning id into v;
  exception when unique_violation then
    get stacked diagnostics v_idx = constraint_name;        -- two simultaneous taps hit the unique index
    if v_idx = 'payments_request_unique' then raise exception 'DUPLICATE_REQUEST'; end if;
    raise exception 'DUPLICATE_REFERENCE';
  end;

  if p_kind = 'membership' then
    perform public.set_membership(p_user, p_tier, p_days);
  else
    update public.users set wallet_balance = wallet_balance + p_amount where id = p_user;
  end if;
  return v;
end $$;

revoke all on function public.admin_record_payment(uuid, text, int, int, numeric, text, uuid, text, text) from public, anon;
grant execute on function public.admin_record_payment(uuid, text, int, int, numeric, text, uuid, text, text) to authenticated;
