-- FamilArea — direct shared lists: invite only linked Contacts of the list owner.
-- Applies only to personal lists and intentionally has no Area dependency.

begin;

create or replace function public.search_invitable_list_accounts(
  p_list_id uuid,
  p_query text
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  v_owner uuid := public.require_current_account();
  v_query text := lower(btrim(coalesce(p_query, '')));
begin
  perform 1
  from public.lists l
  where l.id = p_list_id
    and l.owner_account_id = v_owner
    and l.area_id is null;
  if not found then raise exception 'permission denied'; end if;

  -- The candidate set is the owner's own linked Contacts, never the account base.
  if v_query = '' then return; end if;

  return query
  select jsonb_build_object(
    'account_id', a.id,
    'display_name', btrim(concat_ws(' ', c.first_name, c.last_name)),
    'avatar_path', p.avatar_path
  )
  from public.contacts c
  join public.contact_profile_links cpl
    on cpl.contact_id = c.id
   and cpl.owner_account_id = v_owner
  join public.profiles p on p.id = cpl.profile_id
  join public.accounts a on a.id = p.account_id
  where c.owner_account_id = v_owner
    and a.account_type = 'personal'
    and a.id <> v_owner
    and (
      c.first_name ilike v_query || '%'
      or coalesce(c.last_name, '') ilike v_query || '%'
    )
    and not exists (
      select 1
      from public.list_participants lp
      where lp.list_id = p_list_id and lp.account_id = a.id
    )
    and not exists (
      select 1
      from public.list_invites li
      where li.list_id = p_list_id
        and li.recipient_account_id = a.id
        and li.status = 'pending'
    )
  order by c.first_name, c.last_name nulls first, c.id
  limit 5;
end
$$;

create or replace function public.create_list_invite(
  p_list_id uuid,
  p_recipient_account_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_owner uuid := public.require_current_account();
  v_invite_id uuid;
begin
  perform 1
  from public.lists l
  where l.id = p_list_id and l.owner_account_id = v_owner and l.area_id is null
  for update;
  if not found then raise exception 'permission denied'; end if;
  if p_recipient_account_id = v_owner then raise exception 'cannot invite list owner'; end if;

  if not exists (
    select 1
    from public.contacts c
    join public.contact_profile_links cpl
      on cpl.contact_id = c.id
     and cpl.owner_account_id = v_owner
    join public.profiles p on p.id = cpl.profile_id
    join public.accounts a on a.id = p.account_id
    where c.owner_account_id = v_owner
      and a.id = p_recipient_account_id
      and a.account_type = 'personal'
  ) then
    raise exception 'recipient is not an invitable linked contact';
  end if;

  if exists(select 1 from public.list_participants lp where lp.list_id = p_list_id and lp.account_id = p_recipient_account_id) then
    raise exception 'recipient is already a participant';
  end if;
  if exists(select 1 from public.list_invites li where li.list_id = p_list_id and li.recipient_account_id = p_recipient_account_id and li.status = 'pending') then
    raise exception 'pending invite already exists';
  end if;
  insert into public.list_invites(list_id, invited_by_account_id, recipient_account_id)
  values(p_list_id, v_owner, p_recipient_account_id)
  returning id into v_invite_id;
  return v_invite_id;
end
$$;

revoke all on function public.search_invitable_list_accounts(uuid,text), public.create_list_invite(uuid,uuid) from public, anon;
grant execute on function public.search_invitable_list_accounts(uuid,text), public.create_list_invite(uuid,uuid) to authenticated;

commit;
