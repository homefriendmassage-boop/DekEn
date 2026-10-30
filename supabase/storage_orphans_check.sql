-- READ-ONLY: counts the files in Storage that no row in the database points to any more ("orphans").
-- Run in Supabase -> SQL Editor. It changes nothing.
with refs as (
  select 'worker-originals' as bucket, original_path as name from public.profile_photos
  union select 'worker-originals', original_path from public.draft_photos
  union select 'worker-originals', original_path from public.workers
  union select 'worker-originals', original_path from public.worker_applications
  -- the public (mosaic) copy has the same name + "-public"
  union select 'worker-public', regexp_replace(original_path, '\.jpg$', '-public.jpg') from public.profile_photos
  union select 'worker-public', regexp_replace(original_path, '\.jpg$', '-public.jpg') from public.draft_photos
  union select 'worker-public', regexp_replace(original_path, '\.jpg$', '-public.jpg') from public.workers
  union select 'worker-public', regexp_replace(original_path, '\.jpg$', '-public.jpg') from public.worker_applications
  union select 'worker-public', substring(public_url from '/worker-public/(.*)$') from public.profile_photos
  union select 'worker-public', substring(public_url from '/worker-public/(.*)$') from public.draft_photos
  union select 'worker-public', substring(profile_image from '/worker-public/(.*)$') from public.workers
  union select 'worker-public', substring(profile_image from '/worker-public/(.*)$') from public.worker_applications
  union select 'id-docs', age_id_path from public.worker_applications
  union select 'id-docs', age_selfie_path from public.worker_applications
  union select 'agency-logos', logo_path from public.agencies
  union select 'agency-logos', new_logo_path from public.agency_edit_requests
)
select o.bucket_id as bucket,
       count(*) as files,
       count(*) filter (where r.name is null) as orphans,
       count(*) filter (where r.name is null and o.created_at < now() - interval '3 days') as orphans_older_than_3_days,
       round(coalesce(sum((o.metadata->>'size')::bigint) filter (where r.name is null), 0) / 1048576.0, 1) as orphan_mb,
       round(coalesce(sum((o.metadata->>'size')::bigint), 0) / 1048576.0, 1) as total_mb
  from storage.objects o
  left join refs r on r.bucket = o.bucket_id and r.name = o.name
 where o.bucket_id in ('worker-originals', 'worker-public', 'id-docs', 'agency-logos')
 group by o.bucket_id
 order by 1;
