-- FamilArea — patch for the already-applied Admin account deletion RPC.
-- Changes only the confirmation phrase: the target email is now required.

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

  if v_account is null then raise exception 'account not found'; end if;
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

  v_plan := public.admin_get_account_delete_plan(p_account_id);
  if not coalesce((v_plan ->> 'can_delete')::boolean, false) then
    raise exception 'account deletion blocked by owned data or storage references';
  end if;
  v_profile_id := v_account.profile_id;

  delete from public.organization_members where profile_id = v_profile_id;
  delete from public.activity_assignees where profile_id = v_profile_id;
  if exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'event_participants' and c.column_name = 'contact_id'
  ) and exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'event_participants'
      and c.column_name = 'profile_id' and c.is_nullable = 'YES'
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

  delete from auth.users where id = v_account.auth_user_id;
  if not found then raise exception 'auth user not found'; end if;

  return jsonb_build_object(
    'deleted_account_id', v_account.account_id,
    'deleted_auth_user_id', v_account.auth_user_id,
    'deleted_at', now()
  );
end;
$$;

alter function public.admin_delete_account(uuid, text) owner to postgres;
revoke all on function public.admin_delete_account(uuid, text) from public, anon;
grant execute on function public.admin_delete_account(uuid, text) to authenticated;
