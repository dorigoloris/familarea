-- FamilArea — deadline collaboration V1.
-- A collaboration is explicit, per-deadline and view-only. It never grants
-- access to the owner's other data, attachments, notes, documents or calendar.

begin;

create table public.deadline_collaborations (
  id uuid primary key default gen_random_uuid(),
  deadline_id uuid not null references public.deadlines(id) on delete cascade,
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

create unique index deadline_collaborations_one_active_recipient_idx
  on public.deadline_collaborations(deadline_id, recipient_account_id)
  where status in ('pending', 'accepted');

create index deadline_collaborations_recipient_pending_idx
  on public.deadline_collaborations(recipient_account_id, created_at desc)
  where status = 'pending';

create index deadline_collaborations_owner_management_idx
  on public.deadline_collaborations(owner_account_id, deadline_id, created_at desc)
  where status in ('pending', 'accepted');

alter table public.deadline_collaborations enable row level security;
revoke all on table public.deadline_collaborations from public, anon, authenticated;

-- Even though client roles have no table access, preserve the invariant at the
-- table boundary: collaboration owner always equals the deadline owner and
-- both endpoints must be personal accounts.
create or replace function public.assert_deadline_collaboration_integrity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.deadlines d
    where d.id = new.deadline_id
      and d.owner_account_id = new.owner_account_id
  ) then
    raise exception 'deadline collaboration owner does not match deadline owner';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.id = new.owner_account_id and a.account_type = 'personal'
  ) or not exists (
    select 1 from public.accounts a
    where a.id = new.recipient_account_id and a.account_type = 'personal'
  ) then
    raise exception 'deadline collaboration accounts must be personal';
  end if;

  return new;
end;
$$;

drop trigger if exists deadline_collaborations_integrity on public.deadline_collaborations;
create trigger deadline_collaborations_integrity
before insert or update of deadline_id, owner_account_id, recipient_account_id
on public.deadline_collaborations
for each row execute function public.assert_deadline_collaboration_integrity();

-- Internal-only, explicit whitelist. Do not add deadline notes, attachments,
-- item data, family-member data or any other source-domain fields here.
create or replace function public.deadline_collaboration_view_projection(
  p_deadline_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'deadline_id', d.id,
    'title', d.title,
    'category', d.category,
    'first_due_on', d.first_due_on,
    'recurrence_months', d.recurrence_months,
    'start_time', d.start_time,
    'end_time', d.end_time,
    'status', d.status
  )
  from public.deadlines d
  where d.id = p_deadline_id
$$;

create or replace function public.search_invitable_deadline_accounts(
  p_deadline_id uuid,
  p_query text
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_query text := lower(btrim(coalesce(p_query, '')));
begin
  perform 1
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id;
  if not found then raise exception 'permission denied'; end if;

  -- Candidates are only the owner's own linked Contacts, never all accounts.
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
   and cpl.owner_account_id = v_owner_account_id
  join public.profiles p on p.id = cpl.profile_id
  join public.accounts a on a.id = p.account_id
  where c.owner_account_id = v_owner_account_id
    and a.account_type = 'personal'
    and a.id <> v_owner_account_id
    and (
      c.first_name ilike v_query || '%'
      or coalesce(c.last_name, '') ilike v_query || '%'
    )
    and not exists (
      select 1
      from public.deadline_collaborations dc
      where dc.deadline_id = p_deadline_id
        and dc.recipient_account_id = a.id
        and dc.status in ('pending', 'accepted')
    )
  order by c.first_name, c.last_name nulls first, c.id
  limit 5;
end;
$$;

create or replace function public.create_deadline_collaboration(
  p_deadline_id uuid,
  p_recipient_account_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_collaboration_id uuid;
begin
  perform 1
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
  for update;
  if not found then raise exception 'permission denied'; end if;

  if p_recipient_account_id = v_owner_account_id then
    raise exception 'cannot invite deadline owner';
  end if;

  -- Discovery is convenience; this second server-side check is authorization.
  if not exists (
    select 1
    from public.contacts c
    join public.contact_profile_links cpl
      on cpl.contact_id = c.id
     and cpl.owner_account_id = v_owner_account_id
    join public.profiles p on p.id = cpl.profile_id
    join public.accounts a on a.id = p.account_id
    where c.owner_account_id = v_owner_account_id
      and a.id = p_recipient_account_id
      and a.account_type = 'personal'
  ) then
    raise exception 'recipient is not an invitable linked contact';
  end if;

  if exists (
    select 1
    from public.deadline_collaborations dc
    where dc.deadline_id = p_deadline_id
      and dc.recipient_account_id = p_recipient_account_id
      and dc.status in ('pending', 'accepted')
  ) then
    raise exception 'active deadline collaboration already exists';
  end if;

  insert into public.deadline_collaborations(
    deadline_id, owner_account_id, recipient_account_id
  ) values (
    p_deadline_id, v_owner_account_id, p_recipient_account_id
  ) returning id into v_collaboration_id;

  return v_collaboration_id;
end;
$$;

create or replace function public.get_deadline_collaboration_management(
  p_deadline_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
begin
  if not exists (
    select 1 from public.deadlines d
    where d.id = p_deadline_id and d.owner_account_id = v_owner_account_id
  ) then
    raise exception 'permission denied';
  end if;

  return jsonb_build_object(
    'deadline_id', p_deadline_id,
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
        'collaboration_id', dc.id,
        'recipient_account_id', dc.recipient_account_id,
        'display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
        'avatar_path', p.avatar_path,
        'created_at', dc.created_at,
        'status', dc.status
      ) order by dc.created_at, dc.id)
      from public.deadline_collaborations dc
      join public.profiles p on p.account_id = dc.recipient_account_id
      where dc.deadline_id = p_deadline_id and dc.status = 'pending'
    ), '[]'::jsonb),
    'collaborators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'collaboration_id', dc.id,
        'account_id', dc.recipient_account_id,
        'display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
        'avatar_path', p.avatar_path,
        'accepted_at', dc.accepted_at,
        'status', dc.status
      ) order by dc.accepted_at, dc.id)
      from public.deadline_collaborations dc
      join public.profiles p on p.account_id = dc.recipient_account_id
      where dc.deadline_id = p_deadline_id and dc.status = 'accepted'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.cancel_deadline_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
begin
  update public.deadline_collaborations dc
  set status = 'cancelled', cancelled_at = now()
  where dc.id = p_collaboration_id
    and dc.owner_account_id = v_owner_account_id
    and dc.status = 'pending';
  if not found then raise exception 'collaboration not found or not cancellable'; end if;
end;
$$;

create or replace function public.revoke_deadline_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
begin
  update public.deadline_collaborations dc
  set status = 'revoked', revoked_at = now()
  where dc.id = p_collaboration_id
    and dc.status = 'accepted'
    and v_actor_account_id in (dc.owner_account_id, dc.recipient_account_id);
  if not found then raise exception 'collaboration not found or not revocable'; end if;
end;
$$;

create or replace function public.get_my_deadline_collaboration_invites()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'collaboration_id', dc.id,
    'deadline_id', dc.deadline_id,
    'title', d.title,
    'category', d.category,
    'first_due_on', d.first_due_on,
    'invited_by_account_id', dc.owner_account_id,
    'inviter_display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
    'inviter_avatar_path', p.avatar_path,
    'status', dc.status,
    'created_at', dc.created_at
  )
  from public.deadline_collaborations dc
  join public.deadlines d on d.id = dc.deadline_id
  join public.profiles p on p.account_id = dc.owner_account_id
  where dc.recipient_account_id = public.require_personal_account()
    and dc.status = 'pending'
  order by dc.created_at desc, dc.id
$$;

create or replace function public.accept_my_deadline_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
begin
  update public.deadline_collaborations dc
  set status = 'accepted', accepted_at = now()
  where dc.id = p_collaboration_id
    and dc.recipient_account_id = v_actor_account_id
    and dc.status = 'pending';
  if not found then raise exception 'collaboration invitation unavailable'; end if;
end;
$$;

create or replace function public.decline_my_deadline_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
begin
  update public.deadline_collaborations dc
  set status = 'declined', declined_at = now()
  where dc.id = p_collaboration_id
    and dc.recipient_account_id = v_actor_account_id
    and dc.status = 'pending';
  if not found then raise exception 'collaboration invitation unavailable'; end if;
end;
$$;

create or replace function public.get_shared_deadline(
  p_deadline_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
  v_result jsonb;
begin
  select public.deadline_collaboration_view_projection(dc.deadline_id)
    || jsonb_build_object(
      'collaboration_id', dc.id,
      'owner_display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
      'owner_avatar_path', p.avatar_path,
      'access', 'view'
    )
  into v_result
  from public.deadline_collaborations dc
  join public.profiles p on p.account_id = dc.owner_account_id
  where dc.deadline_id = p_deadline_id
    and dc.recipient_account_id = v_actor_account_id
    and dc.status = 'accepted';

  if v_result is null then raise exception 'shared deadline unavailable'; end if;
  return v_result;
end;
$$;

create or replace function public.get_my_shared_deadlines()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.deadline_collaboration_view_projection(dc.deadline_id)
    || jsonb_build_object(
      'collaboration_id', dc.id,
      'owner_account_id', dc.owner_account_id,
      'owner_display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
      'owner_avatar_path', p.avatar_path,
      'access', 'view',
      'accepted_at', dc.accepted_at
    )
  from public.deadline_collaborations dc
  join public.profiles p on p.account_id = dc.owner_account_id
  where dc.recipient_account_id = public.require_personal_account()
    and dc.status = 'accepted'
  order by dc.accepted_at desc, dc.id
$$;

alter function public.assert_deadline_collaboration_integrity() owner to postgres;
alter function public.deadline_collaboration_view_projection(uuid) owner to postgres;
alter function public.search_invitable_deadline_accounts(uuid, text) owner to postgres;
alter function public.create_deadline_collaboration(uuid, uuid) owner to postgres;
alter function public.get_deadline_collaboration_management(uuid) owner to postgres;
alter function public.cancel_deadline_collaboration(uuid) owner to postgres;
alter function public.revoke_deadline_collaboration(uuid) owner to postgres;
alter function public.get_my_deadline_collaboration_invites() owner to postgres;
alter function public.accept_my_deadline_collaboration(uuid) owner to postgres;
alter function public.decline_my_deadline_collaboration(uuid) owner to postgres;
alter function public.get_shared_deadline(uuid) owner to postgres;
alter function public.get_my_shared_deadlines() owner to postgres;

revoke all on function public.assert_deadline_collaboration_integrity() from public, anon, authenticated;
revoke all on function public.deadline_collaboration_view_projection(uuid) from public, anon, authenticated;
revoke all on function public.search_invitable_deadline_accounts(uuid,text), public.create_deadline_collaboration(uuid,uuid), public.get_deadline_collaboration_management(uuid), public.cancel_deadline_collaboration(uuid), public.revoke_deadline_collaboration(uuid), public.get_my_deadline_collaboration_invites(), public.accept_my_deadline_collaboration(uuid), public.decline_my_deadline_collaboration(uuid), public.get_shared_deadline(uuid), public.get_my_shared_deadlines() from public, anon;
grant execute on function public.search_invitable_deadline_accounts(uuid,text), public.create_deadline_collaboration(uuid,uuid), public.get_deadline_collaboration_management(uuid), public.cancel_deadline_collaboration(uuid), public.revoke_deadline_collaboration(uuid), public.get_my_deadline_collaboration_invites(), public.accept_my_deadline_collaboration(uuid), public.decline_my_deadline_collaboration(uuid), public.get_shared_deadline(uuid), public.get_my_shared_deadlines() to authenticated;

commit;
