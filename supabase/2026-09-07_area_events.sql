-- FamilArea — eventi/appuntamenti separati dalle area_activities.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create table public.area_events (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(id) on delete cascade,
  title text not null check (char_length(btrim(title)) > 0),
  notes text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  is_all_day boolean not null default false,
  location text,
  status text not null default 'active' check (status in ('active', 'cancelled')),
  visibility text not null default 'area'
    check (visibility in ('area', 'private', 'creator_participants')),
  created_by_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint area_events_dates_check check (ends_at is null or ends_at >= starts_at),
  unique (id, area_id)
);

create table public.event_participants (
  event_id uuid not null,
  area_id uuid not null,
  profile_id uuid not null,
  participation_status text not null default 'pending'
    check (participation_status in ('pending', 'accepted', 'declined')),
  added_at timestamptz not null default now(),
  added_by_profile_id uuid references public.profiles(id) on delete set null,
  primary key (event_id, profile_id),
  foreign key (event_id, area_id)
    references public.area_events(id, area_id) on delete cascade,
  foreign key (area_id, profile_id)
    references public.area_memberships(area_id, profile_id) on delete cascade
);

create index area_events_area_starts_idx
  on public.area_events(area_id, starts_at, created_at desc);
create index event_participants_profile_idx
  on public.event_participants(area_id, profile_id, event_id);

alter table public.area_events enable row level security;
alter table public.event_participants enable row level security;
alter table public.area_events no force row level security;
alter table public.event_participants no force row level security;

create function public.set_area_event_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger area_events_set_updated_at
  before update on public.area_events
  for each row execute function public.set_area_event_updated_at();

-- Questo controllo differibile consente alle RPC di sostituire partecipanti e
-- visibilità nella stessa transazione, ma impedisce qualsiasi stato finale
-- private con partecipanti o creator_participants senza partecipanti.
create function public.assert_area_event_participant_visibility()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_id uuid;
  v_visibility text;
  v_participant_count integer;
begin
  if tg_table_name = 'area_events' then
    if tg_op = 'DELETE' then v_event_id := old.id; else v_event_id := new.id; end if;
  else
    if tg_op = 'DELETE' then v_event_id := old.event_id; else v_event_id := new.event_id; end if;
  end if;

  select e.visibility into v_visibility
  from public.area_events e
  where e.id = v_event_id;

  -- L'evento potrebbe essere stato eliminato nella stessa transazione.
  if not found then
    return null;
  end if;

  select count(*) into v_participant_count
  from public.event_participants ep
  where ep.event_id = v_event_id;

  if (v_visibility = 'private' and v_participant_count <> 0)
     or (v_visibility = 'creator_participants' and v_participant_count = 0) then
    raise exception 'Visibilita e partecipanti dell''evento non coerenti';
  end if;

  return null;
end;
$$;

create constraint trigger area_events_visibility_participants_check
  after insert or update of visibility on public.area_events
  deferrable initially deferred
  for each row execute function public.assert_area_event_participant_visibility();

create constraint trigger event_participants_visibility_check
  after insert or delete or update of event_id on public.event_participants
  deferrable initially deferred
  for each row execute function public.assert_area_event_participant_visibility();

create function public.current_area_event_role(p_area_id uuid)
returns table(profile_id uuid, role text)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select am.profile_id, am.role
  from public.area_memberships am
  join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id
    and p.user_id = auth.uid()
    and am.role in ('admin', 'member');
$$;

create function public.get_area_events(
  p_area_id uuid,
  p_status text default null,
  p_starts_from timestamptz default null,
  p_starts_to timestamptz default null
)
returns table(
  id uuid, title text, notes text, starts_at timestamptz, ends_at timestamptz,
  is_all_day boolean, location text, status text, visibility text,
  created_by_profile_id uuid, created_at timestamptz, updated_at timestamptz,
  my_participation_status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  if p_status is not null and p_status not in ('active', 'cancelled') then
    raise exception 'Stato evento non valido';
  end if;

  return query
  select e.id, e.title, e.notes, e.starts_at, e.ends_at, e.is_all_day,
         e.location, e.status, e.visibility, e.created_by_profile_id,
         e.created_at, e.updated_at, ep.participation_status
  from public.area_events e
  left join public.event_participants ep
    on ep.event_id = e.id and ep.profile_id = v_profile_id
  where e.area_id = p_area_id
    and (p_status is null or e.status = p_status)
    and (p_starts_from is null or e.starts_at >= p_starts_from)
    and (p_starts_to is null or e.starts_at <= p_starts_to)
    and (
      e.visibility = 'area'
      or e.created_by_profile_id = v_profile_id
      or (e.visibility = 'creator_participants' and ep.profile_id is not null)
    )
  order by e.starts_at, e.created_at, e.id;
end;
$$;

create function public.get_area_event(p_area_id uuid, p_event_id uuid)
returns table(
  id uuid, title text, notes text, starts_at timestamptz, ends_at timestamptz,
  is_all_day boolean, location text, status text, visibility text,
  created_by_profile_id uuid, created_at timestamptz, updated_at timestamptz,
  my_participation_status text, participant_profile_ids uuid[],
  participant_statuses text[]
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;

  return query
  select e.id, e.title, e.notes, e.starts_at, e.ends_at, e.is_all_day,
         e.location, e.status, e.visibility, e.created_by_profile_id,
         e.created_at, e.updated_at,
         mine.participation_status,
         case when e.created_by_profile_id = v_profile_id then
           array(select ep.profile_id from public.event_participants ep where ep.event_id = e.id order by ep.added_at, ep.profile_id)
         end,
         case when e.created_by_profile_id = v_profile_id then
           array(select ep.participation_status from public.event_participants ep where ep.event_id = e.id order by ep.added_at, ep.profile_id)
         end
  from public.area_events e
  left join public.event_participants mine
    on mine.event_id = e.id and mine.profile_id = v_profile_id
  where e.id = p_event_id and e.area_id = p_area_id
    and (e.visibility = 'area' or e.created_by_profile_id = v_profile_id
         or (e.visibility = 'creator_participants' and mine.profile_id is not null));

  if not found then raise exception 'Evento non trovato o non accessibile'; end if;
end;
$$;

create function public.create_area_event(
  p_area_id uuid, p_title text, p_notes text, p_starts_at timestamptz,
  p_ends_at timestamptz, p_is_all_day boolean, p_location text,
  p_visibility text, p_participant_profile_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_event_id uuid; v_participant_ids uuid[] := coalesce(p_participant_profile_ids, '{}');
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title, '')) = '' or p_starts_at is null
     or p_visibility not in ('area', 'private', 'creator_participants')
     or (p_ends_at is not null and p_ends_at < p_starts_at) then
    raise exception 'Dati evento non validi';
  end if;
  if exists (select 1 from unnest(v_participant_ids) as x where x is null)
     or (p_visibility = 'private' and cardinality(v_participant_ids) <> 0)
     or (p_visibility = 'creator_participants' and cardinality(v_participant_ids) = 0) then
    raise exception 'Visibilita e partecipanti dell''evento non coerenti';
  end if;
  if exists (
    select 1 from (select distinct unnest(v_participant_ids) as profile_id) ids
    left join public.area_memberships am on am.area_id = p_area_id and am.profile_id = ids.profile_id
    where am.profile_id is null
  ) then raise exception 'Partecipante non appartenente all''Area'; end if;

  insert into public.area_events(area_id, title, notes, starts_at, ends_at, is_all_day, location, visibility, created_by_profile_id)
  values(p_area_id, btrim(p_title), p_notes, p_starts_at, p_ends_at, coalesce(p_is_all_day, false), nullif(btrim(coalesce(p_location, '')), ''), p_visibility, v_profile_id)
  returning id into v_event_id;
  insert into public.event_participants(event_id, area_id, profile_id, added_by_profile_id)
  select v_event_id, p_area_id, ids.profile_id, v_profile_id
  from (select distinct unnest(v_participant_ids) as profile_id) ids;
  return v_event_id;
end;
$$;

create function public.update_area_event(
  p_area_id uuid, p_event_id uuid, p_title text, p_notes text,
  p_starts_at timestamptz, p_ends_at timestamptz, p_is_all_day boolean,
  p_location text, p_visibility text, p_participant_profile_ids uuid[] default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_creator_id uuid; v_participant_ids uuid[];
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  select created_by_profile_id into v_creator_id from public.area_events
  where id = p_event_id and area_id = p_area_id for update;
  if not found then raise exception 'Evento non trovato'; end if;
  if v_creator_id is distinct from v_profile_id then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title, '')) = '' or p_starts_at is null
     or p_visibility not in ('area', 'private', 'creator_participants')
     or (p_ends_at is not null and p_ends_at < p_starts_at) then raise exception 'Dati evento non validi'; end if;

  if p_participant_profile_ids is not null then
    perform public.set_area_event_participants(p_area_id, p_event_id, p_participant_profile_ids, p_visibility);
  else
    if (p_visibility = 'private' and exists (select 1 from public.event_participants where event_id = p_event_id))
       or (p_visibility = 'creator_participants' and not exists (select 1 from public.event_participants where event_id = p_event_id)) then
      raise exception 'Visibilita e partecipanti dell''evento non coerenti';
    end if;
    update public.area_events set visibility = p_visibility where id = p_event_id and area_id = p_area_id;
  end if;

  update public.area_events
  set title = btrim(p_title), notes = p_notes, starts_at = p_starts_at,
      ends_at = p_ends_at, is_all_day = coalesce(p_is_all_day, false),
      location = nullif(btrim(coalesce(p_location, '')), '')
  where id = p_event_id and area_id = p_area_id;
end;
$$;

create function public.set_area_event_participants(
  p_area_id uuid, p_event_id uuid, p_participant_profile_ids uuid[], p_visibility text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_creator_id uuid; v_participant_ids uuid[] := coalesce(p_participant_profile_ids, '{}');
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  select created_by_profile_id into v_creator_id from public.area_events
  where id = p_event_id and area_id = p_area_id for update;
  if not found then raise exception 'Evento non trovato'; end if;
  if v_creator_id is distinct from v_profile_id then raise exception 'permission denied'; end if;
  if p_visibility not in ('area', 'private', 'creator_participants')
     or exists (select 1 from unnest(v_participant_ids) as x where x is null)
     or (p_visibility = 'private' and cardinality(v_participant_ids) <> 0)
     or (p_visibility = 'creator_participants' and cardinality(v_participant_ids) = 0) then
    raise exception 'Visibilita e partecipanti dell''evento non coerenti';
  end if;
  if exists (
    select 1 from (select distinct unnest(v_participant_ids) as profile_id) ids
    left join public.area_memberships am on am.area_id = p_area_id and am.profile_id = ids.profile_id
    where am.profile_id is null
  ) then raise exception 'Partecipante non appartenente all''Area'; end if;

  delete from public.event_participants where event_id = p_event_id and area_id = p_area_id;
  insert into public.event_participants(event_id, area_id, profile_id, added_by_profile_id)
  select p_event_id, p_area_id, ids.profile_id, v_profile_id
  from (select distinct unnest(v_participant_ids) as profile_id) ids;
  update public.area_events set visibility = p_visibility where id = p_event_id and area_id = p_area_id;
end;
$$;

create function public.set_my_event_participation_status(
  p_area_id uuid, p_event_id uuid, p_participation_status text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null or p_participation_status not in ('pending', 'accepted', 'declined') then
    raise exception 'permission denied';
  end if;
  update public.event_participants ep
  set participation_status = p_participation_status
  from public.area_events e
  where ep.event_id = p_event_id and ep.area_id = p_area_id
    and ep.profile_id = v_profile_id and e.id = ep.event_id and e.area_id = p_area_id;
  if not found then raise exception 'Partecipazione non trovata o non accessibile'; end if;
end;
$$;

create function public.cancel_area_event(p_area_id uuid, p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  update public.area_events
  set status = 'cancelled'
  where id = p_event_id and area_id = p_area_id and created_by_profile_id = v_profile_id;
  if not found then raise exception 'Evento non trovato o non modificabile'; end if;
end;
$$;

create function public.delete_area_event(p_area_id uuid, p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_event_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  delete from public.area_events
  where id = p_event_id and area_id = p_area_id and created_by_profile_id = v_profile_id;
  if not found then raise exception 'Evento non trovato o non eliminabile'; end if;
end;
$$;

revoke all on function public.set_area_event_updated_at() from public;
revoke all on function public.assert_area_event_participant_visibility() from public;
revoke all on function public.current_area_event_role(uuid) from public;
revoke all on function public.get_area_events(uuid,text,timestamptz,timestamptz) from public;
revoke all on function public.get_area_event(uuid,uuid) from public;
revoke all on function public.create_area_event(uuid,text,text,timestamptz,timestamptz,boolean,text,text,uuid[]) from public;
revoke all on function public.update_area_event(uuid,uuid,text,text,timestamptz,timestamptz,boolean,text,text,uuid[]) from public;
revoke all on function public.set_area_event_participants(uuid,uuid,uuid[],text) from public;
revoke all on function public.set_my_event_participation_status(uuid,uuid,text) from public;
revoke all on function public.cancel_area_event(uuid,uuid) from public;
revoke all on function public.delete_area_event(uuid,uuid) from public;

grant execute on function public.get_area_events(uuid,text,timestamptz,timestamptz) to authenticated;
grant execute on function public.get_area_event(uuid,uuid) to authenticated;
grant execute on function public.create_area_event(uuid,text,text,timestamptz,timestamptz,boolean,text,text,uuid[]) to authenticated;
grant execute on function public.update_area_event(uuid,uuid,text,text,timestamptz,timestamptz,boolean,text,text,uuid[]) to authenticated;
grant execute on function public.set_area_event_participants(uuid,uuid,uuid[],text) to authenticated;
grant execute on function public.set_my_event_participation_status(uuid,uuid,text) to authenticated;
grant execute on function public.cancel_area_event(uuid,uuid) to authenticated;
grant execute on function public.delete_area_event(uuid,uuid) to authenticated;

revoke all on public.area_events, public.event_participants from public, authenticated;

commit;
