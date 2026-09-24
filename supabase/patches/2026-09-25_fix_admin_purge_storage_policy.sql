-- Fix Storage RLS execution as authenticated: do not call the private
-- require_system_admin() helper from a policy-visible function.

create or replace function public.can_delete_account_purge_storage_object(p_bucket_id text,p_name text)
returns boolean
language sql
security definer
stable
set search_path=public,pg_temp
as $$
  select exists(
    select 1
    from public.system_admins sa
    join public.accounts caller on caller.id=sa.account_id
    join public.account_purge_jobs j on j.requested_by_account_id=sa.account_id
    cross join lateral jsonb_to_recordset(j.storage_manifest) x(bucket_id text,name text)
    where caller.auth_user_id=auth.uid()
      and j.expires_at>now()
      and x.bucket_id=p_bucket_id
      and x.name=p_name
  )
$$;

revoke all on function public.can_delete_account_purge_storage_object(text,text) from public,anon;
grant execute on function public.can_delete_account_purge_storage_object(text,text) to authenticated;
alter function public.can_delete_account_purge_storage_object(text,text) owner to postgres;
