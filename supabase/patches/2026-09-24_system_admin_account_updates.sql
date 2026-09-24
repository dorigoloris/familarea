-- FamilArea — Controlled System Admin account updates.

create or replace function public.admin_update_account_details(
  p_account_id uuid,
  p_first_name text default null,
  p_last_name text default null,
  p_organization_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_account_type text;
  v_first_name text := nullif(btrim(coalesce(p_first_name, '')), '');
  v_last_name text := nullif(btrim(coalesce(p_last_name, '')), '');
  v_organization_name text := nullif(btrim(coalesce(p_organization_name, '')), '');
begin
  perform public.require_system_admin();

  select account_type into v_account_type
  from public.accounts
  where id = p_account_id
  for update;

  if not found then
    raise exception 'account not found';
  end if;

  if v_account_type = 'personal' then
    if v_first_name is null then
      raise exception 'first name is required';
    end if;

    update public.profiles
    set first_name = v_first_name,
        last_name = v_last_name,
        updated_at = now()
    where account_id = p_account_id;

    if not found then
      raise exception 'profile not found';
    end if;
  elsif v_account_type = 'organization' then
    if v_organization_name is null then
      raise exception 'organization name is required';
    end if;

    update public.organizations
    set name = v_organization_name,
        updated_at = now()
    where account_id = p_account_id;

    if not found then
      raise exception 'organization not found';
    end if;
  else
    raise exception 'unsupported account type';
  end if;

  return public.admin_get_account_summary(p_account_id);
end;
$$;

create or replace function public.admin_update_account_email(
  p_account_id uuid,
  p_email text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_auth_user_id uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  perform public.require_system_admin();

  if v_email = ''
    or position('@' in v_email) < 2
    or position('.' in split_part(v_email, '@', 2)) = 0 then
    raise exception 'invalid email';
  end if;

  select auth_user_id into v_auth_user_id
  from public.accounts
  where id = p_account_id
  for update;

  if not found then
    raise exception 'account not found';
  end if;

  if v_auth_user_id = auth.uid() then
    raise exception 'cannot change your own system admin email';
  end if;

  if exists (
    select 1 from auth.users u
    where lower(btrim(coalesce(u.email, ''))) = v_email
      and u.id <> v_auth_user_id
  ) or exists (
    select 1 from auth.identities i
    where i.provider = 'email'
      and lower(btrim(coalesce(i.provider_id, ''))) = v_email
      and i.user_id <> v_auth_user_id
  ) then
    raise exception 'email already in use';
  end if;

  if not exists (
    select 1 from auth.identities i
    where i.user_id = v_auth_user_id and i.provider = 'email'
  ) then
    raise exception 'email identity not found';
  end if;

  update auth.users
  set email = v_email,
      email_change = null,
      email_change_token_new = null,
      email_change_token_current = null,
      email_change_sent_at = null,
      email_change_confirm_status = 0,
      updated_at = now()
  where id = v_auth_user_id;

  update auth.identities
  set provider_id = v_email,
      identity_data = jsonb_set(identity_data, '{email}', to_jsonb(v_email), true),
      updated_at = now()
  where user_id = v_auth_user_id and provider = 'email';

  return public.admin_get_account_summary(p_account_id);
end;
$$;

revoke all on function public.admin_update_account_details(uuid,text,text,text) from public,anon;
revoke all on function public.admin_update_account_email(uuid,text) from public,anon;
grant execute on function public.admin_update_account_details(uuid,text,text,text) to authenticated;
grant execute on function public.admin_update_account_email(uuid,text) to authenticated;
alter function public.admin_update_account_details(uuid,text,text,text) owner to postgres;
alter function public.admin_update_account_email(uuid,text) owner to postgres;
