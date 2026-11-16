-- FamilArea V2 -- recipient inbox for email-bound Album invitations.
-- This patch keeps email invitations separate from access grants: an accepted
-- memory_collaboration remains the only record that authorizes album access.

begin;

create or replace function public.get_my_memory_share_invitations()
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_recipient_email text;
begin
  select public.normalize_contact_email(u.email)
  into v_recipient_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = v_recipient_account_id
    and a.auth_user_id = auth.uid()
    and a.account_type in ('personal', 'organization')
    and u.email_confirmed_at is not null;

  if v_recipient_email is null then
    return;
  end if;

  return query
  select jsonb_build_object(
    'invitation_id', i.id,
    'memory_id', m.id,
    'title', m.title,
    'occurred_on', m.occurred_on,
    'cover_attachment_id', m.cover_attachment_id,
    'inviter_display_name', inviter.display_name,
    'inviter_avatar_path', inviter.avatar_path,
    'status', i.status,
    'created_at', i.created_at,
    'expires_at', i.expires_at
  )
  from public.memory_share_invitations i
  join public.memories m
    on m.id = i.memory_id
   and m.owner_account_id = i.owner_account_id
  join lateral public.contact_share_sender_identity(i.owner_account_id) inviter on true
  where i.recipient_email = v_recipient_email
    and i.status = 'pending'
    and i.expires_at > now()
  order by i.created_at desc, i.id;
end;
$$;

create or replace function public.accept_my_memory_share_invitation_by_id(
  p_invitation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_recipient_email text;
  v_invitation public.memory_share_invitations%rowtype;
  v_collaboration public.memory_collaborations%rowtype;
  v_collaboration_id uuid;
begin
  select public.normalize_contact_email(u.email)
  into v_recipient_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = v_recipient_account_id
    and a.auth_user_id = auth.uid()
    and a.account_type in ('personal', 'organization')
    and u.email_confirmed_at is not null;

  if v_recipient_email is null then
    raise exception 'verified recipient email required';
  end if;

  select * into v_invitation
  from public.memory_share_invitations i
  where i.id = p_invitation_id
  for update;

  if not found then
    raise exception 'memory share invitation unavailable';
  end if;

  if not exists (
    select 1
    from public.memories m
    where m.id = v_invitation.memory_id
      and m.owner_account_id = v_invitation.owner_account_id
  ) then
    raise exception 'memory share invitation unavailable';
  end if;

  if v_invitation.status = 'pending' and v_invitation.expires_at <= now() then
    raise exception 'memory share invitation expired';
  end if;

  if v_invitation.status <> 'pending'
    or v_invitation.recipient_email <> v_recipient_email then
    raise exception 'memory share invitation unavailable';
  end if;

  select * into v_collaboration
  from public.memory_collaborations mc
  where mc.memory_id = v_invitation.memory_id
    and mc.recipient_account_id = v_recipient_account_id
    and mc.status in ('pending', 'accepted')
  for update;

  if found then
    v_collaboration_id := v_collaboration.id;
    if v_collaboration.status = 'pending' then
      update public.memory_collaborations
      set status = 'accepted', accepted_at = now()
      where id = v_collaboration_id;
    end if;
  else
    begin
      insert into public.memory_collaborations(
        memory_id,
        owner_account_id,
        recipient_account_id,
        status,
        accepted_at
      ) values (
        v_invitation.memory_id,
        v_invitation.owner_account_id,
        v_recipient_account_id,
        'accepted',
        now()
      )
      returning id into v_collaboration_id;
    exception when unique_violation then
      select * into v_collaboration
      from public.memory_collaborations mc
      where mc.memory_id = v_invitation.memory_id
        and mc.recipient_account_id = v_recipient_account_id
        and mc.status in ('pending', 'accepted')
      for update;

      if not found then
        raise;
      end if;

      v_collaboration_id := v_collaboration.id;
      if v_collaboration.status = 'pending' then
        update public.memory_collaborations
        set status = 'accepted', accepted_at = now()
        where id = v_collaboration_id;
      end if;
    end;
  end if;

  update public.memory_share_invitations
  set status = 'accepted',
      accepted_at = now(),
      accepted_by_account_id = v_recipient_account_id,
      accepted_collaboration_id = v_collaboration_id
  where id = v_invitation.id;

  return v_collaboration_id;
end;
$$;

create or replace function public.decline_my_memory_share_invitation_by_id(
  p_invitation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_recipient_email text;
  v_invitation public.memory_share_invitations%rowtype;
begin
  select public.normalize_contact_email(u.email)
  into v_recipient_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = v_recipient_account_id
    and a.auth_user_id = auth.uid()
    and a.account_type in ('personal', 'organization')
    and u.email_confirmed_at is not null;

  if v_recipient_email is null then
    raise exception 'verified recipient email required';
  end if;

  select * into v_invitation
  from public.memory_share_invitations i
  where i.id = p_invitation_id
  for update;

  if not found then
    raise exception 'memory share invitation unavailable';
  end if;

  if not exists (
    select 1
    from public.memories m
    where m.id = v_invitation.memory_id
      and m.owner_account_id = v_invitation.owner_account_id
  ) then
    raise exception 'memory share invitation unavailable';
  end if;

  if v_invitation.status = 'pending' and v_invitation.expires_at <= now() then
    raise exception 'memory share invitation expired';
  end if;

  if v_invitation.status <> 'pending'
    or v_invitation.recipient_email <> v_recipient_email then
    raise exception 'memory share invitation unavailable';
  end if;

  update public.memory_share_invitations
  set status = 'declined', declined_at = now()
  where id = v_invitation.id;
end;
$$;

create or replace function public.accept_my_memory_share_invitation(
  p_token text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invitation_id uuid;
begin
  select i.id into v_invitation_id
  from public.memory_share_invitations i
  where i.token_hash = public.hash_memory_share_invitation_token(p_token)
  for update;

  if v_invitation_id is null then
    raise exception 'memory share invitation unavailable';
  end if;

  return public.accept_my_memory_share_invitation_by_id(v_invitation_id);
end;
$$;

create or replace function public.decline_my_memory_share_invitation(
  p_token text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invitation_id uuid;
begin
  select i.id into v_invitation_id
  from public.memory_share_invitations i
  where i.token_hash = public.hash_memory_share_invitation_token(p_token)
  for update;

  if v_invitation_id is null then
    raise exception 'memory share invitation unavailable';
  end if;

  perform public.decline_my_memory_share_invitation_by_id(v_invitation_id);
end;
$$;

create or replace function public.create_memory_collaboration(
  p_memory_id uuid,
  p_recipient_account_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_recipient_email text;
  v_collaboration_id uuid;
begin
  perform 1
  from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = v_owner_account_id
  for update;
  if not found then
    raise exception 'permission denied';
  end if;

  if p_recipient_account_id = v_owner_account_id then
    raise exception 'cannot invite memory owner';
  end if;

  if not public.is_invitable_memory_collaboration_recipient(
    v_owner_account_id,
    p_recipient_account_id
  ) then
    raise exception 'recipient is not an invitable linked contact';
  end if;

  select public.normalize_contact_email(u.email)
  into v_recipient_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = p_recipient_account_id;

  if exists (
    select 1
    from public.memory_share_invitations i
    where i.memory_id = p_memory_id
      and i.status = 'pending'
      and i.expires_at > now()
      and i.recipient_email = v_recipient_email
  ) then
    raise exception 'active memory share invitation already exists';
  end if;

  if exists (
    select 1
    from public.memory_collaborations mc
    where mc.memory_id = p_memory_id
      and mc.recipient_account_id = p_recipient_account_id
      and mc.status in ('pending', 'accepted')
  ) then
    raise exception 'active memory collaboration already exists';
  end if;

  insert into public.memory_collaborations(
    memory_id,
    owner_account_id,
    recipient_account_id
  ) values (
    p_memory_id,
    v_owner_account_id,
    p_recipient_account_id
  )
  returning id into v_collaboration_id;

  return v_collaboration_id;
end;
$$;

create or replace function public.get_my_pending_invites_count()
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_account_id uuid := public.require_current_account();
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();

  return ((select count(*) from public.family_invites fi where fi.recipient_email = v_recipient.email and fi.status = 'pending' and (fi.expires_at is null or fi.expires_at > now())) +
    (select count(*) from public.event_invites ei where ei.recipient_email = v_recipient.email and ei.status = 'pending' and ei.expires_at > now()) +
    (select count(*) from public.contact_suggestions cs where cs.recipient_email = v_recipient.email and cs.status = 'pending' and cs.expires_at > now()) +
    (select count(*) from public.contact_shares cs where cs.recipient_email = v_recipient.email and cs.status = 'pending' and cs.expires_at > now()) +
    (select count(*) from public.list_invites li join public.lists l on l.id = li.list_id where li.recipient_account_id = v_account_id and li.status = 'pending' and l.owner_account_id is not null) +
    (select count(*) from public.deadline_collaborations dc where dc.recipient_account_id = v_account_id and dc.status = 'pending') +
    (select count(*)
     from public.memory_collaborations mc
     where mc.recipient_account_id = v_account_id
       and mc.status = 'pending'
       and not exists (
         select 1
         from public.memory_share_invitations i
         join auth.users u on u.id = auth.uid()
         join public.memories m
           on m.id = i.memory_id
          and m.owner_account_id = i.owner_account_id
         where i.memory_id = mc.memory_id
           and i.recipient_email = public.normalize_contact_email(u.email)
           and i.status = 'pending'
           and i.expires_at > now()
           and u.email_confirmed_at is not null
       )) +
    (select count(*)
     from public.memory_share_invitations i
     join public.accounts a on a.id = v_account_id and a.auth_user_id = auth.uid()
     join auth.users u on u.id = a.auth_user_id
     join public.memories m
       on m.id = i.memory_id
      and m.owner_account_id = i.owner_account_id
     where a.account_type in ('personal', 'organization')
       and u.email_confirmed_at is not null
       and i.recipient_email = public.normalize_contact_email(u.email)
       and i.status = 'pending'
       and i.expires_at > now())
  )::integer;
end;
$$;

alter function public.get_my_memory_share_invitations() owner to postgres;
alter function public.accept_my_memory_share_invitation_by_id(uuid) owner to postgres;
alter function public.decline_my_memory_share_invitation_by_id(uuid) owner to postgres;
alter function public.accept_my_memory_share_invitation(text) owner to postgres;
alter function public.decline_my_memory_share_invitation(text) owner to postgres;
alter function public.create_memory_collaboration(uuid, uuid) owner to postgres;
alter function public.get_my_pending_invites_count() owner to postgres;

revoke all on function public.get_my_memory_share_invitations() from public, anon;
revoke all on function public.accept_my_memory_share_invitation_by_id(uuid) from public, anon;
revoke all on function public.decline_my_memory_share_invitation_by_id(uuid) from public, anon;
revoke all on function public.accept_my_memory_share_invitation(text) from public, anon;
revoke all on function public.decline_my_memory_share_invitation(text) from public, anon;
revoke all on function public.create_memory_collaboration(uuid, uuid) from public, anon;
revoke all on function public.get_my_pending_invites_count() from public, anon;

grant execute on function public.get_my_memory_share_invitations() to authenticated;
grant execute on function public.accept_my_memory_share_invitation_by_id(uuid) to authenticated;
grant execute on function public.decline_my_memory_share_invitation_by_id(uuid) to authenticated;
grant execute on function public.accept_my_memory_share_invitation(text) to authenticated;
grant execute on function public.decline_my_memory_share_invitation(text) to authenticated;
grant execute on function public.create_memory_collaboration(uuid, uuid) to authenticated;
grant execute on function public.get_my_pending_invites_count() to authenticated;

commit;
