-- =============================================================================
-- migration_054.sql — run ONCE after migration_053.sql
--   * Flex to the customer when a payment is recorded (slip approved, admin recorded, paid from the Wallet): the package they got with a
--     button for each group it opens (Gold: bartender + ENT; Platinum: + massage; Diamond: + spa), or the Wallet top-up received.
--     Through notify-chat (type 'payment'); the buttons open the app on that group (?open=<category>).
--   * admin_edit_application(): an admin can correct an applicant's data at any time (pending, approved or rejected); when the
--     application is already approved the live profile is updated too, and the provider gets a notice in her admin chat.
-- =============================================================================

create or replace function public.trg_payment_notify() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.push_notify(jsonb_build_object('type', 'payment', 'kind', case when new.kind = 'membership' then 'membership' else 'topup' end,
                                               'user_id', new.user_id, 'tier', new.tier, 'amount', new.amount));
  return new;
end $$;
drop trigger if exists payments_notify on public.payments;
create trigger payments_notify after insert on public.payments for each row execute function public.trg_payment_notify();

create or replace function public.admin_edit_application(p_app uuid, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications; r public.worker_applications; v_cats text[];
begin
  perform public.assert_admin();
  select * into a from public.worker_applications where id = p_app for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  r := jsonb_populate_record(null::public.worker_applications, coalesce(p_data, '{}'::jsonb));
  v_cats := coalesce(r.categories, a.categories);
  if coalesce(array_length(v_cats, 1), 0) = 0 or btrim(coalesce(r.display_name, '')) = '' then raise exception 'BAD_INPUT'; end if;
  if r.province is not null and not exists (select 1 from public.province_centroids where name = r.province) then raise exception 'BAD_PROVINCE'; end if;
  if coalesce(r.age, a.age, 20) < 20 then raise exception 'BAD_AGE'; end if;

  update public.worker_applications set
    display_name = btrim(r.display_name), categories = v_cats, gender = r.gender, age = r.age, height_cm = r.height_cm, weight_kg = r.weight_kg,
    measurements = r.measurements, tags = coalesce(r.tags, '{}'), about = r.about, price = coalesce(r.price, price),
    price_options = coalesce(r.price_options, price_options), start_rate = coalesce(r.start_rate, start_rate), service_mode = r.service_mode,
    province = coalesce(r.province, province), district = r.district, nearby = r.nearby,
    phone = nullif(btrim(coalesce(r.phone, '')), ''), line_id = nullif(btrim(coalesce(r.line_id, '')), ''), note = r.note
   where id = p_app;

  if a.status = 'approved' then
    select * into a from public.worker_applications where id = p_app;      -- the normalised values
    update public.workers w set display_name = a.display_name, categories = a.categories, gender = a.gender, age = a.age, height_cm = a.height_cm,
           weight_kg = a.weight_kg, measurements = a.measurements, tags = a.tags, about = a.about, price_options = a.price_options,
           start_rate = a.start_rate, service_mode = a.service_mode, district = a.district, nearby = a.nearby,
           province = case when a.province is distinct from w.province then a.province else w.province end
     where w.user_id = a.user_id and w.deleted_at is null;
    perform public.support_notify(a.user_id, '✏️ แอดมินปรับข้อมูลโปรไฟล์ของคุณให้เรียบร้อยแล้ว');
  end if;
end $$;
revoke all on function public.trg_payment_notify() from public, anon, authenticated;
revoke all on function public.admin_edit_application(uuid, jsonb) from public, anon;
grant execute on function public.admin_edit_application(uuid, jsonb) to authenticated;
