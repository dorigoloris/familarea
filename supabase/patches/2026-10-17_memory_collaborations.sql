-- FamilArea V2 -- per-album, account-owned sharing for Timeline memories.
--
-- This patch deliberately reuses the established collaboration lifecycle:
-- linked Contact search, explicit invite, acceptance/decline and owner revocation.
-- It grants read-only access to one memory only; it never shares its Timeline.

begin;

create table if not exists public.memory_collaborations (
  id uuid primary key default gen_random_uuid(),
  memory_id uuid not null references public.memories(id) on delete cascade,
  owner_account_id uuid not null references public.accounts(id) on delete restrict,
  recipient_account_id uuid not null references public.accounts(id) on delete restrict,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'cancelled', 'revoked')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  declined_at timestamptz,
  cancelled_at timestamptz,
  revoked_at timestamptz,
  check (owner_account_id <> recipient_account_id)
);

create unique index if not exists memory_collaborations_one_active_recipient_idx
  on public.memory_collaborations(memory_id, recipient_account_id)
  where status in ('pending', 'accepted');

create index if not exists memory_collaborations_recipient_pending_idx
  on public.memory_collaborations(recipient_account_id, created_at desc)
  where status = 'pending';

create index if not exists memory_collaborations_owner_management_idx
  on public.memory_collaborations(owner_account_id, memory_id, created_at desc)
  where status in ('pending', 'accepted');

alter table public.memory_collaborations enable row level security;
revoke all on table public.memory_collaborations from public, anon, authenticated;

create or replace function public.assert_memory_collaboration_integrity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.memories m
    where m.id = new.memory_id
      and m.owner_account_id = new.owner_account_id
  ) then
    raise exception 'memory collaboration owner does not match memory owner';
  end if;

  if not exists (
    select 1
    from public.accounts a
    where a.id = new.owner_account_id
      and a.account_type in ('personal', 'organization')
  ) or not exists (
    select 1
    from public.accounts a
    where a.id = new.recipient_account_id
      and a.account_type in ('personal', 'organization')
  ) then
    raise exception 'memory collaboration accounts must be eligible accounts';
  end if;

  return new;
end;
$$;

drop trigger if exists memory_collaborations_integrity on public.memory_collaborations;
create trigger memory_collaborations_integrity
before insert or update of memory_id, owner_account_id, recipient_account_id
on public.memory_collaborations
for each row execute function public.assert_memory_collaboration_integrity();

-- Internal-only helper. The candidate set remains the owner's linked Contacts;
-- it does not expose the account base to arbitrary searches.
create or replace function public.is_invitable_memory_collaboration_recipient(
  p_owner_account_id uuid,
  p_recipient_account_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with linked_contact_accounts as (
    select cal.linked_account_id as account_id
    from public.contacts c
    join public.contact_account_links cal
      on cal.contact_id = c.id
     and cal.owner_account_id = p_owner_account_id
    where c.owner_account_id = p_owner_account_id

    union

    select p.account_id
    from public.contacts c
    join public.contact_profile_links cpl
      on cpl.contact_id = c.id
     and cpl.owner_account_id = p_owner_account_id
    join public.profiles p on p.id = cpl.profile_id
    where c.owner_account_id = p_owner_account_id
  )
  select exists (
    select 1
    from linked_contact_accounts linked
    join lateral public.contact_share_sender_identity(linked.account_id) identity on true
    where linked.account_id = p_recipient_account_id
      and linked.account_id <> p_owner_account_id
      and identity.account_type in ('personal', 'organization')
  );
$$;

create or replace function public.memory_collaboration_can_read(
  p_memory_id uuid,
  p_account_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.memory_collaborations mc
    where mc.memory_id = p_memory_id
      and mc.recipient_account_id = p_account_id
      and mc.status = 'accepted'
  );
$$;

-- Preserve every existing target_scope branch. The only behavioural change is
-- read access to an accepted recipient of target_type = 'memory'.
create or replace function public.target_scope(
  p_target_type text,
  p_target_id uuid
)
returns table(owner_account_id uuid, area_id uuid, can_read boolean, can_write boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
  v_area uuid;
  v_document public.personal_documents%rowtype;
  v_actor_account_id uuid := public.current_account_id();
  v_memory_shared_read boolean := false;
begin
  if p_target_type = 'activity' then
    select a.owner_account_id, a.area_id into v_owner, v_area
    from public.activities a where a.id = p_target_id;
  elsif p_target_type = 'event' then
    select e.owner_account_id, e.area_id into v_owner, v_area
    from public.events e where e.id = p_target_id;
  elsif p_target_type = 'deadline' then
    select d.owner_account_id, null into v_owner, v_area
    from public.deadlines d
    where d.id = p_target_id
      and public.is_resolved_personal_document_deadline(d.id);
  elsif p_target_type = 'personal_document' then
    select * into v_document
    from public.personal_documents pd
    where pd.id = p_target_id;
    if not found then
      raise exception 'target not found';
    end if;
    return query
    select v_document.storage_owner_account_id, null::uuid,
      public.can_access_personal_document(v_document.id, false),
      public.can_access_personal_document(v_document.id, true);
    return;
  elsif p_target_type = 'memory' then
    select m.owner_account_id, null into v_owner, v_area
    from public.memories m
    where m.id = p_target_id;

    if v_owner is not null and v_actor_account_id is not null then
      v_memory_shared_read := public.memory_collaboration_can_read(
        p_target_id,
        v_actor_account_id
      );
    end if;
  elsif p_target_type = 'timeline_document' then
    select d.owner_account_id, null into v_owner, v_area
    from public.timeline_documents d
    where d.id = p_target_id;
  else
    raise exception 'invalid target';
  end if;

  if v_owner is null and v_area is null then
    raise exception 'target not found';
  end if;

  return query
  select v_owner, v_area,
    (v_owner = v_actor_account_id
      or (p_target_type = 'memory' and v_memory_shared_read)
      or (v_area is not null and (public.is_area_owner(v_area) or public.is_area_member(v_area)))),
    (v_owner = v_actor_account_id
      or (v_area is not null and public.can_manage_area(v_area)));
end;
$$;

-- Storage paths are namespaced by the owner account. For a shared memory the
-- recipient must therefore be checked against target_scope, while the path
-- itself must still name the actual memory owner. Writes remain owner-only.
-- The function signature, SECURITY DEFINER mode, search_path and existing
-- behaviour for every non-memory target are preserved.
create or replace function public.can_access_attachment_path(
  p_path text,
  p_write boolean default false
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v text[] := string_to_array(p_path, '/');
  v_account uuid := public.current_account_id();
  v_scope record;
begin
  if array_length(v, 1) <> 5 or v[1] <> 'attachments' or nullif(v[5], '') is null then
    return false;
  end if;

  if v[3] = 'personal_document' then
    select * into v_scope from public.target_scope(v[3], v[4]::uuid);
    if v[2] <> v_scope.owner_account_id::text then
      return false;
    end if;
    return case when p_write then v_scope.can_write else v_scope.can_read end;
  end if;

  if v[3] = 'memory' then
    select * into v_scope from public.target_scope(v[3], v[4]::uuid);
    if v[2] <> v_scope.owner_account_id::text then
      return false;
    end if;
    return case when p_write then v_scope.can_write else v_scope.can_read end;
  end if;

  if v[2] <> v_account::text then
    return false;
  end if;
  select * into v_scope from public.target_scope(v[3], v[4]::uuid);
  return case when p_write then v_scope.can_write else v_scope.can_read end;
exception when others then
  return false;
end;
$$;

create or replace function public.search_invitable_memory_collaboration_accounts(
  p_memory_id uuid,
  p_query text
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_query text := lower(btrim(coalesce(p_query, '')));
begin
  perform 1
  from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = v_owner_account_id;
  if not found then
    raise exception 'permission denied';
  end if;

  if v_query = '' then
    return;
  end if;

  return query
  with linked_contact_accounts as (
    select cal.linked_account_id as account_id
    from public.contacts c
    join public.contact_account_links cal
      on cal.contact_id = c.id
     and cal.owner_account_id = v_owner_account_id
    where c.owner_account_id = v_owner_account_id

    union

    select p.account_id
    from public.contacts c
    join public.contact_profile_links cpl
      on cpl.contact_id = c.id
     and cpl.owner_account_id = v_owner_account_id
    join public.profiles p on p.id = cpl.profile_id
    where c.owner_account_id = v_owner_account_id
  )
  select jsonb_build_object(
    'account_id', identity.account_id,
    'display_name', identity.display_name,
    'avatar_path', identity.avatar_path,
    'account_type', identity.account_type
  )
  from linked_contact_accounts linked
  join lateral public.contact_share_sender_identity(linked.account_id) identity on true
  where linked.account_id <> v_owner_account_id
    and identity.account_type in ('personal', 'organization')
    and (
      lower(identity.display_name) like '%' || v_query || '%'
      or lower(identity.email) like '%' || v_query || '%'
    )
    and not exists (
      select 1
      from public.memory_collaborations mc
      where mc.memory_id = p_memory_id
        and mc.recipient_account_id = linked.account_id
        and mc.status in ('pending', 'accepted')
    )
  order by identity.display_name, identity.account_id
  limit 5;
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

create or replace function public.get_memory_collaboration_management(
  p_memory_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  if not exists (
    select 1
    from public.memories m
    where m.id = p_memory_id
      and m.owner_account_id = v_owner_account_id
  ) then
    raise exception 'permission denied';
  end if;

  return jsonb_build_object(
    'memory_id', p_memory_id,
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
        'collaboration_id', mc.id,
        'recipient_account_id', mc.recipient_account_id,
        'display_name', recipient.display_name,
        'avatar_path', recipient.avatar_path,
        'account_type', recipient.account_type,
        'created_at', mc.created_at,
        'status', mc.status
      ) order by mc.created_at, mc.id)
      from public.memory_collaborations mc
      join lateral public.contact_share_sender_identity(mc.recipient_account_id) recipient on true
      where mc.memory_id = p_memory_id
        and mc.status = 'pending'
    ), '[]'::jsonb),
    'collaborators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'collaboration_id', mc.id,
        'account_id', mc.recipient_account_id,
        'display_name', recipient.display_name,
        'avatar_path', recipient.avatar_path,
        'account_type', recipient.account_type,
        'accepted_at', mc.accepted_at,
        'status', mc.status
      ) order by mc.accepted_at, mc.id)
      from public.memory_collaborations mc
      join lateral public.contact_share_sender_identity(mc.recipient_account_id) recipient on true
      where mc.memory_id = p_memory_id
        and mc.status = 'accepted'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.cancel_memory_collaboration(
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
  set status = 'cancelled',
      cancelled_at = now()
  where mc.id = p_collaboration_id
    and mc.owner_account_id = v_owner_account_id
    and mc.status = 'pending';

  if not found then
    raise exception 'memory collaboration not found or not cancellable';
  end if;
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
      revoked_at = now()
  where mc.id = p_collaboration_id
    and mc.owner_account_id = v_owner_account_id
    and mc.status = 'accepted';

  if not found then
    raise exception 'memory collaboration not found or not revocable';
  end if;
end;
$$;

create or replace function public.get_my_memory_collaboration_invites()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'collaboration_id', mc.id,
    'memory_id', mc.memory_id,
    'title', m.title,
    'occurred_on', m.occurred_on,
    'cover_attachment_id', m.cover_attachment_id,
    'invited_by_account_id', mc.owner_account_id,
    'inviter_display_name', inviter.display_name,
    'inviter_avatar_path', inviter.avatar_path,
    'status', mc.status,
    'created_at', mc.created_at
  )
  from public.memory_collaborations mc
  join public.memories m on m.id = mc.memory_id
  join lateral public.contact_share_sender_identity(mc.owner_account_id) inviter on true
  where mc.recipient_account_id = public.require_current_account()
    and mc.status = 'pending'
  order by mc.created_at desc, mc.id;
$$;

create or replace function public.accept_my_memory_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
begin
  update public.memory_collaborations mc
  set status = 'accepted',
      accepted_at = now()
  where mc.id = p_collaboration_id
    and mc.recipient_account_id = v_recipient_account_id
    and mc.status = 'pending';

  if not found then
    raise exception 'memory collaboration invitation unavailable';
  end if;
end;
$$;

create or replace function public.decline_my_memory_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
begin
  update public.memory_collaborations mc
  set status = 'declined',
      declined_at = now()
  where mc.id = p_collaboration_id
    and mc.recipient_account_id = v_recipient_account_id
    and mc.status = 'pending';

  if not found then
    raise exception 'memory collaboration invitation unavailable';
  end if;
end;
$$;

-- Shared memories are deliberately separate from get_my_memories_for_timeline:
-- a recipient receives no visibility into the owner's Timeline or other albums.
create or replace function public.get_shared_memory(
  p_memory_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_memory jsonb;
begin
  select to_jsonb(m) || jsonb_build_object(
    'access', 'view',
    'owner_account_id', mc.owner_account_id,
    'collaboration_id', mc.id
  )
  into v_memory
  from public.memory_collaborations mc
  join public.memories m on m.id = mc.memory_id
  where mc.memory_id = p_memory_id
    and mc.recipient_account_id = v_recipient_account_id
    and mc.status = 'accepted';

  if v_memory is null then
    raise exception 'shared memory unavailable';
  end if;

  return v_memory;
end;
$$;

create or replace function public.get_my_shared_memories()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(m) || jsonb_build_object(
    'access', 'view',
    'owner_account_id', mc.owner_account_id,
    'collaboration_id', mc.id,
    'accepted_at', mc.accepted_at,
    'owner_display_name', owner_identity.display_name,
    'owner_avatar_path', owner_identity.avatar_path
  )
  from public.memory_collaborations mc
  join public.memories m on m.id = mc.memory_id
  join lateral public.contact_share_sender_identity(mc.owner_account_id) owner_identity on true
  where mc.recipient_account_id = public.require_current_account()
    and mc.status = 'accepted'
  order by m.occurred_on desc, m.created_at desc, m.id desc;
$$;

alter table public.memory_collaborations owner to postgres;
alter function public.assert_memory_collaboration_integrity() owner to postgres;
alter function public.is_invitable_memory_collaboration_recipient(uuid, uuid) owner to postgres;
alter function public.memory_collaboration_can_read(uuid, uuid) owner to postgres;
alter function public.target_scope(text, uuid) owner to postgres;
alter function public.search_invitable_memory_collaboration_accounts(uuid, text) owner to postgres;
alter function public.create_memory_collaboration(uuid, uuid) owner to postgres;
alter function public.get_memory_collaboration_management(uuid) owner to postgres;
alter function public.cancel_memory_collaboration(uuid) owner to postgres;
alter function public.revoke_memory_collaboration(uuid) owner to postgres;
alter function public.get_my_memory_collaboration_invites() owner to postgres;
alter function public.accept_my_memory_collaboration(uuid) owner to postgres;
alter function public.decline_my_memory_collaboration(uuid) owner to postgres;
alter function public.get_shared_memory(uuid) owner to postgres;
alter function public.get_my_shared_memories() owner to postgres;

revoke all on function public.assert_memory_collaboration_integrity() from public, anon, authenticated;
revoke all on function public.is_invitable_memory_collaboration_recipient(uuid, uuid) from public, anon, authenticated;
revoke all on function public.memory_collaboration_can_read(uuid, uuid) from public, anon, authenticated;
revoke all on function public.search_invitable_memory_collaboration_accounts(uuid, text), public.create_memory_collaboration(uuid, uuid), public.get_memory_collaboration_management(uuid), public.cancel_memory_collaboration(uuid), public.revoke_memory_collaboration(uuid), public.get_my_memory_collaboration_invites(), public.accept_my_memory_collaboration(uuid), public.decline_my_memory_collaboration(uuid), public.get_shared_memory(uuid), public.get_my_shared_memories() from public, anon;
grant execute on function public.search_invitable_memory_collaboration_accounts(uuid, text), public.create_memory_collaboration(uuid, uuid), public.get_memory_collaboration_management(uuid), public.cancel_memory_collaboration(uuid), public.revoke_memory_collaboration(uuid), public.get_my_memory_collaboration_invites(), public.accept_my_memory_collaboration(uuid), public.decline_my_memory_collaboration(uuid), public.get_shared_memory(uuid), public.get_my_shared_memories() to authenticated;

commit;
