create or replace function public.admin_verify_account_purge_storage(p_account_id uuid, p_confirmation text)
returns jsonb
language plpgsql security definer set search_path=public,storage,pg_temp as $$
declare v_admin uuid; v_email text; v_job public.account_purge_jobs%rowtype; v_remaining jsonb;
begin
  v_admin:=public.require_system_admin();
  select lower(btrim(u.email)) into v_email from public.accounts a join auth.users u on u.id=a.auth_user_id where a.id=p_account_id;
  if v_email is null then raise exception 'account not found'; end if;
  if p_account_id=v_admin then raise exception 'cannot delete current system admin account'; end if;
  if lower(btrim(coalesce(p_confirmation,''))) is distinct from v_email then raise exception 'invalid deletion confirmation'; end if;
  select * into v_job from public.account_purge_jobs where target_account_id=p_account_id and requested_by_account_id=v_admin and expires_at>now();
  if not found then raise exception 'prepare storage purge before verifying storage'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('bucket_id',so.bucket_id,'name',so.name) order by so.bucket_id,so.name),'[]'::jsonb)
    into v_remaining
  from storage.objects so,jsonb_to_recordset(v_job.storage_manifest) x(bucket_id text,name text)
  where so.bucket_id=x.bucket_id and so.name=x.name;
  return jsonb_build_object('remaining',v_remaining,'complete',jsonb_array_length(v_remaining)=0);
end $$;
revoke all on function public.admin_verify_account_purge_storage(uuid,text) from public,anon;
grant execute on function public.admin_verify_account_purge_storage(uuid,text) to authenticated;
alter function public.admin_verify_account_purge_storage(uuid,text) owner to postgres;
