-- FamilArea V2 -- one owner-facing management list for Album shares.
-- This patch preserves invitations and collaborations. Archiving only hides an
-- invitation already abandoned by its recipient from the owner's management UI.

begin;

alter table public.memory_share_invitations
  add column if not exists owner_archived_at timestamptz;

alter table public.memory_collaborations
  add column if not exists revoked_by_account_id uuid
    references public.accounts(id) on delete set null;

create index if not exists memory_share_invitations_owner_unarchived_management_idx
  on public.memory_share_invitations(owner_account_id, memory_id, created_at desc)
  where owner_archived_at is null;

create or replace function public.leave_my_memory_collaboration(
  p_collaboration_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_status text;
begin
  if p_collaboration_id is null then
    raise exception 'memory collaboration unavailable';
  end if;

  select mc.status
  into v_status
  from public.memory_collaborations mc
  where mc.id = p_collaboration_id
    and mc.recipient_account_id = v_recipient_account_id
  for update;

  if not found then
    raise exception 'memory collaboration unavailable';
  end if;

  if v_status = 'revoked' then
    return false;
  end if;

  if v_status <> 'accepted' then
    raise exception 'memory collaboration unavailable';
  end if;

  update public.memory_collaborations
  set status = 'revoked',
      revoked_at = now(),
      revoked_by_account_id = v_recipient_account_id
  where id = p_collaboration_id
    and recipient_account_id = v_recipient_account_id
    and status = 'accepted';

  if not found then
    raise exception 'memory collaboration unavailable';
  end if;

  return true;
end;
$$;

create or replace function public.revoke_memory_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  update public.memory_collaborations mc
  set status = 'revoked',
      revoked_at = now(),
      revoked_by_account_id = v_owner_account_id
  where mc.id = p_collaboration_id
    and mc.owner_account_id = v_owner_account_id
    and mc.status = 'accepted';

  if not found then
    raise exception 'memory collaboration not found or not revocable';
  end if;
end;
$$;

create or replace function public.revoke_memory_share_invitation(
  p_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_invitation public.memory_share_invitations%rowtype;
begin
  select * into v_invitation
  from public.memory_share_invitations i
  where i.id = p_id
    and i.owner_account_id = v_owner_account_id
    and i.status = 'accepted'
  for update;

  if not found then
    raise exception 'memory share invitation not found or not revocable';
  end if;

  update public.memory_collaborations
  set status = 'revoked',
      revoked_at = now(),
      revoked_by_account_id = v_owner_account_id
  where id = v_invitation.accepted_collaboration_id
    and owner_account_id = v_owner_account_id
    and status = 'accepted';

  if not found then
    raise exception 'memory share invitation collaboration unavailable';
  end if;

  update public.memory_share_invitations
  set status = 'revoked',
      revoked_at = now()
  where id = v_invitation.id;
end;
$$;

create or replace function public.get_memory_share_management(
  p_memory_id uuid
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  if p_memory_id is null or not exists (
    select 1
    from public.memories m
    where m.id = p_memory_id
      and m.owner_account_id = v_owner_account_id
  ) then
    raise exception 'permission denied';
  end if;

  return query
  with email_rows as (
    select
      'email'::text as source_kind,
      i.id as invitation_id,
      mc.id as collaboration_id,
      coalesce(
        nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''),
        recipient.display_name,
        public.normalize_contact_email(i.recipient_email)
      ) as display_name,
      public.normalize_contact_email(i.recipient_email) as recipient_email,
      case
        when i.status = 'pending' and i.expires_at <= now() then 'expired'
        when i.status = 'accepted'
          and mc.status = 'revoked'
          and mc.revoked_by_account_id = mc.recipient_account_id then 'abandoned'
        when i.status = 'accepted' and mc.status = 'revoked' then 'revoked'
        when i.status = 'accepted' and mc.status = 'accepted' then 'accepted'
        when i.status = 'accepted' then 'unavailable'
        else i.status
      end as share_status,
      i.status as invitation_status,
      mc.status as collaboration_status,
      case
        when i.status = 'pending' and i.expires_at > now() then 'resend_email'
        when i.status = 'accepted' and mc.status = 'accepted' then 'revoke_email_access'
        when i.status = 'accepted'
          and mc.status = 'revoked'
          and mc.revoked_by_account_id = mc.recipient_account_id then 'archive_abandoned_invitation'
        else null
      end as action_kind,
      case
        when i.status = 'accepted' and mc.status = 'accepted' then 0
        when i.status = 'pending' and i.expires_at > now() then 1
        when i.status = 'accepted'
          and mc.status = 'revoked'
          and mc.revoked_by_account_id = mc.recipient_account_id then 2
        else 3
      end as state_rank,
      i.created_at
    from public.memory_share_invitations i
    join public.contacts c
      on c.id = i.recipient_contact_id
     and c.owner_account_id = i.owner_account_id
    left join public.memory_collaborations mc
      on mc.id = i.accepted_collaboration_id
     and mc.memory_id = i.memory_id
     and mc.owner_account_id = i.owner_account_id
    left join lateral public.contact_share_sender_identity(mc.recipient_account_id) recipient
      on mc.id is not null
    where i.memory_id = p_memory_id
      and i.owner_account_id = v_owner_account_id
      and i.owner_archived_at is null
  ),
  collaboration_rows as (
    select
      'collaboration'::text as source_kind,
      null::uuid as invitation_id,
      mc.id as collaboration_id,
      coalesce(
        contact.display_name,
        recipient.display_name,
        public.normalize_contact_email(recipient_user.email)
      ) as display_name,
      public.normalize_contact_email(recipient_user.email) as recipient_email,
      mc.status as share_status,
      null::text as invitation_status,
      mc.status as collaboration_status,
      case mc.status
        when 'pending' then 'cancel_collaboration_invitation'
        when 'accepted' then 'revoke_collaboration_access'
        else null
      end as action_kind,
      case mc.status
        when 'accepted' then 0
        when 'pending' then 1
        else 3
      end as state_rank,
      mc.created_at
    from public.memory_collaborations mc
    join public.accounts recipient_account
      on recipient_account.id = mc.recipient_account_id
    left join auth.users recipient_user
      on recipient_user.id = recipient_account.auth_user_id
    left join lateral (
      select nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), '') as display_name
      from public.contacts c
      left join public.contact_account_links cal
        on cal.contact_id = c.id
       and cal.owner_account_id = mc.owner_account_id
      left join public.contact_profile_links cpl
        on cpl.contact_id = c.id
       and cpl.owner_account_id = mc.owner_account_id
      left join public.profiles linked_profile
        on linked_profile.id = cpl.profile_id
      where c.owner_account_id = mc.owner_account_id
        and (
          cal.linked_account_id = mc.recipient_account_id
          or linked_profile.account_id = mc.recipient_account_id
        )
      order by c.id
      limit 1
    ) contact on true
    left join lateral public.contact_share_sender_identity(mc.recipient_account_id) recipient
      on true
    where mc.memory_id = p_memory_id
      and mc.owner_account_id = v_owner_account_id
      and not exists (
        -- A collaboration created by an email invitation is represented by
        -- that invitation row. Independent authorizations remain visible.
        select 1
        from public.memory_share_invitations i
        where i.accepted_collaboration_id = mc.id
      )
  ),
  candidates as (
    select * from email_rows
    union all
    select * from collaboration_rows
  )
  select jsonb_build_object(
    'source_kind', source_kind,
    'invitation_id', invitation_id,
    'collaboration_id', collaboration_id,
    'display_name', display_name,
    'recipient_email', recipient_email,
    'status', share_status,
    'invitation_status', invitation_status,
    'collaboration_status', collaboration_status,
    'action_kind', action_kind,
    'created_at', created_at
  )
  from candidates
  order by state_rank, created_at desc, coalesce(invitation_id, collaboration_id);
end;
$$;

create or replace function public.archive_abandoned_memory_share_invitation(
  p_invitation_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_invitation public.memory_share_invitations%rowtype;
  v_collaboration_status text;
  v_recipient_account_id uuid;
  v_revoked_by_account_id uuid;
begin
  if p_invitation_id is null then
    raise exception 'memory share invitation unavailable';
  end if;

  select * into v_invitation
  from public.memory_share_invitations i
  where i.id = p_invitation_id
    and i.owner_account_id = v_owner_account_id
  for update;

  if not found then
    raise exception 'memory share invitation unavailable';
  end if;

  if v_invitation.owner_archived_at is not null then
    return false;
  end if;

  select mc.status, mc.recipient_account_id, mc.revoked_by_account_id
  into v_collaboration_status, v_recipient_account_id, v_revoked_by_account_id
  from public.memory_collaborations mc
  where mc.id = v_invitation.accepted_collaboration_id
    and mc.memory_id = v_invitation.memory_id
    and mc.owner_account_id = v_owner_account_id
  for key share;

  if v_invitation.status <> 'accepted'
    or v_collaboration_status <> 'revoked'
    or v_revoked_by_account_id is distinct from v_recipient_account_id then
    raise exception 'memory share invitation is not abandoned';
  end if;

  update public.memory_share_invitations
  set owner_archived_at = now()
  where id = v_invitation.id;

  return true;
end;
$$;

alter function public.get_memory_share_management(uuid) owner to postgres;
alter function public.archive_abandoned_memory_share_invitation(uuid) owner to postgres;
alter function public.leave_my_memory_collaboration(uuid) owner to postgres;
alter function public.revoke_memory_collaboration(uuid) owner to postgres;
alter function public.revoke_memory_share_invitation(uuid) owner to postgres;

revoke all on function public.get_memory_share_management(uuid) from public, anon, authenticated;
revoke all on function public.archive_abandoned_memory_share_invitation(uuid) from public, anon, authenticated;
revoke all on function public.leave_my_memory_collaboration(uuid) from public, anon, authenticated;
revoke all on function public.revoke_memory_collaboration(uuid) from public, anon, authenticated;
revoke all on function public.revoke_memory_share_invitation(uuid) from public, anon, authenticated;
revoke execute on function public.get_memory_share_management(uuid) from public, anon;
revoke execute on function public.archive_abandoned_memory_share_invitation(uuid) from public, anon;

grant execute on function public.get_memory_share_management(uuid) to authenticated;
grant execute on function public.archive_abandoned_memory_share_invitation(uuid) to authenticated;
grant execute on function public.leave_my_memory_collaboration(uuid) to authenticated;
grant execute on function public.revoke_memory_collaboration(uuid) to authenticated;
grant execute on function public.revoke_memory_share_invitation(uuid) to authenticated;

commit;
