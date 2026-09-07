-- FamilArea — Liste condivise per Area.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create table public.area_lists (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(id) on delete cascade,
  title text not null check (char_length(btrim(title)) > 0),
  description text,
  visibility text not null default 'area'
    check (visibility in ('area', 'private', 'creator_participants')),
  created_by_profile_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, area_id)
);

create table public.area_list_participants (
  list_id uuid not null,
  area_id uuid not null,
  profile_id uuid not null,
  added_at timestamptz not null default now(),
  added_by_profile_id uuid not null references public.profiles(id),
  primary key (list_id, profile_id),
  foreign key (list_id, area_id)
    references public.area_lists(id, area_id) on delete cascade,
  foreign key (area_id, profile_id)
    references public.area_memberships(area_id, profile_id) on delete cascade
);

create table public.area_list_items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.area_lists(id) on delete cascade,
  text text not null check (char_length(btrim(text)) > 0),
  status text not null default 'open' check (status in ('open', 'completed')),
  position integer not null default 0 check (position >= 0),
  created_by_profile_id uuid not null references public.profiles(id),
  completed_by_profile_id uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint area_list_items_completion_check check (
    (status = 'completed' and completed_at is not null and completed_by_profile_id is not null)
    or (status = 'open' and completed_at is null and completed_by_profile_id is null)
  )
);

create index area_lists_area_created_idx
  on public.area_lists(area_id, created_at desc);
create index area_list_participants_profile_idx
  on public.area_list_participants(area_id, profile_id, list_id);
create index area_list_items_list_position_idx
  on public.area_list_items(list_id, position, created_at, id);

alter table public.area_lists enable row level security;
alter table public.area_list_participants enable row level security;
alter table public.area_list_items enable row level security;
alter table public.area_lists no force row level security;
alter table public.area_list_participants no force row level security;
alter table public.area_list_items no force row level security;

create function public.set_area_list_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger area_lists_set_updated_at
  before update on public.area_lists
  for each row execute function public.set_area_list_updated_at();

create trigger area_list_items_set_updated_at
  before update on public.area_list_items
  for each row execute function public.set_area_list_updated_at();

-- Consente alle RPC di aggiornare visibilità e partecipanti nella stessa
-- transazione, ma impedisce stati finali incoerenti.
create function public.assert_area_list_participant_visibility()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_list_id uuid;
  v_visibility text;
  v_participant_count integer;
begin
  if tg_table_name = 'area_lists' then
    if tg_op = 'DELETE' then v_list_id := old.id; else v_list_id := new.id; end if;
  else
    if tg_op = 'DELETE' then v_list_id := old.list_id; else v_list_id := new.list_id; end if;
  end if;

  select l.visibility into v_visibility
  from public.area_lists l
  where l.id = v_list_id;
  if not found then return null; end if;

  select count(*) into v_participant_count
  from public.area_list_participants alp
  where alp.list_id = v_list_id;

  if (v_visibility = 'private' and v_participant_count <> 0)
     or (v_visibility = 'creator_participants' and v_participant_count = 0) then
    raise exception 'Visibilita e partecipanti della Lista non coerenti';
  end if;
  return null;
end;
$$;

create constraint trigger area_lists_visibility_participants_check
  after insert or update of visibility on public.area_lists
  deferrable initially deferred
  for each row execute function public.assert_area_list_participant_visibility();

create constraint trigger area_list_participants_visibility_check
  after insert or delete or update of list_id, area_id on public.area_list_participants
  deferrable initially deferred
  for each row execute function public.assert_area_list_participant_visibility();

create function public.current_area_list_role(p_area_id uuid)
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

create function public.get_area_lists(p_area_id uuid)
returns table(
  id uuid, title text, description text, visibility text,
  created_by_profile_id uuid, created_at timestamptz, updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;

  return query
  select l.id, l.title, l.description, l.visibility,
         l.created_by_profile_id, l.created_at, l.updated_at
  from public.area_lists l
  where l.area_id = p_area_id
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (
        l.visibility = 'creator_participants'
        and exists (
          select 1 from public.area_list_participants alp
          where alp.list_id = l.id and alp.profile_id = v_profile_id
        )
      )
    )
  order by l.created_at desc, l.id;
end;
$$;

create function public.get_area_list(p_area_id uuid, p_list_id uuid)
returns table(
  id uuid, title text, description text, visibility text,
  created_by_profile_id uuid, created_at timestamptz, updated_at timestamptz,
  participant_profile_ids uuid[], items jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;

  return query
  select l.id, l.title, l.description, l.visibility,
         l.created_by_profile_id, l.created_at, l.updated_at,
         case when l.created_by_profile_id = v_profile_id then
           array(
             select alp.profile_id from public.area_list_participants alp
             where alp.list_id = l.id order by alp.added_at, alp.profile_id
           )
         end,
         coalesce(
           (
             select jsonb_agg(
               jsonb_build_object(
                 'id', i.id,
                 'text', i.text,
                 'status', i.status,
                 'position', i.position,
                 'created_by_profile_id', i.created_by_profile_id,
                 'completed_by_profile_id', i.completed_by_profile_id,
                 'created_at', i.created_at,
                 'completed_at', i.completed_at,
                 'updated_at', i.updated_at
               ) order by i.position, i.created_at, i.id
             )
             from public.area_list_items i
             where i.list_id = l.id
           ),
           '[]'::jsonb
         )
  from public.area_lists l
  where l.id = p_list_id and l.area_id = p_area_id
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (
        l.visibility = 'creator_participants'
        and exists (
          select 1 from public.area_list_participants alp
          where alp.list_id = l.id and alp.profile_id = v_profile_id
        )
      )
    );
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
end;
$$;

create function public.create_area_list(
  p_area_id uuid,
  p_title text,
  p_description text,
  p_visibility text,
  p_participant_profile_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_list_id uuid;
  v_participant_ids uuid[] := coalesce(p_participant_profile_ids, '{}');
begin
  -- Serializza la creazione con remove_area_member nella stessa Area.
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title, '')) = ''
     or p_visibility not in ('area', 'private', 'creator_participants')
     or exists (select 1 from unnest(v_participant_ids) as x where x is null)
     or (p_visibility = 'private' and cardinality(v_participant_ids) <> 0)
     or (p_visibility = 'creator_participants' and cardinality(v_participant_ids) = 0) then
    raise exception 'Dati Lista non validi';
  end if;
  if exists (
    select 1
    from (select distinct unnest(v_participant_ids) as profile_id) ids
    left join public.area_memberships am
      on am.area_id = p_area_id and am.profile_id = ids.profile_id
    where am.profile_id is null
  ) then raise exception 'Partecipante non appartenente all''Area'; end if;

  insert into public.area_lists(area_id, title, description, visibility, created_by_profile_id)
  values (
    p_area_id,
    btrim(p_title),
    nullif(btrim(coalesce(p_description, '')), ''),
    p_visibility,
    v_profile_id
  )
  returning id into v_list_id;

  insert into public.area_list_participants(list_id, area_id, profile_id, added_by_profile_id)
  select v_list_id, p_area_id, ids.profile_id, v_profile_id
  from (select distinct unnest(v_participant_ids) as profile_id) ids;
  return v_list_id;
end;
$$;

create function public.update_area_list(
  p_area_id uuid,
  p_list_id uuid,
  p_title text,
  p_description text,
  p_visibility text,
  p_participant_profile_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_creator_id uuid;
  v_participant_ids uuid[] := coalesce(p_participant_profile_ids, '{}');
begin
  -- Mantiene lo stesso ordine di lock di create_area_list e remove_area_member.
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  select l.created_by_profile_id into v_creator_id
  from public.area_lists l
  where l.id = p_list_id and l.area_id = p_area_id
  for update;
  if not found then raise exception 'Lista non trovata'; end if;
  if v_creator_id is distinct from v_profile_id then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title, '')) = ''
     or p_visibility not in ('area', 'private', 'creator_participants')
     or exists (select 1 from unnest(v_participant_ids) as x where x is null)
     or (p_visibility = 'private' and cardinality(v_participant_ids) <> 0)
     or (p_visibility = 'creator_participants' and cardinality(v_participant_ids) = 0) then
    raise exception 'Dati Lista non validi';
  end if;
  if exists (
    select 1
    from (select distinct unnest(v_participant_ids) as profile_id) ids
    left join public.area_memberships am
      on am.area_id = p_area_id and am.profile_id = ids.profile_id
    where am.profile_id is null
  ) then raise exception 'Partecipante non appartenente all''Area'; end if;

  delete from public.area_list_participants
  where list_id = p_list_id and area_id = p_area_id;
  insert into public.area_list_participants(list_id, area_id, profile_id, added_by_profile_id)
  select p_list_id, p_area_id, ids.profile_id, v_profile_id
  from (select distinct unnest(v_participant_ids) as profile_id) ids;
  update public.area_lists
  set title = btrim(p_title),
      description = nullif(btrim(coalesce(p_description, '')), ''),
      visibility = p_visibility
  where id = p_list_id and area_id = p_area_id;
end;
$$;

create function public.delete_area_list(p_area_id uuid, p_list_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  delete from public.area_lists
  where id = p_list_id and area_id = p_area_id and created_by_profile_id = v_profile_id;
  if not found then raise exception 'Lista non trovata o non eliminabile'; end if;
end;
$$;

create function public.add_area_list_item(
  p_area_id uuid,
  p_list_id uuid,
  p_text text,
  p_position integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_item_id uuid; v_position integer;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_text, '')) = '' or (p_position is not null and p_position < 0) then
    raise exception 'Dati elemento Lista non validi';
  end if;
  perform 1
  from public.area_lists l
  where l.id = p_list_id and l.area_id = p_area_id
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (
        l.visibility = 'creator_participants'
        and exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id = v_profile_id)
      )
    )
  for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  if p_position is null then
    select coalesce(max(i.position) + 1, 0) into v_position
    from public.area_list_items i where i.list_id = p_list_id;
  else
    v_position := p_position;
  end if;
  insert into public.area_list_items(list_id, text, position, created_by_profile_id)
  values (p_list_id, btrim(p_text), v_position, v_profile_id)
  returning id into v_item_id;
  return v_item_id;
end;
$$;

create function public.update_area_list_item(
  p_area_id uuid,
  p_list_id uuid,
  p_item_id uuid,
  p_text text,
  p_position integer default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_list_creator_id uuid; v_item_creator_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_text, '')) = '' or (p_position is not null and p_position < 0) then
    raise exception 'Dati elemento Lista non validi';
  end if;
  select l.created_by_profile_id into v_list_creator_id
  from public.area_lists l
  where l.id = p_list_id and l.area_id = p_area_id
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (
        l.visibility = 'creator_participants'
        and exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id = v_profile_id)
      )
    )
  for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  select i.created_by_profile_id into v_item_creator_id
  from public.area_list_items i
  where i.id = p_item_id and i.list_id = p_list_id
  for update;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
  if v_item_creator_id is distinct from v_profile_id and v_list_creator_id is distinct from v_profile_id then
    raise exception 'permission denied';
  end if;
  update public.area_list_items
  set text = btrim(p_text), position = coalesce(p_position, position)
  where id = p_item_id and list_id = p_list_id;
end;
$$;

create function public.set_area_list_item_status(
  p_area_id uuid,
  p_list_id uuid,
  p_item_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null or p_status not in ('open', 'completed') then
    raise exception 'permission denied';
  end if;
  perform 1
  from public.area_lists l
  where l.id = p_list_id and l.area_id = p_area_id
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (
        l.visibility = 'creator_participants'
        and exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id = v_profile_id)
      )
    )
  for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  update public.area_list_items
  set status = p_status,
      completed_at = case when p_status = 'completed' then now() else null end,
      completed_by_profile_id = case when p_status = 'completed' then v_profile_id else null end
  where id = p_item_id and list_id = p_list_id;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
end;
$$;

create function public.delete_area_list_item(
  p_area_id uuid,
  p_list_id uuid,
  p_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_list_creator_id uuid; v_item_creator_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  select l.created_by_profile_id into v_list_creator_id
  from public.area_lists l
  where l.id = p_list_id and l.area_id = p_area_id
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (
        l.visibility = 'creator_participants'
        and exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id = v_profile_id)
      )
    )
  for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  select i.created_by_profile_id into v_item_creator_id
  from public.area_list_items i
  where i.id = p_item_id and i.list_id = p_list_id
  for update;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
  if v_item_creator_id is distinct from v_profile_id and v_list_creator_id is distinct from v_profile_id then
    raise exception 'permission denied';
  end if;
  delete from public.area_list_items
  where id = p_item_id and list_id = p_list_id;
end;
$$;

-- Mantiene tutte le protezioni precedenti e aggiunge quelle delle Liste.
create or replace function public.remove_area_member(p_area_id uuid, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_caller_profile_id uuid; v_target_role text;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato: profilo non trovato'; end if;
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  if not exists (select 1 from public.area_memberships am where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin') then
    raise exception 'Utente non autorizzato: solo un admin dell''Area puÃ² rimuovere membri';
  end if;
  select am.role into v_target_role from public.area_memberships am where am.area_id = p_area_id and am.profile_id = p_profile_id for update;
  if not found then raise exception 'Membership del membro non trovata in questa Area'; end if;
  if v_target_role = 'admin' and not exists (select 1 from public.area_memberships am where am.area_id = p_area_id and am.role = 'admin' and am.profile_id <> p_profile_id) then
    raise exception 'Impossibile rimuovere l''ultimo amministratore dell''Area';
  end if;
  perform 1 from public.area_activities a where a.area_id = p_area_id and a.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: Ã¨ creatore di attivitÃ  in questa Area'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: Ã¨ creatore di eventi in questa Area'; end if;
  perform 1 from public.area_lists l where l.area_id = p_area_id and l.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: Ã¨ creatore di Liste in questa Area'; end if;
  perform 1 from public.area_activities a where a.area_id = p_area_id and a.visibility = 'creator_assignees' and exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id = p_profile_id) and not exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id <> p_profile_id) for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo assegnatario di attivitÃ  selettiva'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.visibility = 'creator_participants' and exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id = p_profile_id) and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id <> p_profile_id) for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di evento selettivo'; end if;
  perform 1 from public.area_lists l where l.area_id = p_area_id and l.visibility = 'creator_participants' and exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id = p_profile_id) and not exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id <> p_profile_id) for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di Lista selettiva'; end if;
  delete from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id;
end;
$$;

revoke all on public.area_lists, public.area_list_participants, public.area_list_items from public, authenticated;
revoke all on function public.set_area_list_updated_at() from public;
revoke all on function public.assert_area_list_participant_visibility() from public;
revoke all on function public.current_area_list_role(uuid) from public;
revoke all on function public.get_area_lists(uuid) from public;
revoke all on function public.get_area_list(uuid, uuid) from public;
revoke all on function public.create_area_list(uuid, text, text, text, uuid[]) from public;
revoke all on function public.update_area_list(uuid, uuid, text, text, text, uuid[]) from public;
revoke all on function public.delete_area_list(uuid, uuid) from public;
revoke all on function public.add_area_list_item(uuid, uuid, text, integer) from public;
revoke all on function public.update_area_list_item(uuid, uuid, uuid, text, integer) from public;
revoke all on function public.set_area_list_item_status(uuid, uuid, uuid, text) from public;
revoke all on function public.delete_area_list_item(uuid, uuid, uuid) from public;
revoke all on function public.remove_area_member(uuid, uuid) from public;

grant execute on function public.get_area_lists(uuid) to authenticated;
grant execute on function public.get_area_list(uuid, uuid) to authenticated;
grant execute on function public.create_area_list(uuid, text, text, text, uuid[]) to authenticated;
grant execute on function public.update_area_list(uuid, uuid, text, text, text, uuid[]) to authenticated;
grant execute on function public.delete_area_list(uuid, uuid) to authenticated;
grant execute on function public.add_area_list_item(uuid, uuid, text, integer) to authenticated;
grant execute on function public.update_area_list_item(uuid, uuid, uuid, text, integer) to authenticated;
grant execute on function public.set_area_list_item_status(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.delete_area_list_item(uuid, uuid, uuid) to authenticated;
grant execute on function public.remove_area_member(uuid, uuid) to authenticated;

commit;
