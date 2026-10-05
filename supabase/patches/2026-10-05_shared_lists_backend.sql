-- FamilArea — direct shared lists (backend phase 1).
-- This patch intentionally leaves the legacy Area branch of public.lists intact.
-- New sharing applies only to personal lists (owner_account_id set, area_id null).

begin;

create table if not exists public.list_participants (
  list_id uuid not null references public.lists(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  invited_by_account_id uuid not null references public.accounts(id) on delete restrict,
  accepted_at timestamptz not null default now(),
  primary key (list_id, account_id)
);

create index if not exists list_participants_account_idx
  on public.list_participants(account_id, list_id);

create table if not exists public.list_invites (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists(id) on delete cascade,
  invited_by_account_id uuid not null references public.accounts(id) on delete restrict,
  recipient_account_id uuid not null references public.accounts(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'revoked')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);

create unique index if not exists list_invites_one_pending_recipient_idx
  on public.list_invites(list_id, recipient_account_id)
  where status = 'pending';

create index if not exists list_invites_recipient_pending_idx
  on public.list_invites(recipient_account_id, created_at desc)
  where status = 'pending';

alter table public.list_items
  add column if not exists assignee_account_id uuid references public.accounts(id) on delete set null,
  add column if not exists created_by_account_id uuid references public.accounts(id) on delete set null,
  add column if not exists completed_by_account_id uuid references public.accounts(id) on delete set null,
  add column if not exists completed_at timestamptz;

-- Existing items retain an audit author whenever their existing list has one.
update public.list_items i
set created_by_account_id = coalesce(l.owner_account_id, l.created_by_account_id)
from public.lists l
where l.id = i.list_id
  and i.created_by_account_id is null
  and coalesce(l.owner_account_id, l.created_by_account_id) is not null;

create index if not exists list_items_assignee_idx
  on public.list_items(list_id, assignee_account_id)
  where assignee_account_id is not null;

alter table public.list_participants enable row level security;
alter table public.list_invites enable row level security;
revoke all on table public.list_participants, public.list_invites from anon, authenticated;

-- Internal authorization helpers. They are deliberately not a client API.
create or replace function public.can_read_list(p_list_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp
as $$
  select exists(
    select 1
    from public.lists l
    where l.id = p_list_id
      and (
        l.owner_account_id = public.current_account_id()
        or exists (
          select 1 from public.list_participants lp
          where lp.list_id = l.id and lp.account_id = public.current_account_id()
        )
        or (
          l.area_id is not null
          and (public.is_area_owner(l.area_id) or public.is_area_member(l.area_id))
        )
      )
  )
$$;

create or replace function public.can_edit_list_items(p_list_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp
as $$
  select exists(
    select 1
    from public.lists l
    where l.id = p_list_id
      and (
        l.owner_account_id = public.current_account_id()
        or exists (
          select 1 from public.list_participants lp
          where lp.list_id = l.id and lp.account_id = public.current_account_id()
        )
        or (l.area_id is not null and public.can_manage_area(l.area_id))
      )
  )
$$;

create or replace function public.can_manage_list(p_list_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp
as $$
  select exists(
    select 1 from public.lists l
    where l.id = p_list_id
      and (
        l.owner_account_id = public.current_account_id()
        or (l.area_id is not null and public.can_manage_area(l.area_id))
      )
  )
$$;

-- List metadata remains owner-only for personal lists; the Area branch is unchanged.
create or replace function public.update_list(
  p_list_id uuid,
  p_title text,
  p_description text default null
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v public.lists%rowtype;
begin
  if not public.can_manage_list(p_list_id) then raise exception 'permission denied'; end if;
  update public.lists
  set title = nullif(btrim(p_title), ''),
      description = nullif(btrim(p_description), '')
  where id = p_list_id
  returning * into v;
  if not found then raise exception 'list not found'; end if;
  return to_jsonb(v);
end
$$;

create or replace function public.delete_list(p_list_id uuid)
returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if not public.can_manage_list(p_list_id) then raise exception 'permission denied'; end if;
  delete from public.lists where id = p_list_id;
  if not found then raise exception 'list not found'; end if;
end
$$;

create or replace function public.get_visible_lists()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp
as $$
  select to_jsonb(l) || jsonb_build_object(
    'can_edit_items', public.can_edit_list_items(l.id),
    'can_manage_list', public.can_manage_list(l.id)
  )
  from public.lists l
  where public.can_read_list(l.id)
  order by l.updated_at desc
$$;

create or replace function public.get_list(p_list_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if not public.can_read_list(p_list_id) then raise exception 'permission denied'; end if;
  return (
    select jsonb_build_object(
      'list', to_jsonb(l),
      'owner', case when l.owner_account_id is null then null else jsonb_build_object(
        'account_id', l.owner_account_id,
        'profile_id', owner_profile.id,
        'first_name', owner_profile.first_name,
        'last_name', owner_profile.last_name
      ) end,
      'participants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'account_id', lp.account_id,
          'invited_by_account_id', lp.invited_by_account_id,
          'accepted_at', lp.accepted_at,
          'profile_id', participant_profile.id,
          'first_name', participant_profile.first_name,
          'last_name', participant_profile.last_name
        ) order by lp.accepted_at, lp.account_id)
        from public.list_participants lp
        left join public.profiles participant_profile on participant_profile.account_id = lp.account_id
        where lp.list_id = l.id
      ), '[]'::jsonb),
      'items', coalesce((
        select jsonb_agg(to_jsonb(i) order by i.position, i.created_at, i.id)
        from public.list_items i
        where i.list_id = l.id
      ), '[]'::jsonb),
      'can_edit_items', public.can_edit_list_items(l.id),
      'can_manage_list', public.can_manage_list(l.id)
    )
    from public.lists l
    left join public.profiles owner_profile on owner_profile.account_id = l.owner_account_id
    where l.id = p_list_id
  );
end
$$;

create or replace function public.create_list_item(
  p_list_id uuid,
  p_text text,
  p_position integer default 0
)
returns uuid
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_id uuid;
begin
  if not public.can_edit_list_items(p_list_id) then raise exception 'permission denied'; end if;
  if nullif(btrim(p_text), '') is null or coalesce(p_position, 0) < 0 then
    raise exception 'invalid list item';
  end if;
  insert into public.list_items(list_id, text, position, created_by_account_id)
  values(p_list_id, btrim(p_text), coalesce(p_position, 0), public.require_current_account())
  returning id into v_id;
  return v_id;
end
$$;

create or replace function public.update_list_item(
  p_item_id uuid,
  p_text text,
  p_position integer,
  p_status text default 'open'
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_item public.list_items%rowtype;
  v_actor uuid := public.require_current_account();
begin
  select * into v_item from public.list_items where id = p_item_id for update;
  if not found then raise exception 'list item not found'; end if;
  if not public.can_edit_list_items(v_item.list_id) then raise exception 'permission denied'; end if;
  if nullif(btrim(p_text), '') is null or p_position is null or p_position < 0
     or p_status not in ('open', 'completed') then
    raise exception 'invalid list item';
  end if;
  update public.list_items
  set text = btrim(p_text),
      position = p_position,
      status = p_status,
      completed_at = case
        when p_status = 'completed' and v_item.status <> 'completed' then now()
        when p_status = 'completed' then v_item.completed_at
        else null
      end,
      completed_by_account_id = case
        when p_status = 'completed' and v_item.status <> 'completed' then v_actor
        when p_status = 'completed' then v_item.completed_by_account_id
        else null
      end
  where id = v_item.id
  returning * into v_item;
  return to_jsonb(v_item);
end
$$;

create or replace function public.delete_list_item(p_item_id uuid)
returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_list_id uuid;
begin
  select list_id into v_list_id from public.list_items where id = p_item_id for update;
  if not found then raise exception 'list item not found'; end if;
  if not public.can_edit_list_items(v_list_id) then raise exception 'permission denied'; end if;
  delete from public.list_items where id = p_item_id;
end
$$;

create or replace function public.create_list_invite(
  p_list_id uuid,
  p_recipient_account_id uuid
)
returns uuid
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_owner uuid := public.require_current_account();
  v_invite_id uuid;
begin
  perform 1 from public.lists l
  where l.id = p_list_id and l.owner_account_id = v_owner and l.area_id is null
  for update;
  if not found then raise exception 'permission denied'; end if;
  if p_recipient_account_id = v_owner then raise exception 'cannot invite list owner'; end if;
  if not exists(select 1 from public.accounts a where a.id = p_recipient_account_id) then
    raise exception 'recipient account not found';
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

create or replace function public.get_my_list_invites()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp
as $$
  select jsonb_build_object(
    'invite_id', li.id,
    'list_id', li.list_id,
    'list_title', l.title,
    'invited_by_account_id', li.invited_by_account_id,
    'inviter_profile_id', inviter_profile.id,
    'inviter_first_name', inviter_profile.first_name,
    'inviter_last_name', inviter_profile.last_name,
    'status', li.status,
    'created_at', li.created_at,
    'responded_at', li.responded_at
  )
  from public.list_invites li
  join public.lists l on l.id = li.list_id
  left join public.profiles inviter_profile on inviter_profile.account_id = li.invited_by_account_id
  where li.recipient_account_id = public.require_current_account()
    and li.status = 'pending'
    and l.owner_account_id is not null
    and l.area_id is null
  order by li.created_at desc, li.id
$$;

create or replace function public.accept_my_list_invite(p_invite_id uuid)
returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_actor uuid := public.require_current_account();
  v_invite public.list_invites%rowtype;
begin
  select * into v_invite from public.list_invites where id = p_invite_id for update;
  if not found or v_invite.status <> 'pending' or v_invite.recipient_account_id <> v_actor then
    raise exception 'invalid list invite';
  end if;
  perform 1 from public.lists l
  where l.id = v_invite.list_id and l.owner_account_id is not null and l.area_id is null
  for update;
  if not found then raise exception 'list unavailable'; end if;
  insert into public.list_participants(list_id, account_id, invited_by_account_id, accepted_at)
  values(v_invite.list_id, v_actor, v_invite.invited_by_account_id, now())
  on conflict (list_id, account_id) do nothing;
  update public.list_invites
  set status = 'accepted', responded_at = now()
  where id = v_invite.id;
end
$$;

create or replace function public.decline_my_list_invite(p_invite_id uuid)
returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_actor uuid := public.require_current_account();
begin
  update public.list_invites
  set status = 'declined', responded_at = now()
  where id = p_invite_id
    and recipient_account_id = v_actor
    and status = 'pending';
  if not found then raise exception 'invalid list invite'; end if;
end
$$;

create or replace function public.revoke_list_invite(p_invite_id uuid)
returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_owner uuid := public.require_current_account();
begin
  update public.list_invites li
  set status = 'revoked', responded_at = now()
  from public.lists l
  where li.id = p_invite_id
    and li.list_id = l.id
    and l.owner_account_id = v_owner
    and l.area_id is null
    and li.status = 'pending';
  if not found then raise exception 'invite not found or not revocable'; end if;
end
$$;

create or replace function public.remove_list_participant(
  p_list_id uuid,
  p_account_id uuid
)
returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_owner uuid := public.require_current_account();
begin
  perform 1 from public.lists l
  where l.id = p_list_id and l.owner_account_id = v_owner and l.area_id is null
  for update;
  if not found then raise exception 'permission denied'; end if;
  update public.list_items
  set assignee_account_id = null
  where list_id = p_list_id and assignee_account_id = p_account_id;
  delete from public.list_participants
  where list_id = p_list_id and account_id = p_account_id;
  if not found then raise exception 'participant not found'; end if;
end
$$;

create or replace function public.claim_list_item(p_item_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_actor uuid := public.require_current_account();
  v_item public.list_items%rowtype;
  v_list public.lists%rowtype;
begin
  select i.* into v_item from public.list_items i where i.id = p_item_id for update;
  if not found then raise exception 'list item not found'; end if;
  select * into v_list from public.lists where id = v_item.list_id;
  if not found or v_list.area_id is not null or not public.can_edit_list_items(v_item.list_id) then
    raise exception 'permission denied';
  end if;
  update public.list_items
  set assignee_account_id = v_actor
  where id = v_item.id
  returning * into v_item;
  return to_jsonb(v_item);
end
$$;

create or replace function public.assign_list_item(
  p_item_id uuid,
  p_assignee_account_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_actor uuid := public.require_current_account();
  v_item public.list_items%rowtype;
  v_list public.lists%rowtype;
begin
  select i.* into v_item from public.list_items i where i.id = p_item_id for update;
  if not found then raise exception 'list item not found'; end if;
  select * into v_list from public.lists where id = v_item.list_id;
  if not found or v_list.area_id is not null or v_list.owner_account_id <> v_actor then
    raise exception 'permission denied';
  end if;
  if p_assignee_account_id is not null
    and p_assignee_account_id <> v_list.owner_account_id
    and not exists (
      select 1 from public.list_participants lp
      where lp.list_id = v_list.id and lp.account_id = p_assignee_account_id
    ) then
    raise exception 'invalid list item assignee';
  end if;
  update public.list_items
  set assignee_account_id = p_assignee_account_id
  where id = v_item.id
  returning * into v_item;
  return to_jsonb(v_item);
end
$$;

revoke all on function public.can_read_list(uuid), public.can_edit_list_items(uuid), public.can_manage_list(uuid) from public, anon, authenticated;
revoke all on function public.create_list_invite(uuid,uuid), public.get_my_list_invites(), public.accept_my_list_invite(uuid), public.decline_my_list_invite(uuid), public.revoke_list_invite(uuid), public.remove_list_participant(uuid,uuid), public.claim_list_item(uuid), public.assign_list_item(uuid,uuid) from public, anon;
grant execute on function public.create_list_invite(uuid,uuid), public.get_my_list_invites(), public.accept_my_list_invite(uuid), public.decline_my_list_invite(uuid), public.revoke_list_invite(uuid), public.remove_list_participant(uuid,uuid), public.claim_list_item(uuid), public.assign_list_item(uuid,uuid) to authenticated;

commit;
