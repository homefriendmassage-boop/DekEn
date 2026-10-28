-- DEV ONLY. Run after migration_002.sql. Adds 21 more demo workers so you can test
-- the "free = top 10 per category" rule (12 in category 'ent').
insert into auth.users (id, instance_id, aud, role, email)
select ('00000000-0000-0000-0000-' || lpad((100 + n)::text, 12, '0'))::uuid,
       '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'demo' || (100 + n) || '@example.invalid'
from generate_series(1, 21) n
on conflict do nothing;

update public.users set role = 'worker'
 where id in (select ('00000000-0000-0000-0000-' || lpad((100 + n)::text, 12, '0'))::uuid
                from generate_series(1, 21) n);

insert into public.workers (user_id, display_name, category, price, profile_image, is_online, is_boosted)
select ('00000000-0000-0000-0000-' || lpad((100 + n)::text, 12, '0'))::uuid,
       'Demo ' || n,
       case when n <= 12 then 'ent' when n <= 15 then 'bartender' when n <= 17 then 'ent_hard'
            when n <= 19 then 'masseuse' else 'spa_vip' end,
       1500 + n * 100,
       'https://picsum.photos/seed/d' || n || '/600/800',
       (n % 4 <> 0),
       (n % 5 = 0)
from generate_series(1, 21) n
on conflict (user_id) do nothing;

-- Give yourself a plan to test (find your id: select id, display_name from public.users;)
--   select public.set_membership('<your user id>', 1, 30);   -- VIP 100
--   update public.users set wallet_balance = 2000 where id = '<your user id>';
