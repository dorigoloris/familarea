-- FamilArea — System Administration: conservative account deletion.
-- This migration intentionally permits deletion only when the account has no
-- owned business data or storage references. Personal participation records
-- are removed atomically; Areas, Events and other owned data are never
-- removed implicitly by this administrative action.

begin;

create or replace function public.admin_get_account_delete_plan(p_account_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_caller_account_id uuid;
  v_account record;
  v_profile_id uuid;
  v_blockers jsonb;
  v_removals jsonb;
begin
  v_caller_account_id := public.require_system_admin();

  select
    a.id as account_id,
    a.auth_user_id,
    a.account_type::text as account_type,
    u.email,
    p.id as profile_id,
    to_jsonb(p) ->> 'avatar_path' as profile_avatar_path,
    o.id as organization_id
  into v_account
  from public.accounts a
  left join auth.users u on u.id = a.auth_user_id
  left join public.profiles p on p.account_id = a.id
  left join public.organizations o on o.account_id = a.id
  where a.id = p_account_id;

  if v_account is null then
    raise exception 'account not found';
  end if;

  v_profile_id := v_account.profile_id;
  v_blockers := jsonb_build_object(
    'self', v_account.account_id = v_caller_account_id,
    'organization', v_account.organization_id is not null,
    'owned_areas', (select count(*) from public.areas ar where ar.owner_account_id = v_account.account_id),
    'activities', (select count(*) from public.activities ac where ac.owner_account_id = v_account.account_id),
    'events', (select count(*) from public.events ev where ev.owner_account_id = v_account.account_id),
    'lists', (select count(*) from public.lists li where li.owner_account_id = v_account.account_id),
    'contacts', (select count(*) from public.contacts c where c.owner_account_id = v_account.account_id),
    'families', (select count(*) from public.families f where f.owner_account_id = v_account.account_id),
    'deadlines', (select count(*) from public.deadlines d where d.owner_account_id = v_account.account_id),
    'attachments_owned', (select count(*) from public.attachments at where at.owner_account_id = v_account.account_id),
    'attachments_uploaded', (select count(*) from public.attachments at where at.uploaded_by_account_id = v_account.account_id),
    'profile_avatar', coalesce(v_account.profile_avatar_path, '') <> ''
  );
  v_removals := jsonb_build_object(
    'organization_memberships', (select count(*) from public.organization_members om where om.profile_id = v_profile_id),
    'area_memberships', (select count(*) from public.area_memberships am where am.profile_id = v_profile_id),
    'activity_assignees', (select count(*) from public.activity_assignees aa where aa.profile_id = v_profile_id),
    'event_participations', (select count(*) from public.event_participants ep where ep.profile_id = v_profile_id),
    'area_invites_sent', (select count(*) from public.area_invites ai where ai.invited_by_account_id = v_account.account_id),
    'area_invites_accepted', (select count(*) from public.area_invites ai where ai.accepted_by_profile_id = v_profile_id),
    'area_invites_addressed', (
      select count(*) from public.area_invites ai
      where lower(coalesce(to_jsonb(ai) ->> 'invitee_email', to_jsonb(ai) ->> 'recipient_email', '')) = lower(coalesce(v_account.email, ''))
    ),
    'profile_interests', (select count(*) from public.profile_interests pi where pi.profile_id = v_profile_id),
    'interest_category_proposals', (select count(*) from public.interest_category_proposals icp where icp.profile_id = v_profile_id),
    'family_access', (select count(*) from public.family_access fa where fa.profile_id = v_profile_id),
    'family_member_profile_links', (select count(*) from public.family_members fm where fm.linked_profile_id = v_profile_id),
    'system_admins', (select count(*) from public.system_admins sa where sa.account_id = v_account.account_id)
  );

  return jsonb_build_object(
    'account', jsonb_build_object(
      'account_id', v_account.account_id,
      'account_type', v_account.account_type,
      'email', v_account.email
    ),
    'is_self', v_account.account_id = v_caller_account_id,
    'blockers', v_blockers,
    'removals', v_removals,
    'can_delete', not (
      (v_blockers ->> 'self')::boolean
      or (v_blockers ->> 'organization')::boolean
      or (v_blockers ->> 'profile_avatar')::boolean
      or (v_blockers ->> 'owned_areas')::integer > 0
      or (v_blockers ->> 'activities')::integer > 0
      or (v_blockers ->> 'events')::integer > 0
      or (v_blockers ->> 'lists')::integer > 0
      or (v_blockers ->> 'contacts')::integer > 0
      or (v_blockers ->> 'families')::integer > 0
      or (v_blockers ->> 'deadlines')::integer > 0
      or (v_blockers ->> 'attachments_owned')::integer > 0
      or (v_blockers ->> 'attachments_uploaded')::integer > 0
    )
  );
end;
$$;

create or replace function public.admin_delete_account(
  p_account_id uuid,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_account_id uuid;
  v_account record;
  v_profile_id uuid;
  v_expected_confirmation text;
  v_plan jsonb;
begin
  v_caller_account_id := public.require_system_admin();

  select
    a.id as account_id,
    a.auth_user_id,
    a.account_type::text as account_type,
    u.email,
    p.id as profile_id
  into v_account
  from public.accounts a
  left join auth.users u on u.id = a.auth_user_id
  left join public.profiles p on p.account_id = a.id
  where a.id = p_account_id
  for update of a;

  if v_account is null then
    raise exception 'account not found';
  end if;
  if v_account.account_id = v_caller_account_id then
    raise exception 'cannot delete current system admin account';
  end if;
  if nullif(btrim(v_account.email), '') is null then
    raise exception 'account email is unavailable';
  end if;

  v_expected_confirmation := lower(btrim(v_account.email));
  if lower(btrim(coalesce(p_confirmation, ''))) is distinct from v_expected_confirmation then
    raise exception 'invalid deletion confirmation';
  end if;

  -- The plan is computed inside the same transaction after the account lock.
  v_plan := public.admin_get_account_delete_plan(p_account_id);
  if not coalesce((v_plan ->> 'can_delete')::boolean, false) then
    raise exception 'account deletion blocked by owned data or storage references';
  end if;
  v_profile_id := v_account.profile_id;

  -- These rows belong to the person as participant/member. They never delete
  -- the referenced Area, Event, Activity or Family.
  delete from public.organization_members where profile_id = v_profile_id;
  delete from public.activity_assignees where profile_id = v_profile_id;
  -- Legacy rows have profile_id NOT NULL and must be removed. If the future
  -- Contact-first schema is installed, retain the contact participant and
  -- unlink only this Profile instead.
  if exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'event_participants'
      and c.column_name = 'contact_id'
  ) and exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'event_participants'
      and c.column_name = 'profile_id'
      and c.is_nullable = 'YES'
  ) then
    update public.event_participants set profile_id = null where profile_id = v_profile_id;
  else
    delete from public.event_participants where profile_id = v_profile_id;
  end if;
  delete from public.area_memberships where profile_id = v_profile_id;
  delete from public.area_invites ai
  where ai.invited_by_account_id = v_account.account_id
     or ai.accepted_by_profile_id = v_profile_id
     or lower(coalesce(to_jsonb(ai) ->> 'invitee_email', to_jsonb(ai) ->> 'recipient_email', '')) = lower(v_account.email);
  delete from public.profile_interests where profile_id = v_profile_id;
  delete from public.interest_category_proposals where profile_id = v_profile_id;
  delete from public.family_access where profile_id = v_profile_id;
  update public.family_members set linked_profile_id = null where linked_profile_id = v_profile_id;
  delete from public.system_admins where account_id = v_account.account_id;

  -- accounts.auth_user_id has ON DELETE CASCADE. Removing auth.users last
  -- removes account/profile atomically with the PostgreSQL transaction.
  delete from auth.users where id = v_account.auth_user_id;
  if not found then
    raise exception 'auth user not found';
  end if;

  return jsonb_build_object(
    'deleted_account_id', v_account.account_id,
    'deleted_auth_user_id', v_account.auth_user_id,
    'deleted_at', now()
  );
end;
$$;

alter function public.admin_get_account_delete_plan(uuid) owner to postgres;
alter function public.admin_delete_account(uuid, text) owner to postgres;

revoke all on function public.admin_get_account_delete_plan(uuid) from public, anon;
revoke all on function public.admin_delete_account(uuid, text) from public, anon;
grant execute on function public.admin_get_account_delete_plan(uuid) to authenticated;
grant execute on function public.admin_delete_account(uuid, text) to authenticated;

commit;
