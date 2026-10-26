-- FamilArea V2 — partecipanti privati degli Album.
-- I partecipanti riutilizzano la rubrica e non concedono accesso all'Album.

begin;

create table public.memory_participants (
  id uuid primary key default gen_random_uuid(),
  memory_id uuid not null references public.memories(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete restrict,
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (memory_id, contact_id)
);

create index memory_participants_memory_created_idx on public.memory_participants(memory_id, created_at, id);
create index memory_participants_contact_idx on public.memory_participants(contact_id);
create index memory_participants_owner_contact_idx on public.memory_participants(owner_account_id, contact_id);

alter table public.memory_participants enable row level security;
revoke all on table public.memory_participants from public, anon, authenticated;

create function public.assert_memory_participant_scope()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (
    select 1 from public.memories m
    where m.id = new.memory_id and m.owner_account_id = new.owner_account_id
  ) then
    raise exception 'memory participant owner does not match memory owner';
  end if;
  if not exists (
    select 1 from public.contacts c
    where c.id = new.contact_id and c.owner_account_id = new.owner_account_id
  ) then
    raise exception 'memory participant contact is outside memory owner address book';
  end if;
  return new;
end;
$$;

create trigger memory_participants_scope
before insert or update of memory_id, contact_id, owner_account_id
on public.memory_participants
for each row execute function public.assert_memory_participant_scope();

create function public.get_memory_participants(p_memory_id uuid)
returns setof jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_owner_account_id uuid := public.require_current_account();
begin
  if not exists (
    select 1 from public.memories m
    where m.id = p_memory_id and m.owner_account_id = v_owner_account_id
  ) then
    raise exception 'memory unavailable';
  end if;
  return query
  select jsonb_build_object(
    'id', mp.id,
    'contact_id', c.id,
    'first_name', c.first_name,
    'last_name', c.last_name,
    'email', (
      select cm.value from public.contact_methods cm
      where cm.contact_id = c.id and cm.method_type = 'email'
      order by cm.is_primary desc, cm.id limit 1
    ),
    'created_at', mp.created_at
  )
  from public.memory_participants mp
  join public.contacts c on c.id = mp.contact_id
  where mp.memory_id = p_memory_id and mp.owner_account_id = v_owner_account_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), mp.created_at, mp.id;
end;
$$;

create function public.add_memory_participant(p_memory_id uuid, p_contact_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_participant public.memory_participants%rowtype;
begin
  perform 1 from public.memories m
  where m.id = p_memory_id and m.owner_account_id = v_owner_account_id for update;
  if not found then raise exception 'memory unavailable'; end if;
  perform 1 from public.contacts c
  where c.id = p_contact_id and c.owner_account_id = v_owner_account_id for update;
  if not found then raise exception 'contact unavailable'; end if;
  insert into public.memory_participants(memory_id, contact_id, owner_account_id)
  values (p_memory_id, p_contact_id, v_owner_account_id)
  returning * into v_participant;
  return to_jsonb(v_participant);
exception when unique_violation then
  raise exception using errcode = 'P0001', message = 'memory_participant_already_exists';
end;
$$;

create function public.remove_memory_participant(p_memory_id uuid, p_contact_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_account_id uuid := public.require_current_account();
begin
  perform 1 from public.memories m
  where m.id = p_memory_id and m.owner_account_id = v_owner_account_id for update;
  if not found then raise exception 'memory unavailable'; end if;
  delete from public.memory_participants mp
  where mp.memory_id = p_memory_id
    and mp.contact_id = p_contact_id
    and mp.owner_account_id = v_owner_account_id;
  if not found then raise exception 'memory participant unavailable'; end if;
end;
$$;

-- Contacts already used by an Album cannot be deleted, including outside the UI.
create or replace function public.delete_contact(p_contact_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_account_id uuid;
begin
  v_owner_account_id := public.require_current_account();
  perform 1 from public.contacts c
  where c.id = p_contact_id and c.owner_account_id = v_owner_account_id for update;
  if not found then raise exception 'contact not found or unavailable'; end if;
  if exists (select 1 from public.memory_participants mp where mp.contact_id = p_contact_id) then
    raise exception using errcode = 'P0001', message = 'contact_is_memory_participant';
  end if;
  delete from public.contacts
  where id = p_contact_id and owner_account_id = v_owner_account_id;
end;
$$;

alter table public.memory_participants owner to postgres;
alter function public.assert_memory_participant_scope() owner to postgres;
alter function public.get_memory_participants(uuid) owner to postgres;
alter function public.add_memory_participant(uuid, uuid) owner to postgres;
alter function public.remove_memory_participant(uuid, uuid) owner to postgres;
alter function public.delete_contact(uuid) owner to postgres;

revoke all on function public.delete_contact(uuid) from public, anon;
grant execute on function public.delete_contact(uuid) to authenticated;

revoke all on function public.assert_memory_participant_scope() from public, anon, authenticated;
revoke all on function public.get_memory_participants(uuid) from public, anon;
revoke all on function public.add_memory_participant(uuid, uuid) from public, anon;
revoke all on function public.remove_memory_participant(uuid, uuid) from public, anon;
grant execute on function public.get_memory_participants(uuid) to authenticated;
grant execute on function public.add_memory_participant(uuid, uuid) to authenticated;
grant execute on function public.remove_memory_participant(uuid, uuid) to authenticated;

commit;
