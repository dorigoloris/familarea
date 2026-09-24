-- FamilArea -- complete System Admin account purge with Storage API manifest.
-- Storage objects are never deleted with SQL: the browser uses the Storage API
-- only for paths registered in a short-lived, server-authorized purge job.

begin;

alter table public.attachments alter column uploaded_by_account_id drop not null;
alter table public.attachments drop constraint if exists attachments_uploaded_by_account_id_fkey;
alter table public.attachments add constraint attachments_uploaded_by_account_id_fkey
  foreign key (uploaded_by_account_id) references public.accounts(id) on delete set null;

create table if not exists public.account_purge_jobs (
  id uuid primary key default gen_random_uuid(),
  target_account_id uuid not null references public.accounts(id) on delete restrict,
  requested_by_account_id uuid not null references public.accounts(id) on delete restrict,
  storage_manifest jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes'
);
create unique index if not exists account_purge_jobs_target_idx on public.account_purge_jobs(target_account_id);
alter table public.account_purge_jobs enable row level security;
revoke all on public.account_purge_jobs from public, anon, authenticated;

create or replace function public.admin_account_purge_manifest(p_account_id uuid)
returns jsonb language sql security definer stable set search_path=public,storage,pg_temp as $$
  with subject as (
    select a.auth_user_id, p.avatar_path as profile_avatar_path,
           o.avatar_path as organization_avatar_path, o.dashboard_cover_path,
           array(select ar.image_path from public.areas ar where ar.owner_account_id=a.id and ar.image_path is not null) as area_image_paths
    from public.accounts a left join public.profiles p on p.account_id=a.id
      left join public.organizations o on o.account_id=a.id where a.id=p_account_id
  ), paths as (
    select 'profile-avatars'::text bucket_id, profile_avatar_path name from subject where profile_avatar_path is not null
    union all select 'organization-avatars', organization_avatar_path from subject where organization_avatar_path is not null
    union all select 'organization-dashboard-covers', dashboard_cover_path from subject where dashboard_cover_path is not null
    union all select 'area-images', unnest(area_image_paths) from subject
    union all select 'familarea-attachments', at.storage_path from public.attachments at
      where at.owner_account_id=p_account_id or at.area_id in (select id from public.areas where owner_account_id=p_account_id)
  ), objects as (
    select so.bucket_id,so.name from storage.objects so, subject s where so.owner=s.auth_user_id or so.owner_id=s.auth_user_id::text
    union select so.bucket_id,so.name from storage.objects so join paths p on p.bucket_id=so.bucket_id and p.name=so.name
  ) select coalesce(jsonb_agg(jsonb_build_object('bucket_id',bucket_id,'name',name) order by bucket_id,name),'[]'::jsonb) from objects
$$;

create or replace function public.admin_get_account_delete_plan(p_account_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public,storage,pg_temp as $$
declare v_caller uuid; v_account record; v_manifest jsonb; begin
  v_caller:=public.require_system_admin();
  select a.id,a.auth_user_id,a.account_type::text,u.email,p.id profile_id into v_account
  from public.accounts a join auth.users u on u.id=a.auth_user_id left join public.profiles p on p.account_id=a.id where a.id=p_account_id;
  if v_account is null then raise exception 'account not found'; end if;
  v_manifest:=public.admin_account_purge_manifest(p_account_id);
  return jsonb_build_object('account',jsonb_build_object('account_id',v_account.id,'account_type',v_account.account_type,'email',v_account.email),'is_self',v_account.id=v_caller,'can_delete',v_account.id<>v_caller,
    'delete',jsonb_build_object(
      'areas',(select count(*) from public.areas where owner_account_id=v_account.id),
      'activities',(select count(*) from public.activities where owner_account_id=v_account.id or area_id in(select id from public.areas where owner_account_id=v_account.id)),
      'events',(select count(*) from public.events where owner_account_id=v_account.id or area_id in(select id from public.areas where owner_account_id=v_account.id)),
      'lists',(select count(*) from public.lists where owner_account_id=v_account.id or area_id in(select id from public.areas where owner_account_id=v_account.id)),
      'contacts',(select count(*) from public.contacts where owner_account_id=v_account.id),
      'deadlines',(select count(*) from public.deadlines where owner_account_id=v_account.id),
      'families',(select count(*) from public.families where owner_account_id=v_account.id),
      'attachments',(select count(*) from public.attachments where owner_account_id=v_account.id or area_id in(select id from public.areas where owner_account_id=v_account.id)),
      'area_invites_created',(select count(*) from public.area_invites where invited_by_account_id=v_account.id),
      'event_invites_owned',(select count(*) from public.event_invites where owner_account_id=v_account.id),
      'storage_objects',jsonb_array_length(v_manifest)),
    'unlink',jsonb_build_object(
      'area_memberships',(select count(*) from public.area_memberships where profile_id=v_account.profile_id),
      'organization_memberships',(select count(*) from public.organization_members where profile_id=v_account.profile_id),
      'activity_assignees',(select count(*) from public.activity_assignees where profile_id=v_account.profile_id),
      'external_event_participant_profiles',(select count(*) from public.event_participants ep join public.events e on e.id=ep.event_id where ep.profile_id=v_account.profile_id and e.owner_account_id<>v_account.id),
      'external_contact_profile_links',(select count(*) from public.contact_profile_links where profile_id=v_account.profile_id and owner_account_id<>v_account.id),
      'external_attachment_uploads',(select count(*) from public.attachments where uploaded_by_account_id=v_account.id and owner_account_id<>v_account.id),
      'family_access',(select count(*) from public.family_access where profile_id=v_account.profile_id)));
end $$;

create or replace function public.admin_prepare_account_purge(p_account_id uuid,p_confirmation text)
returns jsonb language plpgsql security definer set search_path=public,storage,pg_temp as $$
declare v_admin uuid; v_email text; v_manifest jsonb; v_job public.account_purge_jobs%rowtype; begin
  v_admin:=public.require_system_admin();
  select lower(btrim(u.email)) into v_email from public.accounts a join auth.users u on u.id=a.auth_user_id where a.id=p_account_id for update of a;
  if v_email is null then raise exception 'account not found'; end if;
  if p_account_id=v_admin then raise exception 'cannot delete current system admin account'; end if;
  if lower(btrim(coalesce(p_confirmation,''))) is distinct from v_email then raise exception 'invalid deletion confirmation'; end if;
  delete from public.account_purge_jobs where expires_at<=now();
  select * into v_job from public.account_purge_jobs where target_account_id=p_account_id;
  if found and v_job.requested_by_account_id<>v_admin then raise exception 'account purge already prepared by another system admin'; end if;
  v_manifest:=public.admin_account_purge_manifest(p_account_id);
  if found then update public.account_purge_jobs set storage_manifest=v_manifest,created_at=now(),expires_at=now()+interval '30 minutes' where id=v_job.id returning * into v_job;
  else insert into public.account_purge_jobs(target_account_id,requested_by_account_id,storage_manifest) values(p_account_id,v_admin,v_manifest) returning * into v_job; end if;
  return jsonb_build_object('job_id',v_job.id,'storage_objects',v_manifest,'plan',public.admin_get_account_delete_plan(p_account_id));
end $$;

create or replace function public.can_delete_account_purge_storage_object(p_bucket_id text,p_name text)
returns boolean language sql security definer stable set search_path=public,pg_temp as $$
  select exists(select 1 from public.account_purge_jobs j,jsonb_to_recordset(j.storage_manifest) x(bucket_id text,name text)
    where j.requested_by_account_id=public.require_system_admin() and j.expires_at>now() and x.bucket_id=p_bucket_id and x.name=p_name)
$$;
drop policy if exists system_admin_purge_storage_delete on storage.objects;
create policy system_admin_purge_storage_delete on storage.objects for delete to authenticated using (public.can_delete_account_purge_storage_object(bucket_id,name));

create or replace function public.admin_delete_account(p_account_id uuid,p_confirmation text)
returns jsonb language plpgsql security definer set search_path=public,storage,pg_temp as $$
declare v_admin uuid; v_account record; v_job public.account_purge_jobs%rowtype; begin
  v_admin:=public.require_system_admin();
  select a.id,a.auth_user_id,p.id profile_id,lower(btrim(u.email)) email into v_account from public.accounts a join auth.users u on u.id=a.auth_user_id left join public.profiles p on p.account_id=a.id where a.id=p_account_id for update of a;
  if v_account is null then raise exception 'account not found'; end if;
  if p_account_id=v_admin then raise exception 'cannot delete current system admin account'; end if;
  if lower(btrim(coalesce(p_confirmation,''))) is distinct from v_account.email then raise exception 'invalid deletion confirmation'; end if;
  select * into v_job from public.account_purge_jobs where target_account_id=p_account_id and requested_by_account_id=v_admin and expires_at>now() for update;
  if not found then raise exception 'prepare storage purge before deleting account'; end if;
  if exists(select 1 from storage.objects so,jsonb_to_recordset(v_job.storage_manifest) x(bucket_id text,name text) where so.bucket_id=x.bucket_id and so.name=x.name) then raise exception 'storage purge is not complete'; end if;
  update public.attachments set uploaded_by_account_id=null where uploaded_by_account_id=v_account.id and owner_account_id<>v_account.id;
  delete from public.area_invites where invited_by_account_id=v_account.id;
  delete from public.account_purge_jobs where id=v_job.id;
  delete from auth.users where id=v_account.auth_user_id;
  if not found then raise exception 'auth user not found'; end if;
  return jsonb_build_object('deleted_account_id',v_account.id,'deleted_at',now());
end $$;

revoke all on function public.admin_account_purge_manifest(uuid),public.can_delete_account_purge_storage_object(text,text),public.admin_prepare_account_purge(uuid,text),public.admin_get_account_delete_plan(uuid),public.admin_delete_account(uuid,text) from public,anon;
grant execute on function public.can_delete_account_purge_storage_object(text,text),public.admin_prepare_account_purge(uuid,text),public.admin_get_account_delete_plan(uuid),public.admin_delete_account(uuid,text) to authenticated;
alter function public.admin_account_purge_manifest(uuid) owner to postgres;
alter function public.can_delete_account_purge_storage_object(text,text) owner to postgres;
alter function public.admin_prepare_account_purge(uuid,text) owner to postgres;
alter function public.admin_get_account_delete_plan(uuid) owner to postgres;
alter function public.admin_delete_account(uuid,text) owner to postgres;

commit;
