-- =============================================================================
-- migration_048.sql — run ONCE after migration_047.sql
-- Fix: uploading draft photos failed with "permission denied for table application_drafts". The storage policies looked at that table
-- directly, and the table is closed to the app's users. They now ask a SECURITY DEFINER helper instead (same rule as migration_047:
-- the draft's creator, or any admin for an admin draft).
-- =============================================================================

create or replace function public.draft_folder_writable(p_folder text, p_any_status boolean default false)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.application_drafts d
                  where d.id::text = p_folder and auth.uid() is not null
                    and (d.created_by = auth.uid() or (public.is_admin() and d.source = 'admin'))
                    and (p_any_status or d.status in ('draft', 'rejected', 'approved')))
$$;
revoke all on function public.draft_folder_writable(text, boolean) from public, anon;
grant execute on function public.draft_folder_writable(text, boolean) to authenticated;

do $$
declare b text;
begin
  foreach b in array array['worker-public', 'worker-originals'] loop
    execute format('drop policy if exists "%1$s_insert" on storage.objects', b);
    execute format($p$create policy "%1$s_insert" on storage.objects for insert to authenticated
      with check (bucket_id = %1$L and (
        ((storage.foldername(name))[1] = auth.uid()::text
          and (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'worker')
            or exists (select 1 from public.worker_applications a where a.user_id = auth.uid() and a.status = 'pending')))
        or public.draft_folder_writable((storage.foldername(name))[1])))$p$, b);
    execute format('drop policy if exists "%1$s_delete" on storage.objects', b);
    execute format($p$create policy "%1$s_delete" on storage.objects for delete to authenticated
      using (bucket_id = %1$L and ((storage.foldername(name))[1] = auth.uid()::text
        or public.draft_folder_writable((storage.foldername(name))[1], true)))$p$, b);
  end loop;
end $$;
