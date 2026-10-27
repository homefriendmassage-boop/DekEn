-- DEV ONLY demo data. Run after schema.sql in the SQL Editor.
-- Creates 4 fake auth users (the on_auth_user_created trigger makes their
-- public.users rows), promotes them to workers, and fills workers cards.

insert into auth.users (id, instance_id, aud, role, email)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid,
       '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'demo' || n || '@example.invalid'
from generate_series(1, 4) n
on conflict do nothing;

update public.users set role = 'worker'
 where id in (select ('00000000-0000-0000-0000-00000000000' || n)::uuid from generate_series(1,4) n);

insert into public.workers (user_id, display_name, service_types, price, profile_image, is_online, is_boosted) values
 ('00000000-0000-0000-0000-000000000001', 'Mild',  '{massage}',          2000, 'https://picsum.photos/seed/w1/600/800', true,  true),
 ('00000000-0000-0000-0000-000000000002', 'Ploy',  '{singer,mc}',        3500, 'https://picsum.photos/seed/w2/600/800', true,  false),
 ('00000000-0000-0000-0000-000000000003', 'Fah',   '{massage,spa}',      1800, 'https://picsum.photos/seed/w3/600/800', false, false),
 ('00000000-0000-0000-0000-000000000004', 'Nook',  '{dancer}',           2500, 'https://picsum.photos/seed/w4/600/800', true,  true)
on conflict (user_id) do nothing;

-- Handy admin snippets (replace the id with your user's id from public.users):
--   update public.users set wallet_balance = 2000 where id = '<uuid>';   -- top up
--   update public.users set is_vip = true         where id = '<uuid>';   -- make VIP
--   update public.users set role = 'partner', partner_ref_code = 'sales01' where id = '<uuid>';
