-- FamilArea — associazione sicura tra Contatti personali e Partecipanti Area.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

-- Un Contatto personale puo' avere un solo profilo tecnico riutilizzabile nelle
-- Aree. La tabella non e' esposta ai client: non deve rivelare chi possiede un
-- partecipante dell'Area.
create table public.contact_participant_profiles (
  contact_id uuid primary key references public.contacts(id) on delete restrict,
  profile_id uuid not null unique references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table public.contact_participant_profiles enable row level security;
alter table public.contact_participant_profiles no force row level security;

-- Mantiene la proiezione visibile nell'Area limitata a nome e cognome. Data di
-- nascita e recapiti non vengono mai copiati dal Contatto personale.
create function public.sync_contact_participant_profile()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.profiles p
  set first_name = new.first_name,
      last_name = new.last_name
  from public.contact_participant_profiles cpp
  where cpp.contact_id = new.id
    and cpp.profile_id = p.id;

  return new;
end;
$$;

create trigger contacts_sync_participant_profile
  after update of first_name, last_name on public.contacts
  for each row execute function public.sync_contact_participant_profile();

-- Gli admin dell'Area possono vedere il profilo proiettato, ma non possono
-- modificare i dati che restano di proprieta' della rubrica personale.
create or replace function public.update_area_member(
  p_area_id    uuid,
  p_profile_id uuid,
  p_first_name text,
  p_last_name  text,
  p_birth_date date
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select id into v_caller_profile_id
  from public.profiles
  where user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  if not exists (
    select 1 from public.area_memberships
    where area_id = p_area_id
      and profile_id = v_caller_profile_id
      and role = 'admin'
  ) then
    raise exception 'permission denied: solo un admin dell''Area puo'' modificare i partecipanti';
  end if;

  if not exists (
    select 1 from public.area_memberships
    where area_id = p_area_id
      and profile_id = p_profile_id
  ) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  if exists (
    select 1
    from public.contact_participant_profiles cpp
    where cpp.profile_id = p_profile_id
  ) then
    raise exception 'Impossibile modificare questo partecipante: i dati provengono da un Contatto personale';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome e'' obbligatorio';
  end if;

  update public.profiles
  set first_name = btrim(p_first_name),
      last_name  = nullif(btrim(coalesce(p_last_name, '')), ''),
      birth_date = p_birth_date
  where id = p_profile_id;
end;
$$;

-- Restituisce esclusivamente i Contatti del chiamante, dopo aver verificato che
-- egli sia admin dell'Area. Il booleano evita duplicati nella futura UI.
create function public.get_my_contacts_for_area(p_area_id uuid)
returns table(
  id uuid,
  first_name text,
  last_name text,
  birth_date date,
  is_already_participant boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_owner_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'permission denied: solo un admin dell''Area puo'' aggiungere partecipanti';
  end if;

  return query
  select c.id,
         c.first_name,
         c.last_name,
         c.birth_date,
         exists (
           select 1
           from public.contact_participant_profiles cpp
           join public.area_memberships am
             on am.profile_id = cpp.profile_id
           where cpp.contact_id = c.id
             and am.area_id = p_area_id
         )
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

-- Associa un Contatto di proprieta' del chiamante all'Area come profilo
-- gestito. Il lock sul Contatto/profilo serializza associazioni e cancellazioni.
create function public.add_my_contact_to_area(
  p_area_id uuid,
  p_contact_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_contact_first_name text;
  v_contact_last_name text;
  v_participant_profile_id uuid;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  -- Serializza l'associazione con remove_area_member nella stessa Area.
  perform 1 from public.areas where id = p_area_id for update;
  if not found then
    raise exception 'Area non trovata';
  end if;

  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_owner_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'permission denied: solo un admin dell''Area puo'' aggiungere partecipanti';
  end if;

  select c.first_name, c.last_name
  into v_contact_first_name, v_contact_last_name
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_profile_id = v_owner_profile_id
  for update;

  if not found then
    raise exception 'Contatto non trovato o non accessibile';
  end if;

  select cpp.profile_id
  into v_participant_profile_id
  from public.contact_participant_profiles cpp
  where cpp.contact_id = p_contact_id
  for update;

  if v_participant_profile_id is null then
    insert into public.profiles(first_name, last_name)
    values (v_contact_first_name, v_contact_last_name)
    returning id into v_participant_profile_id;

    insert into public.contact_participant_profiles(contact_id, profile_id)
    values (p_contact_id, v_participant_profile_id);
  else
    perform 1
    from public.profiles p
    where p.id = v_participant_profile_id
      and p.user_id is null
    for update;

    if not found then
      raise exception 'Associazione Contatto/Partecipante non valida';
    end if;

    -- Ripara anche eventuali proiezioni antecedenti alla sincronizzazione.
    update public.profiles
    set first_name = v_contact_first_name,
        last_name = v_contact_last_name
    where id = v_participant_profile_id;
  end if;

  if exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_participant_profile_id
  ) then
    raise exception 'Il Contatto partecipa gia'' a questa Area';
  end if;

  insert into public.area_memberships(area_id, profile_id, role)
  values (p_area_id, v_participant_profile_id, 'managed');
end;
$$;

-- Il Contatto resta cancellabile solo quando non partecipa piu' ad alcuna Area.
-- In quel caso viene rimossa anche la sua proiezione tecnica, ma solo dopo i
-- controlli espliciti che escludono dipendenze inattese.
create or replace function public.delete_my_contact(p_contact_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_participant_profile_id uuid;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  perform 1
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_profile_id = v_owner_profile_id
  for update;
  if not found then
    raise exception 'Contatto non trovato o non accessibile';
  end if;

  select cpp.profile_id
  into v_participant_profile_id
  from public.contact_participant_profiles cpp
  where cpp.contact_id = p_contact_id
  for update;

  if v_participant_profile_id is not null then
    perform 1
    from public.profiles p
    where p.id = v_participant_profile_id
      and p.user_id is null
    for update;
    if not found then
      raise exception 'Associazione Contatto/Partecipante non valida';
    end if;

    if exists (
      select 1 from public.area_memberships am
      where am.profile_id = v_participant_profile_id
    ) then
      raise exception 'Impossibile eliminare il contatto: rimuovilo prima dalle Aree in cui partecipa';
    end if;

    if exists (
      select 1 from public.areas ar
      where ar.created_by = v_participant_profile_id
    ) or exists (
      select 1 from public.contacts c
      where c.owner_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.area_activities a
      where a.created_by_profile_id = v_participant_profile_id
         or a.completed_by_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.area_events e
      where e.created_by_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.activity_assignees aa
      where aa.assigned_by_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.event_participants ep
      where ep.added_by_profile_id = v_participant_profile_id
    ) then
      raise exception 'Impossibile eliminare il contatto: il partecipante tecnico ha dipendenze inattese';
    end if;

    delete from public.contact_participant_profiles
    where contact_id = p_contact_id
      and profile_id = v_participant_profile_id;

    delete from public.profiles
    where id = v_participant_profile_id
      and user_id is null;
    if not found then
      raise exception 'Associazione Contatto/Partecipante non valida';
    end if;
  end if;

  delete from public.contacts
  where id = p_contact_id
    and owner_profile_id = v_owner_profile_id;
end;
$$;

revoke all on public.contact_participant_profiles from public, authenticated;
revoke all on function public.sync_contact_participant_profile() from public;
revoke all on function public.get_my_contacts_for_area(uuid) from public;
revoke all on function public.add_my_contact_to_area(uuid, uuid) from public;
revoke all on function public.update_area_member(uuid, uuid, text, text, date) from public;
revoke all on function public.delete_my_contact(uuid) from public;

grant execute on function public.get_my_contacts_for_area(uuid) to authenticated;
grant execute on function public.add_my_contact_to_area(uuid, uuid) to authenticated;
grant execute on function public.update_area_member(uuid, uuid, text, text, date) to authenticated;
grant execute on function public.delete_my_contact(uuid) to authenticated;

commit;
