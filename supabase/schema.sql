-- =============================================================================
-- FamilArea â€” schema di riferimento (verificato contro il database remoto)
-- =============================================================================
-- Questo file NON Ã¨ stato eseguito contro il database remoto.
-- Rispecchia la configurazione verificata manualmente su Supabase il 2026-09-04:
-- GRANT, RLS/FORCE RLS, funzioni SECURITY DEFINER, policy e privilegi EXECUTE
-- sono stati confermati uno per uno contro il progetto reale (flusso testato:
-- Login â†’ Le mie Aree â†’ apertura Area â†’ elenco membri).
--
-- Convenzioni:
--  - tutte le scritture su profiles/areas/area_memberships avvengono SOLO
--    tramite le funzioni RPC SECURITY DEFINER (create_area, add_area_member)
--    o tramite il trigger handle_new_user. Al ruolo "authenticated" non viene
--    mai concesso INSERT/DELETE diretto su queste tabelle.
--  - le funzioni helper usate nelle policy RLS (is_area_member, can_view_profile)
--    sono SECURITY DEFINER di proprietÃ  del proprietario delle tabelle: essendo
--    l'owner, per default bypassano la RLS all'interno del proprio corpo e
--    quindi NON generano ricorsione quando vengono richiamate da una policy.
--    Questo richiede che le 4 tabelle abbiano FORCE ROW LEVEL SECURITY = false
--    (confermato sul remoto), altrimenti anche l'owner sarebbe soggetto a RLS.
-- =============================================================================

create extension if not exists pgcrypto;

-- =============================================================================
-- 1. TABELLE
-- =============================================================================

create table if not exists public.profiles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid unique references auth.users (id) on delete cascade,
  first_name  text not null,
  last_name   text,
  birth_date  date,
  avatar_path text,
  created_at  timestamptz not null default now()
);
comment on table public.profiles is
  'Un profilo per ogni persona nota a FamilArea. user_id Ã¨ NULL per i profili "gestiti" (senza account) creati da add_area_member.';

create table if not exists public.areas (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) > 0),
  area_type   text not null check (area_type in ('family','school','sport','friends','course','travel','other')),
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.area_memberships (
  id          uuid primary key default gen_random_uuid(),
  area_id     uuid not null references public.areas (id) on delete cascade,
  profile_id  uuid not null references public.profiles (id) on delete cascade,
  role        text not null check (role in ('admin','member','managed')),
  created_at  timestamptz not null default now(),
  unique (area_id, profile_id)
);

create table if not exists public.profile_contacts (
  id            uuid primary key default gen_random_uuid(),
  area_id       uuid not null references public.areas (id) on delete cascade,
  profile_id    uuid not null references public.profiles (id) on delete cascade,
  contact_type  text not null check (contact_type in ('email','phone')),
  contact_value text not null check (char_length(btrim(contact_value)) > 0),
  is_primary    boolean not null default false,
  created_at    timestamptz not null default now(),
  constraint profile_contacts_area_profile_membership_fkey
    foreign key (area_id, profile_id)
    references public.area_memberships (area_id, profile_id)
    on delete cascade,
  constraint profile_contacts_email_normalized_check
    check (contact_type <> 'email' or contact_value = lower(btrim(contact_value))),
  constraint profile_contacts_phone_e164_check
    check (contact_type <> 'phone' or contact_value ~ '^\+[1-9][0-9]{1,14}$'),
  unique (area_id, profile_id, contact_type, contact_value)
);
comment on table public.profile_contacts is
  'Contatti aggiuntivi (email/telefono) per un profilo, tipicamente usati per profili gestiti senza account. Non ancora usata dal client: nessuna policy di accesso definita finchÃ© non serve.';

create unique index if not exists profile_contacts_one_primary_per_type
  on public.profile_contacts (area_id, profile_id, contact_type)
  where is_primary = true;

create table if not exists public.area_activities (
  id uuid primary key default gen_random_uuid(), area_id uuid not null references public.areas(id) on delete cascade,
  title text not null check (char_length(btrim(title)) > 0), notes text,
  activity_type text not null check (activity_type in ('task','reminder','deadline','appointment')),
  status text not null default 'open' check (status in ('open','completed','cancelled')),
  priority text not null default 'normal' check (priority in ('low','normal','high')),
  visibility text not null default 'area' check (visibility in ('private','creator_assignees','area')),
  starts_at timestamptz, due_at timestamptz, is_all_day boolean not null default false,
  recurrence_frequency text, recurrence_interval smallint, recurrence_weekdays smallint[],
  recurrence_until date, recurrence_timezone text,
  created_by_profile_id uuid references public.profiles(id) on delete set null,
  completed_by_profile_id uuid references public.profiles(id) on delete set null,
  completed_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint area_activities_dates_check check (starts_at is null or due_at is null or due_at >= starts_at),
  constraint area_activities_completion_check check ((status = 'completed' and completed_at is not null) or (status <> 'completed' and completed_at is null and completed_by_profile_id is null)),
  constraint area_activities_recurrence_frequency_check check (recurrence_frequency is null or recurrence_frequency = 'weekly'),
  constraint area_activities_recurrence_configuration_check check (
    (recurrence_frequency is null and recurrence_interval is null and recurrence_weekdays is null and recurrence_until is null and recurrence_timezone is null)
    or (recurrence_frequency = 'weekly' and starts_at is not null and recurrence_interval is not null and recurrence_interval > 0
      and recurrence_weekdays is not null and cardinality(recurrence_weekdays) > 0 and array_position(recurrence_weekdays, null) is null
      and recurrence_weekdays <@ array[1,2,3,4,5,6,7]::smallint[] and recurrence_until is not null
      and recurrence_timezone is not null and btrim(recurrence_timezone) <> ''
      and extract(isodow from (starts_at at time zone recurrence_timezone))::smallint = any(recurrence_weekdays)
      and recurrence_until >= (starts_at at time zone recurrence_timezone)::date)
  ),
  unique (id, area_id)
);
create table if not exists public.activity_assignees (
  activity_id uuid not null, area_id uuid not null, profile_id uuid not null,
  assigned_at timestamptz not null default now(), assigned_by_profile_id uuid references public.profiles(id) on delete set null,
  primary key (activity_id, profile_id),
  foreign key (activity_id, area_id) references public.area_activities(id, area_id) on delete cascade,
  foreign key (area_id, profile_id) references public.area_memberships(area_id, profile_id) on delete cascade
);
create index if not exists area_activities_open_due_idx on public.area_activities(area_id, status, due_at) where status = 'open';
create index if not exists area_activities_starts_idx on public.area_activities(area_id, starts_at) where starts_at is not null;
create index if not exists area_activities_created_idx on public.area_activities(area_id, created_at desc);
create index if not exists area_activities_weekly_recurrence_idx on public.area_activities(area_id, recurrence_until) where recurrence_frequency = 'weekly' and status = 'open';
create index if not exists activity_assignees_profile_idx on public.activity_assignees(area_id, profile_id, activity_id);

alter table public.profiles          enable row level security;
alter table public.areas             enable row level security;
alter table public.area_memberships  enable row level security;
alter table public.profile_contacts  enable row level security;
alter table public.area_activities   enable row level security;
alter table public.activity_assignees enable row level security;

-- confermato sul remoto: FORCE RLS = false su tutte e 4 (necessario perchÃ© le
-- funzioni SECURITY DEFINER sotto possano bypassare la RLS come table owner).
alter table public.profiles          no force row level security;
alter table public.areas             no force row level security;
alter table public.area_memberships  no force row level security;
alter table public.profile_contacts  no force row level security;
alter table public.area_activities   no force row level security;
alter table public.activity_assignees no force row level security;

-- =============================================================================
-- 2. FUNZIONI HELPER PER LE POLICY RLS (SECURITY DEFINER, non ricorsive)
-- =============================================================================

create or replace function public.is_area_member(p_area_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.area_memberships am
    join public.profiles p on p.id = am.profile_id
    where am.area_id = p_area_id
      and p.user_id = auth.uid()
      and am.role in ('admin', 'member')
  );
$$;
comment on function public.is_area_member(uuid) is
  'Vero se l''utente autenticato ha una membership autonoma admin o member nell''Area indicata. I profili managed non ottengono accesso autonomo anche se collegati ad Auth.';

create or replace function public.can_view_profile(p_profile_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    exists (
      select 1 from public.profiles me
      where me.id = p_profile_id
        and me.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.area_memberships am_target
      join public.area_memberships am_me on am_me.area_id = am_target.area_id
      join public.profiles me on me.id = am_me.profile_id
      where am_target.profile_id = p_profile_id
        and me.user_id = auth.uid()
        and am_me.role in ('admin', 'member')
    );
$$;
comment on function public.can_view_profile(uuid) is
  'Vero se il profilo e'' quello dell''utente autenticato, oppure se il chiamante e'' admin/member in un''Area condivisa con quel profilo. I managed non ottengono visibilita'' autonoma sulle Aree.';

revoke all on function public.is_area_member(uuid)   from public;
revoke all on function public.can_view_profile(uuid) from public;
grant execute on function public.is_area_member(uuid)   to authenticated;
grant execute on function public.can_view_profile(uuid) to authenticated;

-- =============================================================================
-- 3. TRIGGER: creazione automatica del profilo alla registrazione
-- =============================================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (user_id, first_name, last_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'first_name', ''),
    new.raw_user_meta_data ->> 'last_name'
  );
  return new;
end;
$$;
comment on function public.handle_new_user() is
  'Trigger su auth.users: crea il profilo pubblico associato leggendo first_name/last_name dai metadata di signUp.';

revoke all on function public.handle_new_user() from public;
-- nessun grant execute: la funzione viene invocata solo dal trigger, mai direttamente dal client.

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =============================================================================
-- 4. RPC: creazione Area (con membership admin per il creatore)
-- =============================================================================

create or replace function public.create_area(p_name text, p_area_type text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_area_id    uuid;
begin
  select id into v_profile_id
  from public.profiles
  where user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  insert into public.areas (name, area_type, created_by)
  values (btrim(p_name), p_area_type, v_profile_id)
  returning id into v_area_id;

  insert into public.area_memberships (area_id, profile_id, role)
  values (v_area_id, v_profile_id, 'admin');

  return v_area_id;
end;
$$;
comment on function public.create_area(text, text) is
  'Crea una nuova Area e assegna il chiamante come admin. Il profilo del chiamante deve giÃ  esistere (creato da handle_new_user).';

revoke all on function public.create_area(text, text) from public;
grant execute on function public.create_area(text, text) to authenticated;

create or replace function public.update_area(
  p_area_id uuid,
  p_name text,
  p_area_type text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin'
  ) then raise exception 'permission denied: solo un admin dell''Area puÃ² modificare l''Area'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Il nome dell''Area Ã¨ obbligatorio'; end if;
  if p_area_type not in ('family', 'school', 'sport', 'friends', 'course', 'travel', 'other') then
    raise exception 'Tipo Area non valido: %', p_area_type;
  end if;

  update public.areas set name = btrim(p_name), area_type = p_area_type where id = p_area_id;
  if not found then raise exception 'Area non trovata'; end if;
end;
$$;
revoke all on function public.update_area(uuid, text, text) from public;
grant execute on function public.update_area(uuid, text, text) to authenticated;

-- =============================================================================
-- 5. RPC: aggiunta membro (profilo senza account) â€” solo admin dell'Area
-- =============================================================================

create or replace function public.add_area_member(
  p_area_id    uuid,
  p_first_name text,
  p_last_name  text,
  p_birth_date date,
  p_role       text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_new_profile_id    uuid;
begin
  if p_role not in ('admin','member','managed') then
    raise exception 'Ruolo non valido: %', p_role;
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome e'' obbligatorio';
  end if;

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
    raise exception 'permission denied: solo un admin dell''Area puÃ² aggiungere membri';
  end if;

  insert into public.profiles (first_name, last_name)
  values (btrim(p_first_name), nullif(btrim(coalesce(p_last_name, '')), ''))
  returning id into v_new_profile_id;

  insert into public.area_memberships (area_id, profile_id, role)
  values (p_area_id, v_new_profile_id, p_role);

  return v_new_profile_id;
end;
$$;
comment on function public.add_area_member(uuid, text, text, date, text) is
  'Crea un profilo senza account e lo aggiunge come membro dell''Area indicata. Verifica lato server che il chiamante sia admin di quell''Area.';

revoke all on function public.add_area_member(uuid, text, text, date, text) from public;
grant execute on function public.add_area_member(uuid, text, text, date, text) to authenticated;

-- =============================================================================
-- 5b. RPC: modifica anagrafica di un membro â€” solo admin dell'Area
-- =============================================================================

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
    raise exception 'permission denied: solo un admin dell''Area puÃ² modificare i membri';
  end if;

  if not exists (
    select 1 from public.area_memberships
    where area_id = p_area_id
      and profile_id = p_profile_id
  ) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome Ã¨ obbligatorio';
  end if;

  update public.profiles
  set first_name = btrim(p_first_name),
      last_name  = nullif(btrim(coalesce(p_last_name, '')), '')
  where id = p_profile_id;
end;
$$;
comment on function public.update_area_member(uuid, uuid, text, text, date) is
  'Aggiorna nome, cognome e data di nascita di un membro dell''Area. Richiede che il chiamante sia admin di quella Area; non modifica user_id nÃ© altre colonne.';

revoke all on function public.update_area_member(uuid, uuid, text, text, date) from public;
grant execute on function public.update_area_member(uuid, uuid, text, text, date) to authenticated;

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
    raise exception 'Utente non autorizzato: solo un admin dell''Area può rimuovere membri';
  end if;
  select am.role into v_target_role from public.area_memberships am where am.area_id = p_area_id and am.profile_id = p_profile_id for update;
  if not found then raise exception 'Membership del membro non trovata in questa Area'; end if;
  if v_target_role = 'admin' and not exists (select 1 from public.area_memberships am where am.area_id = p_area_id and am.role = 'admin' and am.profile_id <> p_profile_id) then
    raise exception 'Impossibile rimuovere l''ultimo amministratore dell''Area';
  end if;
  perform 1 from public.area_activities a where a.area_id = p_area_id and a.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: è creatore di attività in questa Area'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: è creatore di eventi in questa Area'; end if;
  perform 1 from public.area_activities a where a.area_id = p_area_id and a.visibility = 'creator_assignees' and exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id = p_profile_id) and not exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id <> p_profile_id) for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo assegnatario di attività selettiva'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.visibility = 'creator_participants' and exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id = p_profile_id) and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id <> p_profile_id) for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di evento selettivo'; end if;
  delete from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id;
end;
$$;
revoke all on function public.remove_area_member(uuid, uuid) from public;
grant execute on function public.remove_area_member(uuid, uuid) to authenticated;

-- =============================================================================
-- 18. Eliminazione Area
-- =============================================================================

create or replace function public.delete_area(p_area_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select p.id
  into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  perform 1
  from public.areas a
  where a.id = p_area_id
  for update;

  if not found then
    raise exception 'Area non trovata';
  end if;

  if not exists (
    select 1
    from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'Non sei autorizzato a eliminare questa Area';
  end if;

  delete from public.area_invites
  where area_id = p_area_id;

  delete from public.areas
  where id = p_area_id;
end;
$$;

revoke all on function public.delete_area(uuid) from public;
grant execute on function public.delete_area(uuid) to authenticated;

-- =============================================================================
-- 5c. RPC: contatti contestuali all'Area â€” solo admin dell'Area
-- =============================================================================

create or replace function public.require_area_contact_admin(p_area_id uuid, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃƒÂ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  select user_id into v_target_user_id from public.profiles where id = p_profile_id;
  if v_target_user_id is not null then
    raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente';
  end if;
end;
$$;
revoke all on function public.require_area_contact_admin(uuid, uuid) from public;

create or replace function public.get_area_member_contacts(
  p_area_id uuid,
  p_profile_id uuid
)
returns table (
  id uuid,
  contact_type text,
  contact_value text,
  is_primary boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃƒÂ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  select user_id into v_target_user_id from public.profiles where id = p_profile_id;
  if v_target_user_id is not null then
    raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente';
  end if;

  return query
  select pc.id, pc.contact_type, pc.contact_value, pc.is_primary, pc.created_at
  from public.profile_contacts pc
  where pc.area_id = p_area_id and pc.profile_id = p_profile_id
  order by pc.contact_type, pc.is_primary desc, pc.created_at, pc.id;
end;
$$;

create or replace function public.add_area_member_contact(
  p_area_id uuid,
  p_profile_id uuid,
  p_contact_type text,
  p_contact_value text,
  p_is_primary boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
  v_contact_type text := lower(btrim(p_contact_type));
  v_contact_value text;
  v_is_primary boolean;
  v_existing_count integer;
  v_contact_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃƒÂ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
  select user_id into v_target_user_id from public.profiles where id = p_profile_id;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  if v_contact_type is null or v_contact_type not in ('email', 'phone') then raise exception 'Tipo di contatto non valido'; end if;

  v_contact_value := case when v_contact_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_contact_value, '') = '' then raise exception 'Il valore del contatto ÃƒÂ¨ obbligatorio'; end if;
  if v_contact_type = 'phone' and v_contact_value !~ '^\+[1-9][0-9]{1,14}$' then
    raise exception 'Il telefono deve essere nel formato internazionale E.164';
  end if;

  perform 1 from public.profiles where id = p_profile_id for update;
  select count(*) into v_existing_count from public.profile_contacts
  where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type;
  v_is_primary := v_existing_count = 0 or coalesce(p_is_primary, false);
  if v_is_primary then
    update public.profile_contacts set is_primary = false
    where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type;
  end if;

  insert into public.profile_contacts (area_id, profile_id, contact_type, contact_value, is_primary)
  values (p_area_id, p_profile_id, v_contact_type, v_contact_value, v_is_primary)
  returning id into v_contact_id;
  return v_contact_id;
end;
$$;

create or replace function public.update_area_member_contact(
  p_area_id uuid,
  p_profile_id uuid,
  p_contact_id uuid,
  p_contact_value text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
  v_contact_type text;
  v_contact_value text;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃƒÂ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
  select user_id into v_target_user_id from public.profiles where id = p_profile_id;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type into v_contact_type from public.profile_contacts
  where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_contact_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;

  v_contact_value := case when v_contact_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_contact_value, '') = '' then raise exception 'Il valore del contatto ÃƒÂ¨ obbligatorio'; end if;
  if v_contact_type = 'phone' and v_contact_value !~ '^\+[1-9][0-9]{1,14}$' then
    raise exception 'Il telefono deve essere nel formato internazionale E.164';
  end if;
  update public.profile_contacts set contact_value = v_contact_value where id = p_contact_id;
end;
$$;

create or replace function public.set_area_member_contact_primary(
  p_area_id uuid,
  p_profile_id uuid,
  p_contact_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
  v_contact_type text;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃƒÂ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
  select user_id into v_target_user_id from public.profiles where id = p_profile_id;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type into v_contact_type from public.profile_contacts
  where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_contact_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  update public.profile_contacts set is_primary = false
  where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type;
  update public.profile_contacts set is_primary = true where id = p_contact_id;
end;
$$;

create or replace function public.delete_area_member_contact(
  p_area_id uuid,
  p_profile_id uuid,
  p_contact_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
  v_contact_type text;
  v_was_primary boolean;
  v_replacement_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃƒÂ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
  select user_id into v_target_user_id from public.profiles where id = p_profile_id;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type, is_primary into v_contact_type, v_was_primary from public.profile_contacts
  where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_contact_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  delete from public.profile_contacts where id = p_contact_id;
  if v_was_primary then
    select id into v_replacement_id from public.profile_contacts
    where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type
    order by created_at, id limit 1;
    if v_replacement_id is not null then
      update public.profile_contacts set is_primary = true where id = v_replacement_id;
    end if;
  end if;
end;
$$;

revoke all on function public.get_area_member_contacts(uuid, uuid) from public;
revoke all on function public.add_area_member_contact(uuid, uuid, text, text, boolean) from public;
revoke all on function public.update_area_member_contact(uuid, uuid, uuid, text) from public;
revoke all on function public.set_area_member_contact_primary(uuid, uuid, uuid) from public;
revoke all on function public.delete_area_member_contact(uuid, uuid, uuid) from public;

grant execute on function public.get_area_member_contacts(uuid, uuid) to authenticated;
grant execute on function public.add_area_member_contact(uuid, uuid, text, text, boolean) to authenticated;
grant execute on function public.update_area_member_contact(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.set_area_member_contact_primary(uuid, uuid, uuid) to authenticated;
grant execute on function public.delete_area_member_contact(uuid, uuid, uuid) to authenticated;

-- =============================================================================
-- 6. GRANT / REVOKE a livello di tabella
-- =============================================================================
-- 5d. AttivitÃƒÂ  condivise â€” helper, trigger e RPC
-- =============================================================================

create or replace function public.current_area_activity_role(p_area_id uuid)
returns table(profile_id uuid, role text) language sql security definer stable set search_path = public, pg_temp as $$
  select am.profile_id, am.role from public.area_memberships am join public.profiles p on p.id=am.profile_id
  where am.area_id=p_area_id and p.user_id=auth.uid() and am.role in ('admin','member');
$$;
create or replace function public.set_area_activity_updated_at()
returns trigger language plpgsql set search_path = public, pg_temp as $$ begin new.updated_at=now(); return new; end; $$;
drop trigger if exists area_activities_set_updated_at on public.area_activities;
create trigger area_activities_set_updated_at before update on public.area_activities for each row execute function public.set_area_activity_updated_at();

-- Le firme cambiate vengono eliminate esplicitamente: nessun overload RPC.
drop function if exists public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz);
drop function if exists public.get_area_activity(uuid,uuid);
drop function if exists public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[]);
drop function if exists public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean);
drop function if exists public.set_area_activity_assignees(uuid,uuid,uuid[]);
drop function if exists public.set_area_activity_status(uuid,uuid,text);
drop function if exists public.delete_area_activity(uuid,uuid);

create function public.get_area_activities(p_area_id uuid,p_status text default null,p_activity_type text default null,p_assigned_to_me boolean default false,p_due_from timestamptz default null,p_due_to timestamptz default null)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;
  return query select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at
  from public.area_activities a
  where a.area_id=p_area_id
    and (p_status is null or a.status=p_status) and (p_activity_type is null or a.activity_type=p_activity_type)
    and (p_due_from is null or a.due_at>=p_due_from) and (p_due_to is null or a.due_at<=p_due_to)
    and (a.visibility='area' or a.created_by_profile_id=v_profile or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile)))
    and (not p_assigned_to_me or exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile) or not exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id))
  order by a.due_at nulls last,a.created_at desc;
end; $$;

create function public.get_area_activity(p_area_id uuid,p_activity_id uuid)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,visibility text,assignee_profile_ids uuid[],starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;
  return query select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,array(select aa.profile_id from public.activity_assignees aa where aa.activity_id=a.id order by aa.assigned_at,aa.profile_id),a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at
  from public.area_activities a where a.id=p_activity_id and a.area_id=p_area_id
    and (a.visibility='area' or a.created_by_profile_id=v_profile or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile)));
  if not found then raise exception 'Attivita non trovata o non accessibile'; end if;
end; $$;

create function public.get_my_visible_activities()
returns table(activity_id uuid,area_id uuid,area_name text,area_type text,title text,notes text,activity_type text,status text,priority text,starts_at timestamptz,due_at timestamptz,is_all_day boolean,visibility text,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid;
begin
  select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid();
  if v_profile_id is null then raise exception 'permission denied'; end if;
  return query
  select a.id,ar.id,ar.name,ar.area_type,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.visibility,a.created_by_profile_id,a.created_at,a.updated_at
  from public.area_memberships am
  join public.areas ar on ar.id=am.area_id
  join public.area_activities a on a.area_id=am.area_id
  where am.profile_id=v_profile_id
    and am.role in ('admin','member')
    and (a.visibility='area' or a.created_by_profile_id=v_profile_id or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile_id)))
  order by coalesce(a.due_at,a.starts_at) asc nulls last,a.created_at asc,a.id asc;
end; $$;

revoke all on function public.get_my_visible_activities() from public;
grant execute on function public.get_my_visible_activities() to authenticated;

create function public.create_area_activity(p_area_id uuid,p_title text,p_notes text,p_activity_type text,p_priority text,p_starts_at timestamptz,p_due_at timestamptz,p_is_all_day boolean,p_assignee_profile_ids uuid[],p_visibility text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_id uuid; v_ids uuid[]:=coalesce(p_assignee_profile_ids,'{}');
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title,''))='' or p_activity_type not in ('task','reminder','deadline','appointment') or p_priority not in ('low','normal','high') or p_visibility not in ('private','creator_assignees','area') or (p_starts_at is not null and p_due_at is not null and p_due_at<p_starts_at) then raise exception 'Dati attivita non validi'; end if;
  if (p_visibility='private' and cardinality(v_ids)>0) or (p_visibility='creator_assignees' and cardinality(v_ids)=0) then raise exception 'Visibilita e assegnatari non coerenti'; end if;
  if v_role='member' and exists(select 1 from unnest(v_ids) x where x is distinct from v_profile) then raise exception 'permission denied'; end if;
  if exists(select 1 from unnest(v_ids) x left join public.area_memberships am on am.area_id=p_area_id and am.profile_id=x where am.profile_id is null) then raise exception 'Assegnatario non appartenente all''Area'; end if;
  insert into public.area_activities(area_id,title,notes,activity_type,priority,visibility,starts_at,due_at,is_all_day,created_by_profile_id) values(p_area_id,btrim(p_title),p_notes,p_activity_type,p_priority,p_visibility,p_starts_at,p_due_at,coalesce(p_is_all_day,false),v_profile) returning id into v_id;
  insert into public.activity_assignees(activity_id,area_id,profile_id,assigned_by_profile_id) select v_id,p_area_id,x,v_profile from(select distinct unnest(v_ids) x)s;
  return v_id;
end; $$;

create function public.update_area_activity(p_area_id uuid,p_activity_id uuid,p_title text,p_notes text,p_activity_type text,p_priority text,p_starts_at timestamptz,p_due_at timestamptz,p_is_all_day boolean,p_visibility text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_current_visibility text;
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  select created_by_profile_id,visibility into v_creator,v_current_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id; if not found then raise exception 'Attivita non trovata'; end if;
  if v_creator is distinct from v_profile and not (v_current_visibility='area' and p_visibility='area' and v_role='admin') then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title,''))='' or p_activity_type not in ('task','reminder','deadline','appointment') or p_priority not in ('low','normal','high') or p_visibility not in ('private','creator_assignees','area') or (p_starts_at is not null and p_due_at is not null and p_due_at<p_starts_at) then raise exception 'Dati attivita non validi'; end if;
  if (p_visibility='private' and exists(select 1 from public.activity_assignees where activity_id=p_activity_id)) or (p_visibility='creator_assignees' and not exists(select 1 from public.activity_assignees where activity_id=p_activity_id)) then raise exception 'Visibilita e assegnatari non coerenti'; end if;
  update public.area_activities set title=btrim(p_title),notes=p_notes,activity_type=p_activity_type,priority=p_priority,visibility=p_visibility,starts_at=p_starts_at,due_at=p_due_at,is_all_day=coalesce(p_is_all_day,false) where id=p_activity_id and area_id=p_area_id;
end; $$;

create function public.set_area_activity_assignees(p_area_id uuid,p_activity_id uuid,p_assignee_profile_ids uuid[],p_visibility text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_current_visibility text; v_ids uuid[]:=coalesce(p_assignee_profile_ids,'{}');
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  select created_by_profile_id,visibility into v_creator,v_current_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id for update; if not found then raise exception 'Attivita non trovata'; end if;
  if v_creator is distinct from v_profile and not (v_current_visibility='area' and p_visibility='area' and v_role='admin') then raise exception 'permission denied'; end if;
  if p_visibility not in ('private','creator_assignees','area') or (p_visibility='private' and cardinality(v_ids)>0) or (p_visibility='creator_assignees' and cardinality(v_ids)=0) then raise exception 'Visibilita e assegnatari non coerenti'; end if;
  if v_role='member' and exists(select 1 from unnest(v_ids) x where x is distinct from v_profile) then raise exception 'permission denied'; end if;
  if exists(select 1 from unnest(v_ids) x left join public.area_memberships am on am.area_id=p_area_id and am.profile_id=x where am.profile_id is null) then raise exception 'Assegnatario non appartenente all''Area'; end if;
  delete from public.activity_assignees where activity_id=p_activity_id and area_id=p_area_id;
  insert into public.activity_assignees(activity_id,area_id,profile_id,assigned_by_profile_id) select p_activity_id,p_area_id,x,v_profile from(select distinct unnest(v_ids)x)s;
  update public.area_activities set visibility=p_visibility where id=p_activity_id and area_id=p_area_id;
end; $$;

create function public.set_area_activity_status(p_area_id uuid,p_activity_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_visibility text;
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null or p_status not in ('open','completed','cancelled') then raise exception 'permission denied'; end if;
  select created_by_profile_id,visibility into v_creator,v_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id; if not found then raise exception 'Attivita non trovata'; end if;
  if v_visibility='private' and v_creator is distinct from v_profile then raise exception 'permission denied'; end if;
  if v_visibility='creator_assignees' and (p_status<>'completed' or (v_creator is distinct from v_profile and not exists(select 1 from public.activity_assignees where activity_id=p_activity_id and profile_id=v_profile))) then raise exception 'permission denied'; end if;
  if v_visibility='area' and v_role<>'admin' and (p_status<>'completed' or (exists(select 1 from public.activity_assignees where activity_id=p_activity_id) and not exists(select 1 from public.activity_assignees where activity_id=p_activity_id and profile_id=v_profile))) then raise exception 'permission denied'; end if;
  update public.area_activities set status=p_status,completed_at=case when p_status='completed' then now() else null end,completed_by_profile_id=case when p_status='completed' then v_profile else null end where id=p_activity_id and area_id=p_area_id;
end; $$;

create function public.delete_area_activity(p_area_id uuid,p_activity_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_status text; v_visibility text;
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  select created_by_profile_id,status,visibility into v_creator,v_status,v_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id; if not found then raise exception 'Attivita non trovata'; end if;
  if (v_visibility<>'area' and v_creator is distinct from v_profile) or (v_visibility='area' and v_role<>'admin' and (v_creator is distinct from v_profile or v_status<>'open')) then raise exception 'permission denied'; end if;
  delete from public.area_activities where id=p_activity_id and area_id=p_area_id;
end; $$;

revoke all on function public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz),public.get_area_activity(uuid,uuid),public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text),public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text),public.set_area_activity_assignees(uuid,uuid,uuid[],text),public.set_area_activity_status(uuid,uuid,text),public.delete_area_activity(uuid,uuid) from public;
grant execute on function public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz),public.get_area_activity(uuid,uuid),public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text),public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text),public.set_area_activity_assignees(uuid,uuid,uuid[],text),public.set_area_activity_status(uuid,uuid,text),public.delete_area_activity(uuid,uuid) to authenticated;

revoke all on public.area_activities,public.activity_assignees from public,authenticated;



-- 6. GRANT / REVOKE a livello di tabella
-- =============================================================================
-- Nessun INSERT/DELETE/UPDATE diretto per "authenticated": tutte le scritture
-- passano dalle funzioni SECURITY DEFINER sopra, che girano con i privilegi
-- del proprietario delle tabelle.

revoke all on public.profiles          from public, authenticated;
revoke all on public.areas             from public, authenticated;
revoke all on public.area_memberships  from public, authenticated;
revoke all on public.profile_contacts  from public, authenticated;
revoke all on public.area_activities   from public, authenticated;
revoke all on public.activity_assignees from public, authenticated;

grant select on public.profiles to authenticated;
grant update (first_name, last_name, avatar_path) on public.profiles to authenticated;

grant select on public.areas to authenticated;

grant select on public.area_memberships to authenticated;

-- profile_contacts: nessun grant per ora, non ancora usata dal client.

-- =============================================================================
-- 7. POLICY RLS (non ricorsive: si appoggiano alle funzioni SECURITY DEFINER)
-- =============================================================================

-- profiles ---------------------------------------------------------------
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
  on public.profiles
  for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists profiles_select_shared_area on public.profiles;
create policy profiles_select_shared_area
  on public.profiles
  for select
  to authenticated
  using (public.can_view_profile(id));

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
  on public.profiles
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- areas -------------------------------------------------------------------
-- confermato sul remoto: la policy verifica la membership tramite
-- area_memberships + profiles + auth.uid(), la stessa logica incapsulata in
-- is_area_member(uuid) qui sotto.
drop policy if exists areas_select_member on public.areas;
create policy areas_select_member
  on public.areas
  for select
  to authenticated
  using (public.is_area_member(id));

-- area_memberships ----------------------------------------------------------
drop policy if exists area_memberships_select_own_area on public.area_memberships;
create policy area_memberships_select_own_area
  on public.area_memberships
  for select
  to authenticated
  using (public.is_area_member(area_id));

-- profile_contacts ------------------------------------------------------
-- confermato sul remoto: RLS abilitata, nessuna policy presente -> nessun
-- accesso da "authenticated" finchÃ© non verrÃ  introdotta una RPC dedicata a
-- leggere/scrivere i contatti.
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
-- visibilitÃ  nella stessa transazione, ma impedisce qualsiasi stato finale
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

create or replace function public.get_my_visible_events()
returns table(
  event_id uuid,
  area_id uuid,
  area_name text,
  area_type text,
  title text,
  notes text,
  location text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_all_day boolean,
  status text,
  visibility text,
  created_by_profile_id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  own_participation_status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'permission denied';
  end if;

  return query
  select
    e.id,
    ar.id,
    ar.name,
    ar.area_type,
    e.title,
    e.notes,
    e.location,
    e.starts_at,
    e.ends_at,
    e.is_all_day,
    e.status,
    e.visibility,
    e.created_by_profile_id,
    e.created_at,
    e.updated_at,
    mine.participation_status
  from public.area_memberships am
  join public.areas ar on ar.id = am.area_id
  join public.area_events e on e.area_id = am.area_id
  left join public.event_participants mine
    on mine.event_id = e.id
    and mine.area_id = e.area_id
    and mine.profile_id = v_profile_id
  where am.profile_id = v_profile_id
    and am.role in ('admin', 'member')
    and (
      e.visibility = 'area'
      or e.created_by_profile_id = v_profile_id
      or (
        e.visibility = 'creator_participants'
        and mine.profile_id is not null
      )
    )
  order by e.starts_at asc, e.created_at asc, e.id asc;
end;
$$;

revoke all on function public.get_my_visible_events() from public;
grant execute on function public.get_my_visible_events() to authenticated;

-- =============================================================================
-- 9. Rubrica personale privata
-- =============================================================================

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  first_name text not null check (first_name = btrim(first_name) and char_length(first_name) > 0),
  last_name text check (last_name is null or last_name = btrim(last_name)),
  birth_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index contacts_owner_name_idx on public.contacts(owner_profile_id, lower(first_name), lower(coalesce(last_name, '')), id);

create table public.contact_methods (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references public.contacts(id) on delete cascade,
  type text not null check (type in ('email', 'phone')),
  value text not null check (value = btrim(value) and char_length(value) > 0),
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (contact_id, type, value)
);
create unique index contact_methods_email_case_insensitive_unique on public.contact_methods(contact_id, lower(value)) where type = 'email';
create unique index contact_methods_one_primary_per_type on public.contact_methods(contact_id, type) where is_primary;

alter table public.contacts enable row level security;
alter table public.contact_methods enable row level security;
alter table public.contacts no force row level security;
alter table public.contact_methods no force row level security;

create function public.set_personal_contact_updated_at()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin new.updated_at = now(); return new; end;
$$;
create trigger contacts_set_updated_at before update on public.contacts for each row execute function public.set_personal_contact_updated_at();
create trigger contact_methods_set_updated_at before update on public.contact_methods for each row execute function public.set_personal_contact_updated_at();

create function public.get_my_contacts()
returns table(id uuid, first_name text, last_name text, birth_date date, created_at timestamptz, updated_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query select c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at
  from public.contacts c where c.owner_profile_id = v_owner_profile_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

create function public.get_my_contact(p_contact_id uuid)
returns table(id uuid, first_name text, last_name text, birth_date date, created_at timestamptz, updated_at timestamptz, methods jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query
  select c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at,
    coalesce((select jsonb_agg(jsonb_build_object('id', cm.id, 'type', cm.type, 'value', cm.value, 'is_primary', cm.is_primary, 'created_at', cm.created_at, 'updated_at', cm.updated_at) order by cm.type, cm.is_primary desc, cm.created_at, cm.id) from public.contact_methods cm where cm.contact_id = c.id), '[]'::jsonb)
  from public.contacts c where c.id = p_contact_id and c.owner_profile_id = v_owner_profile_id;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
end;
$$;

create function public.create_my_contact(p_first_name text, p_last_name text default null, p_birth_date date default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid; v_contact_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if btrim(coalesce(p_first_name, '')) = '' then raise exception 'Il nome del contatto e'' obbligatorio'; end if;
  insert into public.contacts(owner_profile_id, first_name, last_name, birth_date)
  values(v_owner_profile_id, btrim(p_first_name), nullif(btrim(coalesce(p_last_name, '')), ''), p_birth_date) returning id into v_contact_id;
  return v_contact_id;
end;
$$;

create function public.update_my_contact(p_contact_id uuid, p_first_name text, p_last_name text, p_birth_date date)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if btrim(coalesce(p_first_name, '')) = '' then raise exception 'Il nome del contatto e'' obbligatorio'; end if;
  update public.contacts set first_name = btrim(p_first_name), last_name = nullif(btrim(coalesce(p_last_name, '')), ''), birth_date = p_birth_date
  where id = p_contact_id and owner_profile_id = v_owner_profile_id;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
end;
$$;

create function public.delete_my_contact(p_contact_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  delete from public.contacts where id = p_contact_id and owner_profile_id = v_owner_profile_id;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
end;
$$;

create function public.add_my_contact_method(p_contact_id uuid, p_type text, p_value text, p_is_primary boolean default false)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid; v_type text := lower(btrim(p_type)); v_value text; v_is_primary boolean; v_method_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if coalesce(v_type, '') not in ('email', 'phone') then raise exception 'Tipo di recapito non valido'; end if;
  v_value := btrim(coalesce(p_value, '')); if v_value = '' then raise exception 'Il valore del recapito e'' obbligatorio'; end if;
  if v_type = 'email' then v_value := lower(v_value); end if;
  perform 1 from public.contacts c where c.id = p_contact_id and c.owner_profile_id = v_owner_profile_id for update;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
  v_is_primary := coalesce(p_is_primary, false) or not exists(select 1 from public.contact_methods cm where cm.contact_id = p_contact_id and cm.type = v_type);
  if v_is_primary then update public.contact_methods set is_primary = false where contact_id = p_contact_id and type = v_type; end if;
  insert into public.contact_methods(contact_id, type, value, is_primary) values(p_contact_id, v_type, v_value, v_is_primary) returning id into v_method_id;
  return v_method_id;
end;
$$;

create function public.update_my_contact_method(p_method_id uuid, p_type text, p_value text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid; v_contact_id uuid; v_is_primary boolean; v_type text := lower(btrim(p_type)); v_value text;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if coalesce(v_type, '') not in ('email', 'phone') then raise exception 'Tipo di recapito non valido'; end if;
  v_value := btrim(coalesce(p_value, '')); if v_value = '' then raise exception 'Il valore del recapito e'' obbligatorio'; end if;
  if v_type = 'email' then v_value := lower(v_value); end if;
  select cm.contact_id, cm.is_primary into v_contact_id, v_is_primary from public.contact_methods cm join public.contacts c on c.id = cm.contact_id where cm.id = p_method_id and c.owner_profile_id = v_owner_profile_id for update of c, cm;
  if v_contact_id is null then raise exception 'Recapito non trovato o non accessibile'; end if;
  if v_is_primary then update public.contact_methods set is_primary = false where contact_id = v_contact_id and type = v_type and id <> p_method_id; end if;
  update public.contact_methods set type = v_type, value = v_value where id = p_method_id and contact_id = v_contact_id;
end;
$$;

create function public.set_my_contact_method_primary(p_method_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid; v_contact_id uuid; v_type text;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select cm.contact_id, cm.type into v_contact_id, v_type from public.contact_methods cm join public.contacts c on c.id = cm.contact_id where cm.id = p_method_id and c.owner_profile_id = v_owner_profile_id for update of c, cm;
  if v_contact_id is null then raise exception 'Recapito non trovato o non accessibile'; end if;
  update public.contact_methods set is_primary = false where contact_id = v_contact_id and type = v_type;
  update public.contact_methods set is_primary = true where id = p_method_id and contact_id = v_contact_id;
end;
$$;

create function public.delete_my_contact_method(p_method_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid; v_contact_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select cm.contact_id into v_contact_id from public.contact_methods cm join public.contacts c on c.id = cm.contact_id where cm.id = p_method_id and c.owner_profile_id = v_owner_profile_id for update of c, cm;
  if v_contact_id is null then raise exception 'Recapito non trovato o non accessibile'; end if;
  delete from public.contact_methods where id = p_method_id and contact_id = v_contact_id;
end;
$$;

revoke all on public.contacts, public.contact_methods from public, authenticated;
revoke all on function public.set_personal_contact_updated_at() from public;
revoke all on function public.get_my_contacts() from public;
revoke all on function public.get_my_contact(uuid) from public;
revoke all on function public.create_my_contact(text, text, date) from public;
revoke all on function public.update_my_contact(uuid, text, text, date) from public;
revoke all on function public.delete_my_contact(uuid) from public;
revoke all on function public.add_my_contact_method(uuid, text, text, boolean) from public;
revoke all on function public.update_my_contact_method(uuid, text, text) from public;
revoke all on function public.set_my_contact_method_primary(uuid) from public;
revoke all on function public.delete_my_contact_method(uuid) from public;
grant execute on function public.get_my_contacts() to authenticated;
grant execute on function public.get_my_contact(uuid) to authenticated;
grant execute on function public.create_my_contact(text, text, date) to authenticated;
grant execute on function public.update_my_contact(uuid, text, text, date) to authenticated;
grant execute on function public.delete_my_contact(uuid) to authenticated;

grant execute on function public.add_my_contact_method(uuid, text, text, boolean) to authenticated;
grant execute on function public.update_my_contact_method(uuid, text, text) to authenticated;
grant execute on function public.set_my_contact_method_primary(uuid) to authenticated;
grant execute on function public.delete_my_contact_method(uuid) to authenticated;

-- =============================================================================
-- 10. Contatti personali come partecipanti delle Aree
-- =============================================================================

-- Relazione privata: non espone al resto dell'Area il proprietario del Contatto.
create table public.contact_participant_profiles (
  contact_id uuid primary key references public.contacts(id) on delete restrict,
  profile_id uuid not null unique references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table public.contact_participant_profiles enable row level security;
alter table public.contact_participant_profiles no force row level security;

create function public.sync_contact_participant_profile()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.profiles p
  set first_name = new.first_name,
      last_name = new.last_name
  from public.contact_participant_profiles cpp
  where cpp.contact_id = new.id and cpp.profile_id = p.id;
  return new;
end;
$$;

create trigger contacts_sync_participant_profile
  after update of first_name, last_name on public.contacts
  for each row execute function public.sync_contact_participant_profile();

create or replace function public.update_area_member(
  p_area_id uuid, p_profile_id uuid, p_first_name text, p_last_name text, p_birth_date date
)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;

  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;

  if not exists (
    select 1 from public.area_memberships
    where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin'
  ) then raise exception 'permission denied: solo un admin dell''Area puo'' modificare i partecipanti'; end if;

  select p.user_id into v_target_user_id
  from public.area_memberships am
  join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id and am.profile_id = p_profile_id
  for update of am, p;
  if not found then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;

  if exists (
    select 1 from public.contact_participant_profiles where profile_id = p_profile_id
  ) then raise exception 'Impossibile modificare questo partecipante: i dati provengono da un Contatto personale'; end if;

  if v_target_user_id is not null then
    raise exception 'Impossibile modificare un profilo collegato a un account utente';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then raise exception 'Il nome e'' obbligatorio'; end if;
  update public.profiles
  set first_name = btrim(p_first_name),
      last_name = nullif(btrim(coalesce(p_last_name, '')), '')
  where id = p_profile_id;
end;
$$;

create function public.get_my_contacts_for_area(p_area_id uuid)
returns table(id uuid, first_name text, last_name text, birth_date date, is_already_participant boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_owner_profile_id and am.role = 'admin'
  ) then raise exception 'permission denied: solo un admin dell''Area puo'' aggiungere partecipanti'; end if;
  return query
  select c.id, c.first_name, c.last_name, c.birth_date,
    exists (
      select 1 from public.contact_participant_profiles cpp
      join public.area_memberships am on am.profile_id = cpp.profile_id
      where cpp.contact_id = c.id and am.area_id = p_area_id
    )
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

create function public.add_my_contact_to_area(p_area_id uuid, p_contact_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_owner_profile_id uuid;
  v_contact_first_name text;
  v_contact_last_name text;
  v_participant_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_owner_profile_id and am.role = 'admin'
  ) then raise exception 'permission denied: solo un admin dell''Area puo'' aggiungere partecipanti'; end if;
  select c.first_name, c.last_name into v_contact_first_name, v_contact_last_name
  from public.contacts c
  where c.id = p_contact_id and c.owner_profile_id = v_owner_profile_id
  for update;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
  select cpp.profile_id into v_participant_profile_id
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
    perform 1 from public.profiles p
    where p.id = v_participant_profile_id and p.user_id is null
    for update;
    if not found then raise exception 'Associazione Contatto/Partecipante non valida'; end if;
    update public.profiles
    set first_name = v_contact_first_name, last_name = v_contact_last_name
    where id = v_participant_profile_id;
  end if;
  if exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_participant_profile_id
  ) then raise exception 'Il Contatto partecipa gia'' a questa Area'; end if;
  insert into public.area_memberships(area_id, profile_id, role)
  values (p_area_id, v_participant_profile_id, 'managed');
end;
$$;

create or replace function public.delete_my_contact(p_contact_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid; v_participant_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  perform 1 from public.contacts c
  where c.id = p_contact_id and c.owner_profile_id = v_owner_profile_id
  for update;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
  select cpp.profile_id into v_participant_profile_id
  from public.contact_participant_profiles cpp
  where cpp.contact_id = p_contact_id
  for update;
  if v_participant_profile_id is not null then
    perform 1 from public.profiles p
    where p.id = v_participant_profile_id and p.user_id is null
    for update;
    if not found then raise exception 'Associazione Contatto/Partecipante non valida'; end if;
    if exists (
      select 1 from public.area_memberships am where am.profile_id = v_participant_profile_id
    ) then raise exception 'Impossibile eliminare il contatto: rimuovilo prima dalle Aree in cui partecipa'; end if;
    if exists (
      select 1 from public.areas ar where ar.created_by = v_participant_profile_id
    ) or exists (
      select 1 from public.contacts c where c.owner_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.area_activities a
      where a.created_by_profile_id = v_participant_profile_id or a.completed_by_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.area_events e where e.created_by_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.activity_assignees aa where aa.assigned_by_profile_id = v_participant_profile_id
    ) or exists (
      select 1 from public.event_participants ep where ep.added_by_profile_id = v_participant_profile_id
    ) then raise exception 'Impossibile eliminare il contatto: il partecipante tecnico ha dipendenze inattese'; end if;
    delete from public.contact_participant_profiles
    where contact_id = p_contact_id and profile_id = v_participant_profile_id;
    delete from public.profiles
    where id = v_participant_profile_id and user_id is null;
    if not found then raise exception 'Associazione Contatto/Partecipante non valida'; end if;
  end if;
  delete from public.contacts
  where id = p_contact_id and owner_profile_id = v_owner_profile_id;
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

-- =============================================================================
-- 11. Elenco partecipanti Area senza esporre la rubrica privata
-- =============================================================================

create function public.get_area_participants(p_area_id uuid)
returns table(
  profile_id uuid,
  first_name text,
  last_name text,
  role text,
  is_personal_contact_participant boolean
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role in ('admin', 'member')
  ) then raise exception 'permission denied: partecipante non autorizzato per questa Area'; end if;
  return query
  select am.profile_id, p.first_name, p.last_name, am.role,
    exists (
      select 1 from public.contact_participant_profiles cpp where cpp.profile_id = am.profile_id
    )
  from public.area_memberships am
  join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id
  order by lower(p.first_name), lower(coalesce(p.last_name, '')), am.profile_id;
end;
$$;

revoke all on function public.get_area_participants(uuid) from public;
grant execute on function public.get_area_participants(uuid) to authenticated;

-- =============================================================================
-- 12. Liste condivise per Area
-- =============================================================================

create table public.area_lists (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(id) on delete cascade,
  title text not null check (char_length(btrim(title)) > 0),
  description text,
  visibility text not null default 'area' check (visibility in ('area', 'private', 'creator_participants')),
  created_by_profile_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, area_id)
);
create table public.area_list_participants (
  list_id uuid not null, area_id uuid not null, profile_id uuid not null,
  added_at timestamptz not null default now(),
  added_by_profile_id uuid not null references public.profiles(id),
  primary key (list_id, profile_id),
  foreign key (list_id, area_id) references public.area_lists(id, area_id) on delete cascade,
  foreign key (area_id, profile_id) references public.area_memberships(area_id, profile_id) on delete cascade
);
create table public.area_list_items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.area_lists(id) on delete cascade,
  text text not null check (char_length(btrim(text)) > 0),
  status text not null default 'open' check (status in ('open', 'completed')),
  position integer not null default 0 check (position >= 0),
  created_by_profile_id uuid not null references public.profiles(id),
  completed_by_profile_id uuid references public.profiles(id),
  created_at timestamptz not null default now(), completed_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint area_list_items_completion_check check (
    (status = 'completed' and completed_at is not null and completed_by_profile_id is not null)
    or (status = 'open' and completed_at is null and completed_by_profile_id is null)
  )
);
create index area_lists_area_created_idx on public.area_lists(area_id, created_at desc);
create index area_list_participants_profile_idx on public.area_list_participants(area_id, profile_id, list_id);
create index area_list_items_list_position_idx on public.area_list_items(list_id, position, created_at, id);
alter table public.area_lists enable row level security;
alter table public.area_list_participants enable row level security;
alter table public.area_list_items enable row level security;
alter table public.area_lists no force row level security;
alter table public.area_list_participants no force row level security;
alter table public.area_list_items no force row level security;

create function public.set_area_list_updated_at() returns trigger language plpgsql set search_path = public, pg_temp as $$ begin new.updated_at = now(); return new; end; $$;
create trigger area_lists_set_updated_at before update on public.area_lists for each row execute function public.set_area_list_updated_at();
create trigger area_list_items_set_updated_at before update on public.area_list_items for each row execute function public.set_area_list_updated_at();

create function public.assert_area_list_participant_visibility()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_list_id uuid; v_visibility text; v_participant_count integer;
begin
  if tg_table_name = 'area_lists' then
    if tg_op = 'DELETE' then v_list_id := old.id; else v_list_id := new.id; end if;
  else
    if tg_op = 'DELETE' then v_list_id := old.list_id; else v_list_id := new.list_id; end if;
  end if;
  select l.visibility into v_visibility from public.area_lists l where l.id = v_list_id;
  if not found then return null; end if;
  select count(*) into v_participant_count from public.area_list_participants alp where alp.list_id = v_list_id;
  if (v_visibility = 'private' and v_participant_count <> 0) or (v_visibility = 'creator_participants' and v_participant_count = 0) then
    raise exception 'Visibilita e partecipanti della Lista non coerenti';
  end if;
  return null;
end;
$$;
create constraint trigger area_lists_visibility_participants_check after insert or update of visibility on public.area_lists deferrable initially deferred for each row execute function public.assert_area_list_participant_visibility();
create constraint trigger area_list_participants_visibility_check after insert or delete or update of list_id, area_id on public.area_list_participants deferrable initially deferred for each row execute function public.assert_area_list_participant_visibility();

create function public.current_area_list_role(p_area_id uuid)
returns table(profile_id uuid, role text) language sql security definer stable set search_path = public, pg_temp as $$
  select am.profile_id, am.role from public.area_memberships am join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id and p.user_id = auth.uid() and am.role in ('admin', 'member');
$$;

create function public.get_area_lists(p_area_id uuid)
returns table(id uuid, title text, description text, visibility text, created_by_profile_id uuid, created_at timestamptz, updated_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  return query select l.id,l.title,l.description,l.visibility,l.created_by_profile_id,l.created_at,l.updated_at
  from public.area_lists l where l.area_id=p_area_id and (l.visibility='area' or l.created_by_profile_id=v_profile_id or (l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=v_profile_id)))
  order by l.created_at desc,l.id;
end;
$$;

create function public.get_area_list(p_area_id uuid, p_list_id uuid)
returns table(id uuid, title text, description text, visibility text, created_by_profile_id uuid, created_at timestamptz, updated_at timestamptz, participant_profile_ids uuid[], items jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id);
  if v_profile_id is null then raise exception 'permission denied'; end if;
  return query select l.id,l.title,l.description,l.visibility,l.created_by_profile_id,l.created_at,l.updated_at,
    case when l.created_by_profile_id=v_profile_id then array(select alp.profile_id from public.area_list_participants alp where alp.list_id=l.id order by alp.added_at,alp.profile_id) end,
    coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'text',i.text,'status',i.status,'position',i.position,'created_by_profile_id',i.created_by_profile_id,'completed_by_profile_id',i.completed_by_profile_id,'created_at',i.created_at,'completed_at',i.completed_at,'updated_at',i.updated_at) order by i.position,i.created_at,i.id) from public.area_list_items i where i.list_id=l.id),'[]'::jsonb)
  from public.area_lists l where l.id=p_list_id and l.area_id=p_area_id and (l.visibility='area' or l.created_by_profile_id=v_profile_id or (l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=v_profile_id)));
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
end;
$$;

create function public.create_area_list(p_area_id uuid,p_title text,p_description text,p_visibility text,p_participant_profile_ids uuid[])
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_list_id uuid; v_participant_ids uuid[]:=coalesce(p_participant_profile_ids,'{}');
begin
  perform 1 from public.areas where id=p_area_id for update; if not found then raise exception 'Area non trovata'; end if;
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id); if v_profile_id is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title,''))='' or p_visibility not in ('area','private','creator_participants') or exists(select 1 from unnest(v_participant_ids) x where x is null) or (p_visibility='private' and cardinality(v_participant_ids)<>0) or (p_visibility='creator_participants' and cardinality(v_participant_ids)=0) then raise exception 'Dati Lista non validi'; end if;
  if exists(select 1 from (select distinct unnest(v_participant_ids) profile_id) ids left join public.area_memberships am on am.area_id=p_area_id and am.profile_id=ids.profile_id where am.profile_id is null) then raise exception 'Partecipante non appartenente all''Area'; end if;
  insert into public.area_lists(area_id,title,description,visibility,created_by_profile_id) values(p_area_id,btrim(p_title),nullif(btrim(coalesce(p_description,'')),''),p_visibility,v_profile_id) returning id into v_list_id;
  insert into public.area_list_participants(list_id,area_id,profile_id,added_by_profile_id) select v_list_id,p_area_id,ids.profile_id,v_profile_id from(select distinct unnest(v_participant_ids) profile_id) ids;
  return v_list_id;
end;
$$;

create function public.update_area_list(p_area_id uuid,p_list_id uuid,p_title text,p_description text,p_visibility text,p_participant_profile_ids uuid[])
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_creator_id uuid; v_participant_ids uuid[]:=coalesce(p_participant_profile_ids,'{}');
begin
  perform 1 from public.areas where id=p_area_id for update; if not found then raise exception 'Area non trovata'; end if;
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id); if v_profile_id is null then raise exception 'permission denied'; end if;
  select l.created_by_profile_id into v_creator_id from public.area_lists l where l.id=p_list_id and l.area_id=p_area_id for update; if not found then raise exception 'Lista non trovata'; end if;
  if v_creator_id is distinct from v_profile_id then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title,''))='' or p_visibility not in ('area','private','creator_participants') or exists(select 1 from unnest(v_participant_ids) x where x is null) or (p_visibility='private' and cardinality(v_participant_ids)<>0) or (p_visibility='creator_participants' and cardinality(v_participant_ids)=0) then raise exception 'Dati Lista non validi'; end if;
  if exists(select 1 from (select distinct unnest(v_participant_ids) profile_id) ids left join public.area_memberships am on am.area_id=p_area_id and am.profile_id=ids.profile_id where am.profile_id is null) then raise exception 'Partecipante non appartenente all''Area'; end if;
  delete from public.area_list_participants where list_id=p_list_id and area_id=p_area_id;
  insert into public.area_list_participants(list_id,area_id,profile_id,added_by_profile_id) select p_list_id,p_area_id,ids.profile_id,v_profile_id from(select distinct unnest(v_participant_ids) profile_id) ids;
  update public.area_lists set title=btrim(p_title),description=nullif(btrim(coalesce(p_description,'')),''),visibility=p_visibility where id=p_list_id and area_id=p_area_id;
end;
$$;

create function public.delete_area_list(p_area_id uuid,p_list_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id); if v_profile_id is null then raise exception 'permission denied'; end if;
  delete from public.area_lists where id=p_list_id and area_id=p_area_id and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Lista non trovata o non eliminabile'; end if;
end;
$$;

create function public.add_area_list_item(p_area_id uuid,p_list_id uuid,p_text text,p_position integer default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_item_id uuid; v_position integer;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id); if v_profile_id is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_text,''))='' or (p_position is not null and p_position<0) then raise exception 'Dati elemento Lista non validi'; end if;
  perform 1 from public.area_lists l where l.id=p_list_id and l.area_id=p_area_id and (l.visibility='area' or l.created_by_profile_id=v_profile_id or (l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=v_profile_id))) for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  if p_position is null then select coalesce(max(i.position)+1,0) into v_position from public.area_list_items i where i.list_id=p_list_id; else v_position:=p_position; end if;
  insert into public.area_list_items(list_id,text,position,created_by_profile_id) values(p_list_id,btrim(p_text),v_position,v_profile_id) returning id into v_item_id;
  return v_item_id;
end;
$$;

create function public.update_area_list_item(p_area_id uuid,p_list_id uuid,p_item_id uuid,p_text text,p_position integer default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_list_creator_id uuid; v_item_creator_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id); if v_profile_id is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_text,''))='' or (p_position is not null and p_position<0) then raise exception 'Dati elemento Lista non validi'; end if;
  select l.created_by_profile_id into v_list_creator_id from public.area_lists l where l.id=p_list_id and l.area_id=p_area_id and (l.visibility='area' or l.created_by_profile_id=v_profile_id or (l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=v_profile_id))) for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  select i.created_by_profile_id into v_item_creator_id from public.area_list_items i where i.id=p_item_id and i.list_id=p_list_id for update;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
  if v_item_creator_id is distinct from v_profile_id and v_list_creator_id is distinct from v_profile_id then raise exception 'permission denied'; end if;
  update public.area_list_items set text=btrim(p_text),position=coalesce(p_position,position) where id=p_item_id and list_id=p_list_id;
end;
$$;

create function public.set_area_list_item_status(p_area_id uuid,p_list_id uuid,p_item_id uuid,p_status text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id); if v_profile_id is null or p_status not in ('open','completed') then raise exception 'permission denied'; end if;
  perform 1 from public.area_lists l where l.id=p_list_id and l.area_id=p_area_id and (l.visibility='area' or l.created_by_profile_id=v_profile_id or (l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=v_profile_id))) for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  update public.area_list_items set status=p_status,completed_at=case when p_status='completed' then now() else null end,completed_by_profile_id=case when p_status='completed' then v_profile_id else null end where id=p_item_id and list_id=p_list_id;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
end;
$$;

create function public.delete_area_list_item(p_area_id uuid,p_list_id uuid,p_item_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_list_creator_id uuid; v_item_creator_id uuid;
begin
  select profile_id into v_profile_id from public.current_area_list_role(p_area_id); if v_profile_id is null then raise exception 'permission denied'; end if;
  select l.created_by_profile_id into v_list_creator_id from public.area_lists l where l.id=p_list_id and l.area_id=p_area_id and (l.visibility='area' or l.created_by_profile_id=v_profile_id or (l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=v_profile_id))) for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  select i.created_by_profile_id into v_item_creator_id from public.area_list_items i where i.id=p_item_id and i.list_id=p_list_id for update;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
  if v_item_creator_id is distinct from v_profile_id and v_list_creator_id is distinct from v_profile_id then raise exception 'permission denied'; end if;
  delete from public.area_list_items where id=p_item_id and list_id=p_list_id;
end;
$$;

create or replace function public.remove_area_member(p_area_id uuid,p_profile_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_target_role text;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id=auth.uid(); if v_caller_profile_id is null then raise exception 'Utente non autorizzato: profilo non trovato'; end if;
  perform 1 from public.areas where id=p_area_id for update; if not found then raise exception 'Area non trovata'; end if;
  if not exists(select 1 from public.area_memberships am where am.area_id=p_area_id and am.profile_id=v_caller_profile_id and am.role='admin') then raise exception 'Utente non autorizzato: solo un admin dell''Area puÃ² rimuovere membri'; end if;
  select am.role into v_target_role from public.area_memberships am where am.area_id=p_area_id and am.profile_id=p_profile_id for update; if not found then raise exception 'Membership del membro non trovata in questa Area'; end if;
  if v_target_role='admin' and not exists(select 1 from public.area_memberships am where am.area_id=p_area_id and am.role='admin' and am.profile_id<>p_profile_id) then raise exception 'Impossibile rimuovere l''ultimo amministratore dell''Area'; end if;
  perform 1 from public.area_activities a where a.area_id=p_area_id and a.created_by_profile_id=p_profile_id for update; if found then raise exception 'Impossibile rimuovere il membro: Ã¨ creatore di attivitÃ  in questa Area'; end if;
  perform 1 from public.area_events e where e.area_id=p_area_id and e.created_by_profile_id=p_profile_id for update; if found then raise exception 'Impossibile rimuovere il membro: Ã¨ creatore di eventi in questa Area'; end if;
  perform 1 from public.area_lists l where l.area_id=p_area_id and l.created_by_profile_id=p_profile_id for update; if found then raise exception 'Impossibile rimuovere il membro: Ã¨ creatore di Liste in questa Area'; end if;
  perform 1 from public.area_activities a where a.area_id=p_area_id and a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=p_profile_id) and not exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id<>p_profile_id) for update; if found then raise exception 'Impossibile rimuovere il membro: ultimo assegnatario di attivitÃ  selettiva'; end if;
  perform 1 from public.area_events e where e.area_id=p_area_id and e.visibility='creator_participants' and exists(select 1 from public.event_participants ep where ep.event_id=e.id and ep.profile_id=p_profile_id) and not exists(select 1 from public.event_participants ep where ep.event_id=e.id and ep.profile_id<>p_profile_id) for update; if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di evento selettivo'; end if;
  perform 1 from public.area_lists l where l.area_id=p_area_id and l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=p_profile_id) and not exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id<>p_profile_id) for update; if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di Lista selettiva'; end if;
  delete from public.area_memberships where area_id=p_area_id and profile_id=p_profile_id;
end;
$$;

revoke all on public.area_lists, public.area_list_participants, public.area_list_items from public, authenticated;
revoke all on function public.set_area_list_updated_at() from public;
revoke all on function public.assert_area_list_participant_visibility() from public;
revoke all on function public.current_area_list_role(uuid) from public;
revoke all on function public.get_area_lists(uuid) from public;
revoke all on function public.get_area_list(uuid,uuid) from public;
revoke all on function public.create_area_list(uuid,text,text,text,uuid[]) from public;
revoke all on function public.update_area_list(uuid,uuid,text,text,text,uuid[]) from public;
revoke all on function public.delete_area_list(uuid,uuid) from public;
revoke all on function public.add_area_list_item(uuid,uuid,text,integer) from public;
revoke all on function public.update_area_list_item(uuid,uuid,uuid,text,integer) from public;
revoke all on function public.set_area_list_item_status(uuid,uuid,uuid,text) from public;
revoke all on function public.delete_area_list_item(uuid,uuid,uuid) from public;
revoke all on function public.remove_area_member(uuid,uuid) from public;
grant execute on function public.get_area_lists(uuid) to authenticated;
grant execute on function public.get_area_list(uuid,uuid) to authenticated;
grant execute on function public.create_area_list(uuid,text,text,text,uuid[]) to authenticated;
grant execute on function public.update_area_list(uuid,uuid,text,text,text,uuid[]) to authenticated;
grant execute on function public.delete_area_list(uuid,uuid) to authenticated;
grant execute on function public.add_area_list_item(uuid,uuid,text,integer) to authenticated;
grant execute on function public.update_area_list_item(uuid,uuid,uuid,text,integer) to authenticated;
grant execute on function public.set_area_list_item_status(uuid,uuid,uuid,text) to authenticated;
grant execute on function public.delete_area_list_item(uuid,uuid,uuid) to authenticated;
grant execute on function public.remove_area_member(uuid,uuid) to authenticated;

-- =============================================================================
-- 13. Liste visibili dell'utente su tutte le Aree
-- =============================================================================

create function public.get_my_visible_lists()
returns table(
  list_id uuid,
  area_id uuid,
  area_name text,
  title text,
  description text,
  visibility text,
  created_by_profile_id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  total_item_count bigint,
  completed_item_count bigint
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'permission denied'; end if;
  return query
  select l.id, ar.id, ar.name, l.title, l.description, l.visibility,
         l.created_by_profile_id, l.created_at, l.updated_at,
         (select count(*) from public.area_list_items i where i.list_id = l.id),
         (select count(*) from public.area_list_items i where i.list_id = l.id and i.status = 'completed')
  from public.area_memberships am
  join public.areas ar on ar.id = am.area_id
  join public.area_lists l on l.area_id = am.area_id
  where am.profile_id = v_profile_id and am.role in ('admin', 'member')
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (l.visibility = 'creator_participants' and exists (
        select 1 from public.area_list_participants alp
        where alp.list_id = l.id and alp.profile_id = v_profile_id
      ))
    )
  order by l.updated_at desc, l.created_at desc, l.id;
end;
$$;

revoke all on function public.get_my_visible_lists() from public;
grant execute on function public.get_my_visible_lists() to authenticated;

-- =============================================================================
-- 14. Inviti alle Aree - fase 1
-- =============================================================================

create table public.area_invites (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(id) on delete cascade,
  recipient_email text not null check (recipient_email = lower(btrim(recipient_email)) and recipient_email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'),
  first_name text check (first_name is null or (first_name = btrim(first_name) and char_length(first_name) > 0)),
  last_name text check (last_name is null or (last_name = btrim(last_name) and char_length(last_name) > 0)),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'revoked', 'expired')),
  expires_at timestamptz not null,
  created_by_profile_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  accepted_by_profile_id uuid references public.profiles(id),
  revoked_by_profile_id uuid references public.profiles(id),
  revoked_at timestamptz,
  constraint area_invites_expiration_check check (expires_at > created_at),
  constraint area_invites_state_check check (
    (status = 'pending' and responded_at is null and accepted_by_profile_id is null and revoked_by_profile_id is null and revoked_at is null)
    or (status = 'accepted' and responded_at is not null and accepted_by_profile_id is not null and revoked_by_profile_id is null and revoked_at is null)
    or (status = 'declined' and responded_at is not null and accepted_by_profile_id is null and revoked_by_profile_id is null and revoked_at is null)
    or (status = 'revoked' and responded_at is null and accepted_by_profile_id is null and revoked_by_profile_id is not null and revoked_at is not null)
    or (status = 'expired' and responded_at is null and accepted_by_profile_id is null and revoked_by_profile_id is null and revoked_at is null)
  )
);
create unique index area_invites_one_pending_email_per_area_idx on public.area_invites(area_id, recipient_email) where status = 'pending';
create index area_invites_recipient_status_idx on public.area_invites(recipient_email, status, expires_at, created_at desc);
create index area_invites_area_status_idx on public.area_invites(area_id, status, created_at desc);
alter table public.area_invites enable row level security;
alter table public.area_invites no force row level security;
revoke all on public.area_invites from public, authenticated;

create function public.create_area_invite(p_area_id uuid, p_email text, p_first_name text default null, p_last_name text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_email text := lower(btrim(coalesce(p_email, ''))); v_invite_id uuid;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  if not exists (select 1 from public.area_memberships am where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin') then raise exception 'permission denied'; end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'Email non valida'; end if;
  update public.area_invites set status = 'expired' where area_id = p_area_id and recipient_email = v_email and status = 'pending' and expires_at <= now();
  if exists (select 1 from auth.users u join public.profiles p on p.user_id = u.id join public.area_memberships am on am.profile_id = p.id where lower(btrim(u.email)) = v_email and am.area_id = p_area_id and am.role in ('admin', 'member')) then raise exception 'Impossibile creare l''invito per questo indirizzo'; end if;
  if exists (select 1 from public.area_invites ai where ai.area_id = p_area_id and ai.recipient_email = v_email and ai.status = 'pending') then raise exception 'Esiste gia'' un invito in attesa per questo indirizzo'; end if;
  insert into public.area_invites(area_id, recipient_email, first_name, last_name, expires_at, created_by_profile_id)
  values (p_area_id, v_email, nullif(btrim(coalesce(p_first_name, '')), ''), nullif(btrim(coalesce(p_last_name, '')), ''), now() + interval '7 days', v_caller_profile_id)
  returning id into v_invite_id;
  return v_invite_id;
end;
$$;

create function public.get_area_invites(p_area_id uuid)
returns table(invite_id uuid, recipient_email text, first_name text, last_name text, status text, expires_at timestamptz, created_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  if not exists (select 1 from public.area_memberships am where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin') then raise exception 'permission denied'; end if;
  return query select ai.id, ai.recipient_email, ai.first_name, ai.last_name, case when ai.status = 'pending' and ai.expires_at <= now() then 'expired' else ai.status end, ai.expires_at, ai.created_at from public.area_invites ai where ai.area_id = p_area_id order by ai.created_at desc, ai.id;
end;
$$;

create function public.revoke_area_invite(p_area_id uuid, p_invite_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_status text;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  if not exists (select 1 from public.area_memberships am where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin') then raise exception 'permission denied'; end if;
  update public.area_invites set status = 'expired' where id = p_invite_id and area_id = p_area_id and status = 'pending' and expires_at <= now();
  select ai.status into v_status from public.area_invites ai where ai.id = p_invite_id and ai.area_id = p_area_id for update;
  if not found then raise exception 'Invito non trovato in questa Area'; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' piu'' revocabile'; end if;
  update public.area_invites set status = 'revoked', revoked_at = now(), revoked_by_profile_id = v_caller_profile_id where id = p_invite_id and area_id = p_area_id;
end;
$$;

create function public.get_my_area_invites()
returns table(invite_id uuid, area_id uuid, area_name text, status text, expires_at timestamptz, created_at timestamptz, inviter_first_name text, inviter_last_name text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_email text;
begin
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then raise exception 'Email dell''account non verificata'; end if;
  return query select ai.id, ai.area_id, a.name, case when ai.status = 'pending' and ai.expires_at <= now() then 'expired' else ai.status end, ai.expires_at, ai.created_at, inviter.first_name, inviter.last_name
  from public.area_invites ai join public.areas a on a.id = ai.area_id join public.profiles inviter on inviter.id = ai.created_by_profile_id
  where ai.recipient_email = v_email
  order by case when ai.status = 'pending' and ai.expires_at > now() then 0 else 1 end, ai.created_at desc, ai.id;
end;
$$;

create function public.accept_area_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_email text; v_area_id uuid; v_recipient_email text; v_status text; v_expires_at timestamptz; v_accepted_by_profile_id uuid; v_membership_role text;
begin
  select p.id, lower(btrim(u.email)) into v_caller_profile_id, v_email from auth.users u join public.profiles p on p.user_id = u.id where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_caller_profile_id is null or v_email is null then raise exception 'Email dell''account non verificata o profilo non trovato'; end if;
  select ai.area_id into v_area_id from public.area_invites ai where ai.id = p_invite_id;
  if v_area_id is null then raise exception 'Invito non trovato'; end if;
  perform 1 from public.areas where id = v_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  update public.area_invites set status = 'expired' where id = p_invite_id and area_id = v_area_id and status = 'pending' and expires_at <= now();
  select ai.recipient_email, ai.status, ai.expires_at, ai.accepted_by_profile_id into v_recipient_email, v_status, v_expires_at, v_accepted_by_profile_id from public.area_invites ai where ai.id = p_invite_id and ai.area_id = v_area_id for update;
  if not found then raise exception 'Invito non trovato'; end if;
  if v_recipient_email <> v_email then raise exception 'permission denied'; end if;
  if v_status = 'accepted' and v_accepted_by_profile_id = v_caller_profile_id then return; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' accettabile'; end if;
  if v_expires_at <= now() then raise exception 'Invito scaduto'; end if;
  perform 1 from public.profiles p where p.id = v_caller_profile_id for update;
  if not found then raise exception 'Profilo non trovato'; end if;
  select am.role into v_membership_role from public.area_memberships am where am.area_id = v_area_id and am.profile_id = v_caller_profile_id for update;
  if v_membership_role is null then insert into public.area_memberships(area_id, profile_id, role) values (v_area_id, v_caller_profile_id, 'member');
  elsif v_membership_role = 'managed' then update public.area_memberships set role = 'member' where area_id = v_area_id and profile_id = v_caller_profile_id;
  end if;
  update public.area_invites set status = 'accepted', responded_at = now(), accepted_by_profile_id = v_caller_profile_id where id = p_invite_id and area_id = v_area_id;
end;
$$;

create function public.decline_area_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_email text; v_area_id uuid; v_recipient_email text; v_status text;
begin
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then raise exception 'Email dell''account non verificata'; end if;
  select ai.area_id into v_area_id from public.area_invites ai where ai.id = p_invite_id;
  if v_area_id is null then raise exception 'Invito non trovato'; end if;
  perform 1 from public.areas where id = v_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  update public.area_invites set status = 'expired' where id = p_invite_id and area_id = v_area_id and status = 'pending' and expires_at <= now();
  select ai.recipient_email, ai.status into v_recipient_email, v_status from public.area_invites ai where ai.id = p_invite_id and ai.area_id = v_area_id for update;
  if not found then raise exception 'Invito non trovato'; end if;
  if v_recipient_email <> v_email then raise exception 'permission denied'; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' rifiutabile'; end if;
  update public.area_invites set status = 'declined', responded_at = now() where id = p_invite_id and area_id = v_area_id;
end;
$$;

revoke all on function public.create_area_invite(uuid, text, text, text) from public;
revoke all on function public.get_area_invites(uuid) from public;
revoke all on function public.revoke_area_invite(uuid, uuid) from public;
revoke all on function public.get_my_area_invites() from public;
revoke all on function public.accept_area_invite(uuid) from public;
revoke all on function public.decline_area_invite(uuid) from public;
grant execute on function public.create_area_invite(uuid, text, text, text) to authenticated;
grant execute on function public.get_area_invites(uuid) to authenticated;
grant execute on function public.revoke_area_invite(uuid, uuid) to authenticated;
grant execute on function public.get_my_area_invites() to authenticated;
grant execute on function public.accept_area_invite(uuid) to authenticated;
grant execute on function public.decline_area_invite(uuid) to authenticated;

-- =============================================================================
-- 15. Inviti Area — collegamento esplicito di partecipante managed (Fase 2)
-- =============================================================================
-- Stato finale applicato dalla migration 2026-09-07_area_invite_managed_link.sql.
-- Il riferimento e' nullo per un invito normale; quando valorizzato e' valido
-- soltanto finche' identifica una membership della stessa Area. Le RPC Fase 2
-- lo verificano nuovamente sotto lock e lo azzerano quando la membership T
-- viene convertita/rimossa, evitando un successivo downgrade a invito normale.
alter table public.area_invites
  add column target_managed_profile_id uuid;

alter table public.area_invites
  add constraint area_invites_target_managed_profile_fkey
    foreign key (target_managed_profile_id)
    references public.profiles(id) on delete restrict,
  add constraint area_invites_target_managed_membership_fkey
    foreign key (area_id, target_managed_profile_id)
    references public.area_memberships(area_id, profile_id) on delete restrict;

create index area_invites_target_managed_pending_idx
  on public.area_invites(area_id, target_managed_profile_id)
  where status = 'pending' and target_managed_profile_id is not null;

-- La definizione finale delle RPC e' quella completa nella migration Fase 2:
--   create_area_invite(uuid,text,text,text,uuid default null)
--   get_area_invites(uuid) -> include flag/nome pubblico del target
--   get_my_area_invites() -> include flag/nome pubblico del target
--   accept_area_invite(uuid) -> migrazione T -> A limitata all'Area
--   remove_area_member(uuid,uuid) -> revoca e scollega inviti target pending.
-- Tutte sono SECURITY DEFINER con search_path public, pg_temp; l'accesso alle
-- tabelle resta RPC-only e EXECUTE e' riservato ad authenticated.
drop function public.create_area_invite(uuid, text, text, text);

create function public.create_area_invite(
  p_area_id uuid,
  p_email text,
  p_first_name text default null,
  p_last_name text default null,
  p_target_managed_profile_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_invite_id uuid;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Utente non autorizzato';
  end if;

  perform 1 from public.areas where id = p_area_id for update;
  if not found then
    raise exception 'Area non trovata';
  end if;

  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'permission denied';
  end if;

  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Email non valida';
  end if;

  -- Il target e' sempre selezionato esplicitamente dall'admin: non esiste
  -- alcun confronto automatico tra email, nomi o Contatti personali.
  if p_target_managed_profile_id is not null then
    perform 1
    from public.area_memberships am
    join public.profiles target_profile on target_profile.id = am.profile_id
    where am.area_id = p_area_id
      and am.profile_id = p_target_managed_profile_id
      and am.role = 'managed'
      and target_profile.user_id is null
    for update of am, target_profile;

    if not found then
      raise exception 'Il partecipante selezionato non e'' piu'' un profilo managed disponibile in questa Area';
    end if;
  end if;

  update public.area_invites
  set status = 'expired'
  where area_id = p_area_id
    and recipient_email = v_email
    and status = 'pending'
    and expires_at <= now();

  if exists (
    select 1
    from auth.users u
    join public.profiles p on p.user_id = u.id
    join public.area_memberships am on am.profile_id = p.id
    where lower(btrim(u.email)) = v_email
      and am.area_id = p_area_id
      and am.role in ('admin', 'member')
  ) then
    raise exception 'Impossibile creare l''invito per questo indirizzo';
  end if;

  if exists (
    select 1 from public.area_invites ai
    where ai.area_id = p_area_id
      and ai.recipient_email = v_email
      and ai.status = 'pending'
  ) then
    raise exception 'Esiste gia'' un invito in attesa per questo indirizzo';
  end if;

  insert into public.area_invites(
    area_id, recipient_email, first_name, last_name, expires_at,
    created_by_profile_id, target_managed_profile_id
  )
  values (
    p_area_id, v_email,
    nullif(btrim(coalesce(p_first_name, '')), ''),
    nullif(btrim(coalesce(p_last_name, '')), ''),
    now() + interval '7 days', v_caller_profile_id,
    p_target_managed_profile_id
  )
  returning id into v_invite_id;

  return v_invite_id;
end;
$$;

drop function public.get_area_invites(uuid);

create function public.get_area_invites(p_area_id uuid)
returns table(
  invite_id uuid,
  recipient_email text,
  first_name text,
  last_name text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  has_target_managed_participant boolean,
  target_first_name text,
  target_last_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin'
  ) then raise exception 'permission denied'; end if;

  return query
  select ai.id, ai.recipient_email, ai.first_name, ai.last_name,
         case when ai.status = 'pending' and ai.expires_at <= now() then 'expired' else ai.status end,
         ai.expires_at, ai.created_at,
         ai.target_managed_profile_id is not null,
         target_profile.first_name, target_profile.last_name
  from public.area_invites ai
  left join public.profiles target_profile on target_profile.id = ai.target_managed_profile_id
  where ai.area_id = p_area_id
  order by ai.created_at desc, ai.id;
end;
$$;

drop function public.get_my_area_invites();

create function public.get_my_area_invites()
returns table(
  invite_id uuid,
  area_id uuid,
  area_name text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  inviter_first_name text,
  inviter_last_name text,
  is_managed_participant_link boolean,
  target_first_name text,
  target_last_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_email text;
begin
  select lower(btrim(u.email)) into v_email
  from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;

  if v_email is null then raise exception 'Email dell''account non verificata'; end if;

  return query
  select ai.id, ai.area_id, a.name,
         case when ai.status = 'pending' and ai.expires_at <= now() then 'expired' else ai.status end,
         ai.expires_at, ai.created_at,
         inviter.first_name, inviter.last_name,
         ai.target_managed_profile_id is not null,
         target_profile.first_name, target_profile.last_name
  from public.area_invites ai
  join public.areas a on a.id = ai.area_id
  join public.profiles inviter on inviter.id = ai.created_by_profile_id
  left join public.profiles target_profile on target_profile.id = ai.target_managed_profile_id
  where ai.recipient_email = v_email
  order by case when ai.status = 'pending' and ai.expires_at > now() then 0 else 1 end,
           ai.created_at desc, ai.id;
end;
$$;

create or replace function public.accept_area_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_email text;
  v_area_id uuid;
  v_recipient_email text;
  v_status text;
  v_expires_at timestamptz;
  v_accepted_by_profile_id uuid;
  v_target_profile_id uuid;
  v_target_role text;
  v_target_user_id uuid;
  v_caller_membership_role text;
  v_locked_profile_id uuid;
  v_locked_profile_count integer := 0;
begin
  select p.id, lower(btrim(u.email))
  into v_caller_profile_id, v_email
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where u.id = auth.uid() and u.email_confirmed_at is not null;

  if v_caller_profile_id is null or v_email is null then
    raise exception 'Email dell''account non verificata o profilo non trovato';
  end if;

  -- Lettura iniziale solo per sapere quale Area bloccare; i dati dell'invito
  -- vengono riletti e validati dopo il lock.
  select ai.area_id into v_area_id
  from public.area_invites ai
  where ai.id = p_invite_id;
  if v_area_id is null then raise exception 'Invito non trovato'; end if;

  perform 1 from public.areas where id = v_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;

  update public.area_invites
  set status = 'expired'
  where id = p_invite_id
    and area_id = v_area_id
    and status = 'pending'
    and expires_at <= now();

  select ai.recipient_email, ai.status, ai.expires_at,
         ai.accepted_by_profile_id, ai.target_managed_profile_id
  into v_recipient_email, v_status, v_expires_at,
       v_accepted_by_profile_id, v_target_profile_id
  from public.area_invites ai
  where ai.id = p_invite_id and ai.area_id = v_area_id
  for update;

  if not found then raise exception 'Invito non trovato'; end if;
  if v_recipient_email <> v_email then raise exception 'permission denied'; end if;
  if v_status = 'accepted' and v_accepted_by_profile_id = v_caller_profile_id then return; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' accettabile'; end if;
  if v_expires_at <= now() then raise exception 'Invito scaduto'; end if;

  if v_target_profile_id is null then
    -- Flusso Fase 1 invariato per gli inviti senza collegamento esplicito.
    perform 1 from public.profiles p where p.id = v_caller_profile_id for update;
    if not found then raise exception 'Profilo non trovato'; end if;

    select am.role into v_caller_membership_role
    from public.area_memberships am
    where am.area_id = v_area_id and am.profile_id = v_caller_profile_id
    for update;

    if v_caller_membership_role is null then
      insert into public.area_memberships(area_id, profile_id, role)
      values (v_area_id, v_caller_profile_id, 'member');
    elsif v_caller_membership_role = 'managed' then
      update public.area_memberships
      set role = 'member'
      where area_id = v_area_id and profile_id = v_caller_profile_id;
    end if;

    update public.area_invites
    set status = 'accepted', responded_at = now(), accepted_by_profile_id = v_caller_profile_id
    where id = p_invite_id and area_id = v_area_id;
    return;
  end if;

  if v_target_profile_id = v_caller_profile_id then
    raise exception 'Collegamento del partecipante non valido';
  end if;

  -- Ordine stabile per due righe profiles; evita deadlock tra accettazioni
  -- che coinvolgono profili in ordine inverso.
  for v_locked_profile_id in
    select p.id
    from public.profiles p
    where p.id in (v_target_profile_id, v_caller_profile_id)
    order by p.id
    for update
  loop
    v_locked_profile_count := v_locked_profile_count + 1;
  end loop;
  if v_locked_profile_count <> 2 then raise exception 'Profilo non trovato'; end if;

  select am.role, target_profile.user_id
  into v_target_role, v_target_user_id
  from public.area_memberships am
  join public.profiles target_profile on target_profile.id = am.profile_id
  where am.area_id = v_area_id and am.profile_id = v_target_profile_id
  for update of am, target_profile;

  if not found
     or v_target_role <> 'managed'
     or v_target_user_id is not null then
    raise exception 'Il partecipante indicato non e'' piu'' collegabile in questa Area';
  end if;

  select am.role into v_caller_membership_role
  from public.area_memberships am
  where am.area_id = v_area_id and am.profile_id = v_caller_profile_id
  for update;

  if v_caller_membership_role is not null then
    raise exception 'Il tuo account e'' gia'' partecipante di questa Area: il collegamento richiede una risoluzione esplicita';
  end if;

  -- Le collisioni non dovrebbero essere possibili senza una membership A gia'
  -- esistente, ma vengono bloccate esplicitamente prima di ogni aggiornamento.
  if exists (
    select 1
    from public.activity_assignees target_row
    join public.activity_assignees account_row
      on account_row.activity_id = target_row.activity_id
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: assegnazioni attivita'' in conflitto'; end if;

  if exists (
    select 1
    from public.event_participants target_row
    join public.event_participants account_row
      on account_row.event_id = target_row.event_id
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: partecipazioni evento in conflitto'; end if;

  if exists (
    select 1
    from public.area_list_participants target_row
    join public.area_list_participants account_row
      on account_row.list_id = target_row.list_id
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: partecipazioni Lista in conflitto'; end if;

  if exists (
    select 1
    from public.profile_contacts target_row
    join public.profile_contacts account_row
      on account_row.area_id = target_row.area_id
     and account_row.contact_type = target_row.contact_type
     and (
       account_row.contact_value = target_row.contact_value
       or (account_row.is_primary and target_row.is_primary)
     )
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: recapiti contestuali in conflitto'; end if;

  insert into public.area_memberships(area_id, profile_id, role)
  values (v_area_id, v_caller_profile_id, 'member');

  delete from public.profile_contacts
  where area_id = v_area_id and profile_id = v_target_profile_id;

  update public.area_activities
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_activities
  set completed_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and completed_by_profile_id = v_target_profile_id;
  update public.activity_assignees aa
  set profile_id = v_caller_profile_id
  where aa.area_id = v_area_id and aa.profile_id = v_target_profile_id;
  update public.activity_assignees aa
  set assigned_by_profile_id = v_caller_profile_id
  from public.area_activities a
  where a.id = aa.activity_id and a.area_id = aa.area_id
    and a.area_id = v_area_id and aa.assigned_by_profile_id = v_target_profile_id;

  update public.area_events
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.event_participants ep
  set profile_id = v_caller_profile_id
  where ep.area_id = v_area_id and ep.profile_id = v_target_profile_id;
  update public.event_participants ep
  set added_by_profile_id = v_caller_profile_id
  from public.area_events e
  where e.id = ep.event_id and e.area_id = ep.area_id
    and e.area_id = v_area_id and ep.added_by_profile_id = v_target_profile_id;

  update public.areas
  set created_by = v_caller_profile_id
  where id = v_area_id and created_by = v_target_profile_id;

  update public.area_lists
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_list_participants alp
  set profile_id = v_caller_profile_id
  where alp.area_id = v_area_id and alp.profile_id = v_target_profile_id;
  update public.area_list_participants alp
  set added_by_profile_id = v_caller_profile_id
  from public.area_lists l
  where l.id = alp.list_id and l.area_id = alp.area_id
    and l.area_id = v_area_id and alp.added_by_profile_id = v_target_profile_id;
  update public.area_list_items i
  set created_by_profile_id = v_caller_profile_id
  from public.area_lists l
  where l.id = i.list_id and l.area_id = v_area_id
    and i.created_by_profile_id = v_target_profile_id;
  update public.area_list_items i
  set completed_by_profile_id = v_caller_profile_id
  from public.area_lists l
  where l.id = i.list_id and l.area_id = v_area_id
    and i.completed_by_profile_id = v_target_profile_id;

  -- Gli audit degli inviti sono area-scoped; non viene mai toccato un invito
  -- di un'altra Area. Gli inviti concorrenti allo stesso target vengono
  -- revocati: non possono degradare a inviti normali dopo la conversione.
  update public.area_invites
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_invites
  set accepted_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and accepted_by_profile_id = v_target_profile_id;
  update public.area_invites
  set revoked_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and revoked_by_profile_id = v_target_profile_id;
  update public.area_invites
  set status = case when status = 'pending' then 'revoked' else status end,
      revoked_at = case when status = 'pending' then now() else revoked_at end,
      revoked_by_profile_id = case when status = 'pending' then v_caller_profile_id else revoked_by_profile_id end,
      target_managed_profile_id = null
  where area_id = v_area_id
    and target_managed_profile_id = v_target_profile_id
    and id <> p_invite_id;

  update public.area_invites
  set status = 'accepted',
      responded_at = now(),
      accepted_by_profile_id = v_caller_profile_id,
      target_managed_profile_id = null
  where id = p_invite_id and area_id = v_area_id;

  delete from public.area_memberships
  where area_id = v_area_id and profile_id = v_target_profile_id;
end;
$$;

-- La rimozione di un partecipante deve rendere non accettabili tutti gli
-- inviti pending che lo indicavano esplicitamente come target. Il target viene
-- scollegato anche dagli inviti conclusi per liberare la FK composita prima
-- della rimozione della membership; lo stato concluso resta invariato.
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

  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin'
  ) then raise exception 'Utente non autorizzato: solo un admin dell''Area puo'' rimuovere membri'; end if;

  -- Lock Area -> Inviti target -> membership, coerente con accept_area_invite.
  perform 1 from public.area_invites ai
  where ai.area_id = p_area_id and ai.target_managed_profile_id = p_profile_id
  for update;

  select am.role into v_target_role from public.area_memberships am
  where am.area_id = p_area_id and am.profile_id = p_profile_id
  for update;
  if not found then raise exception 'Membership del membro non trovata in questa Area'; end if;

  if v_target_role = 'admin' and not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.role = 'admin' and am.profile_id <> p_profile_id
  ) then raise exception 'Impossibile rimuovere l''ultimo amministratore dell''Area'; end if;

  perform 1 from public.area_activities a where a.area_id = p_area_id and a.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: e'' creatore di attivita'' in questa Area'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: e'' creatore di eventi in questa Area'; end if;
  perform 1 from public.area_lists l where l.area_id = p_area_id and l.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: e'' creatore di Liste in questa Area'; end if;
  perform 1 from public.area_activities a where a.area_id = p_area_id and a.visibility = 'creator_assignees'
    and exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id = p_profile_id)
    and not exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id <> p_profile_id)
    for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo assegnatario di attivita'' selettiva'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.visibility = 'creator_participants'
    and exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id = p_profile_id)
    and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id <> p_profile_id)
    for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di evento selettivo'; end if;
  perform 1 from public.area_lists l where l.area_id = p_area_id and l.visibility = 'creator_participants'
    and exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id = p_profile_id)
    and not exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id <> p_profile_id)
    for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di Lista selettiva'; end if;

  update public.area_invites
  set status = case when status = 'pending' then 'revoked' else status end,
      revoked_at = case when status = 'pending' then now() else revoked_at end,
      revoked_by_profile_id = case when status = 'pending' then v_caller_profile_id else revoked_by_profile_id end,
      target_managed_profile_id = null
  where area_id = p_area_id and target_managed_profile_id = p_profile_id;

  delete from public.area_memberships
  where area_id = p_area_id and profile_id = p_profile_id;
end;
$$;

revoke all on function public.create_area_invite(uuid, text, text, text, uuid) from public;
revoke all on function public.get_area_invites(uuid) from public;
revoke all on function public.get_my_area_invites() from public;
revoke all on function public.accept_area_invite(uuid) from public;
revoke all on function public.remove_area_member(uuid, uuid) from public;
grant execute on function public.create_area_invite(uuid, text, text, text, uuid) to authenticated;
grant execute on function public.get_area_invites(uuid) to authenticated;
grant execute on function public.get_my_area_invites() to authenticated;
grant execute on function public.accept_area_invite(uuid) to authenticated;
grant execute on function public.remove_area_member(uuid, uuid) to authenticated;
-- =============================================================================
-- 19. Inviti normali e Contatti personali
-- =============================================================================

alter table public.area_invites add column source_contact_id uuid;
alter table public.area_invites
  add constraint area_invites_source_contact_fkey
  foreign key (source_contact_id) references public.contacts(id) on delete set null;
create index area_invites_pending_source_contact_idx
  on public.area_invites(created_by_profile_id, source_contact_id)
  where status = 'pending' and source_contact_id is not null;

create or replace function public.create_area_invite(
  p_area_id uuid, p_email text, p_first_name text default null,
  p_last_name text default null, p_target_managed_profile_id uuid default null
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_caller_profile_id uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_first_name text := nullif(btrim(coalesce(p_first_name, '')), '');
  v_last_name text := nullif(btrim(coalesce(p_last_name, '')), '');
  v_invite_id uuid;
  v_source_contact_id uuid;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  if not exists (select 1 from public.area_memberships am where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin') then raise exception 'permission denied'; end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'Email non valida'; end if;

  if p_target_managed_profile_id is not null then
    perform 1 from public.area_memberships am join public.profiles target_profile on target_profile.id = am.profile_id
    where am.area_id = p_area_id and am.profile_id = p_target_managed_profile_id and am.role = 'managed' and target_profile.user_id is null
    for update of am, target_profile;
    if not found then raise exception 'Il partecipante selezionato non e'' piu'' un profilo managed disponibile in questa Area'; end if;
  else
    if v_first_name is null then raise exception 'Il nome del destinatario e'' obbligatorio'; end if;
    perform pg_advisory_xact_lock(hashtextextended(v_caller_profile_id::text || ':' || v_email, 0));
  end if;

  update public.area_invites set status = 'expired'
  where area_id = p_area_id and recipient_email = v_email and status = 'pending' and expires_at <= now();
  if exists (select 1 from auth.users u join public.profiles p on p.user_id = u.id join public.area_memberships am on am.profile_id = p.id where lower(btrim(u.email)) = v_email and am.area_id = p_area_id and am.role in ('admin', 'member')) then raise exception 'Impossibile creare l''invito per questo indirizzo'; end if;
  if exists (select 1 from public.area_invites ai where ai.area_id = p_area_id and ai.recipient_email = v_email and ai.status = 'pending') then raise exception 'Esiste gia'' un invito in attesa per questo indirizzo'; end if;

  if p_target_managed_profile_id is null then
    select c.id into v_source_contact_id
    from public.contacts c join public.contact_methods cm on cm.contact_id = c.id
    where c.owner_profile_id = v_caller_profile_id and cm.type = 'email' and lower(btrim(cm.value)) = v_email
    order by c.created_at, c.id, cm.created_at, cm.id limit 1 for update of c, cm;
    if v_source_contact_id is null then
      insert into public.contacts(owner_profile_id, first_name, last_name) values (v_caller_profile_id, v_first_name, v_last_name) returning id into v_source_contact_id;
      insert into public.contact_methods(contact_id, type, value, is_primary) values (v_source_contact_id, 'email', v_email, true);
    end if;
  end if;

  insert into public.area_invites(area_id, recipient_email, first_name, last_name, expires_at, created_by_profile_id, target_managed_profile_id, source_contact_id)
  values (p_area_id, v_email, v_first_name, v_last_name, now() + interval '7 days', v_caller_profile_id, p_target_managed_profile_id, v_source_contact_id)
  returning id into v_invite_id;
  return v_invite_id;
end;
$$;

drop function public.get_my_contacts();
create function public.get_my_contacts()
returns table(id uuid, first_name text, last_name text, birth_date date, created_at timestamptz, updated_at timestamptz, pending_invites_count bigint)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_profile_id uuid;
begin
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query
  select c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at, count(ai.id)::bigint
  from public.contacts c left join public.area_invites ai
    on ai.source_contact_id = c.id and ai.created_by_profile_id = v_owner_profile_id and ai.status = 'pending'
  where c.owner_profile_id = v_owner_profile_id
  group by c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

revoke all on function public.create_area_invite(uuid, text, text, text, uuid) from public;
revoke all on function public.get_my_contacts() from public;
grant execute on function public.create_area_invite(uuid, text, text, text, uuid) to authenticated;
grant execute on function public.get_my_contacts() to authenticated;

-- =============================================================================
-- 20. Compleanni dei Contatti nel Calendario personale
-- =============================================================================

alter table public.contacts
  add column show_birthday_in_calendar boolean not null default false;

drop function public.get_my_contacts();

create function public.get_my_contacts()
returns table(
  id uuid,
  first_name text,
  last_name text,
  birth_date date,
  created_at timestamptz,
  updated_at timestamptz,
  pending_invites_count bigint,
  primary_email text,
  primary_phone text,
  show_birthday_in_calendar boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
begin
  select p.id
  into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();
  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  return query
  select
    c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at,
    (
      select count(ai.id)::bigint
      from public.area_invites ai
      where ai.source_contact_id = c.id
        and ai.created_by_profile_id = v_owner_profile_id
        and ai.status = 'pending'
        and ai.expires_at > now()
        and exists (
          select 1
          from public.contact_methods cm
          where cm.contact_id = c.id
            and cm.type = 'email'
            and lower(btrim(cm.value)) = lower(btrim(ai.recipient_email))
        )
    ),
    (
      select cm.value from public.contact_methods cm
      where cm.contact_id = c.id and cm.type = 'email'
      order by cm.is_primary desc, cm.created_at, cm.id limit 1
    ),
    (
      select cm.value from public.contact_methods cm
      where cm.contact_id = c.id and cm.type = 'phone'
      order by cm.is_primary desc, cm.created_at, cm.id limit 1
    ),
    c.show_birthday_in_calendar
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

create function public.set_my_contact_birthday_calendar(p_contact_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_owner_profile_id uuid; v_birth_date date;
begin
  if p_enabled is null then raise exception 'Valore non valido per la visualizzazione del compleanno'; end if;
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select c.birth_date into v_birth_date from public.contacts c
  where c.id = p_contact_id and c.owner_profile_id = v_owner_profile_id for update;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
  if p_enabled and v_birth_date is null then
    raise exception 'Aggiungi una data di nascita prima di mostrare il compleanno nel Calendario';
  end if;
  update public.contacts set show_birthday_in_calendar = p_enabled
  where id = p_contact_id and owner_profile_id = v_owner_profile_id;
end;
$$;

create function public.get_my_contact_birthdays(p_year integer)
returns table(contact_id uuid, first_name text, last_name text, occurs_on date)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_owner_profile_id uuid; v_is_leap_year boolean;
begin
  if p_year is null or p_year < 1 or p_year > 9999 then raise exception 'Anno non valido'; end if;
  select p.id into v_owner_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_owner_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  v_is_leap_year := (p_year % 4 = 0 and (p_year % 100 <> 0 or p_year % 400 = 0));
  return query
  select c.id, c.first_name, c.last_name,
    case when extract(month from c.birth_date) = 2 and extract(day from c.birth_date) = 29 and not v_is_leap_year then null
      else make_date(p_year, extract(month from c.birth_date)::integer, extract(day from c.birth_date)::integer)
    end
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
    and c.show_birthday_in_calendar
    and c.birth_date is not null
    and not (extract(month from c.birth_date) = 2 and extract(day from c.birth_date) = 29 and not v_is_leap_year)
  order by extract(month from c.birth_date), extract(day from c.birth_date), lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

revoke all on function public.get_my_contacts() from public;
revoke all on function public.set_my_contact_birthday_calendar(uuid, boolean) from public;
revoke all on function public.get_my_contact_birthdays(integer) from public;
grant execute on function public.get_my_contacts() to authenticated;
grant execute on function public.set_my_contact_birthday_calendar(uuid, boolean) to authenticated;
grant execute on function public.get_my_contact_birthdays(integer) to authenticated;

-- =============================================================================
-- 21. Account privato, preferenze e avatar dei profili
-- =============================================================================

-- contacts.birth_date rimane invariata: appartiene esclusivamente alla rubrica
-- personale. La data di nascita dei partecipanti non fa piu' parte di profiles.
alter table public.profiles drop column birth_date;

revoke update on public.profiles from authenticated;
grant update (first_name, last_name, avatar_path) on public.profiles to authenticated;

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
  on public.profiles
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and (avatar_path is null or avatar_path = id::text || '/avatar')
  );

create table public.account_profile_private (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  phone text,
  birth_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.account_preferences (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  language text not null default 'it' check (language in ('it')),
  date_format text not null default 'DD/MM/YYYY'
    check (date_format in ('DD/MM/YYYY', 'YYYY-MM-DD', 'MM/DD/YYYY')),
  week_starts_on smallint not null default 1 check (week_starts_on between 0 and 6),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.account_preferences.week_starts_on is
  '0 = domenica, 1 = lunedi, ... 6 = sabato; il default 1 corrisponde a lunedi.';

create function public.set_account_profile_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create function public.assert_auth_account_profile()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.profiles p
    where p.id = new.profile_id
      and p.user_id is not null
  ) then
    raise exception 'I dati privati dell''account richiedono un profilo collegato a un utente Auth';
  end if;
  return new;
end;
$$;

create trigger account_profile_private_set_updated_at
  before update on public.account_profile_private
  for each row execute function public.set_account_profile_updated_at();

create trigger account_profile_private_require_auth_profile
  before insert or update of profile_id on public.account_profile_private
  for each row execute function public.assert_auth_account_profile();

create trigger account_preferences_set_updated_at
  before update on public.account_preferences
  for each row execute function public.set_account_profile_updated_at();

create trigger account_preferences_require_auth_profile
  before insert or update of profile_id on public.account_preferences
  for each row execute function public.assert_auth_account_profile();

alter table public.account_profile_private enable row level security;
alter table public.account_preferences enable row level security;
alter table public.account_profile_private force row level security;
alter table public.account_preferences force row level security;

revoke all on public.account_profile_private, public.account_preferences from public, authenticated;
grant select, insert, update on public.account_profile_private to authenticated;
grant select, insert, update on public.account_preferences to authenticated;

create policy account_profile_private_owner_select
  on public.account_profile_private
  for select to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = account_profile_private.profile_id and p.user_id = auth.uid()
    )
  );

create policy account_profile_private_owner_insert
  on public.account_profile_private
  for insert to authenticated
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_profile_private.profile_id and p.user_id = auth.uid()
    )
  );

create policy account_profile_private_owner_update
  on public.account_profile_private
  for update to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = account_profile_private.profile_id and p.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_profile_private.profile_id and p.user_id = auth.uid()
    )
  );

create policy account_preferences_owner_select
  on public.account_preferences
  for select to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id and p.user_id = auth.uid()
    )
  );

create policy account_preferences_owner_insert
  on public.account_preferences
  for insert to authenticated
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id and p.user_id = auth.uid()
    )
  );

create policy account_preferences_owner_update
  on public.account_preferences
  for update to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id and p.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id and p.user_id = auth.uid()
    )
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-avatars',
  'profile-avatars',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists profile_avatars_select_visible_profile on storage.objects;
drop policy if exists profile_avatars_insert_own_profile on storage.objects;
drop policy if exists profile_avatars_update_own_profile on storage.objects;
drop policy if exists profile_avatars_delete_own_profile on storage.objects;

create policy profile_avatars_select_visible_profile
  on storage.objects for select to authenticated
  using (
    bucket_id = 'profile-avatars'
    and exists (
      select 1 from public.profiles p
      where p.id::text = split_part(name, '/', 1)
        and public.can_view_profile(p.id)
    )
  );

create policy profile_avatars_insert_own_profile
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar' from public.profiles p where p.user_id = auth.uid()
    )
  );

create policy profile_avatars_update_own_profile
  on storage.objects for update to authenticated
  using (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar' from public.profiles p where p.user_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar' from public.profiles p where p.user_id = auth.uid()
    )
  );

create policy profile_avatars_delete_own_profile
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar' from public.profiles p where p.user_id = auth.uid()
    )
  );

revoke all on function public.set_account_profile_updated_at() from public;
revoke all on function public.assert_auth_account_profile() from public;

-- =============================================================================
-- 22. La mia Famiglia
-- =============================================================================
-- Stato consolidato della migration 2026-09-09_my_family.sql.

create table public.families (
  id uuid primary key default gen_random_uuid(),
  created_by_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint families_one_personal_family_per_creator unique (created_by_profile_id)
);

create table public.family_access (
  family_id uuid not null references public.families(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role text not null,
  primary key (family_id, profile_id),
  constraint family_access_role_check check (role in ('owner', 'adult'))
);

create table public.family_members (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  member_type text not null,
  linked_profile_id uuid references public.profiles(id) on delete set null,
  contact_id uuid references public.contacts(id) on delete set null,
  first_name text,
  last_name text,
  relationship text not null,
  birth_date date,
  pet_species text,
  pet_species_label text,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint family_members_member_type_check check (member_type in ('person', 'pet')),
  constraint family_members_pet_species_check check (pet_species is null or pet_species in ('dog', 'cat', 'other')),
  constraint family_members_relationship_not_blank check (btrim(relationship) <> ''),
  constraint family_members_self_requires_linked_profile check (
    lower(btrim(relationship)) <> 'self'
    or (member_type = 'person' and linked_profile_id is not null)
  ),
  constraint family_members_contact_only_for_nonself_person_check check (
    contact_id is null
    or (
      member_type = 'person'
      and lower(btrim(relationship)) <> 'self'
    )
  ),
  constraint family_members_person_or_pet_check check (
    (
      member_type = 'person'
      and pet_species is null
      and pet_species_label is null
      and (
        linked_profile_id is not null
        or btrim(coalesce(first_name, '')) <> ''
      )
    )
    or (
      member_type = 'pet'
      and linked_profile_id is null
      and btrim(coalesce(first_name, '')) <> ''
      and pet_species is not null
    )
  )
);

create unique index family_members_unique_linked_profile_per_family
  on public.family_members (family_id, linked_profile_id)
  where linked_profile_id is not null;

create unique index family_members_unique_contact_per_family
  on public.family_members (family_id, contact_id)
  where contact_id is not null;

create index family_access_profile_id_idx
  on public.family_access (profile_id, family_id);

create index family_members_family_id_idx
  on public.family_members (family_id, created_at, id);

create function public.set_family_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger families_set_updated_at
  before update on public.families
  for each row execute function public.set_family_updated_at();

create trigger family_members_set_updated_at
  before update on public.family_members
  for each row execute function public.set_family_updated_at();

alter table public.families enable row level security;
alter table public.family_access enable row level security;
alter table public.family_members enable row level security;
alter table public.families no force row level security;
alter table public.family_access no force row level security;
alter table public.family_members no force row level security;

revoke all on public.families, public.family_access, public.family_members from public, authenticated;

-- Le policy sono intenzionalmente limitate al dominio Famiglia. Le operazioni
-- applicative restano RPC-only; non esiste alcuna dipendenza da Aree o Contatti.
create policy family_access_current_profile_select
  on public.family_access
  for select to authenticated
  using (
    exists (
      select 1
      from public.profiles p
      where p.id = family_access.profile_id
        and p.user_id = auth.uid()
    )
  );

create policy families_authorized_profile_select
  on public.families
  for select to authenticated
  using (
    exists (
      select 1
      from public.family_access fa
      join public.profiles p on p.id = fa.profile_id
      where fa.family_id = families.id
        and p.user_id = auth.uid()
    )
  );

create policy family_members_authorized_profile_select
  on public.family_members
  for select to authenticated
  using (
    exists (
      select 1
      from public.family_access fa
      join public.profiles p on p.id = fa.profile_id
      where fa.family_id = family_members.family_id
        and p.user_id = auth.uid()
    )
  );

create function public.get_my_family()
returns table(
  id uuid,
  created_by_profile_id uuid,
  role text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  return query
  select f.id, f.created_by_profile_id, fa.role, f.created_at, f.updated_at
  from public.families f
  join public.family_access fa
    on fa.family_id = f.id
   and fa.profile_id = v_profile_id
  where f.created_by_profile_id = v_profile_id
    and fa.role = 'owner';
end;
$$;

create function public.create_my_family()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  -- Serializza la creazione per proprietario e rende la RPC idempotente.
  perform pg_advisory_xact_lock(hashtextextended(v_profile_id::text, 0));

  select f.id into v_family_id
  from public.families f
  where f.created_by_profile_id = v_profile_id
  for update;

  if not found then
    insert into public.families (created_by_profile_id)
    values (v_profile_id)
    returning id into v_family_id;
  end if;

  -- Ripara in modo idempotente eventuali stati parziali preesistenti.
  insert into public.family_access (family_id, profile_id, role)
  values (v_family_id, v_profile_id, 'owner')
  on conflict (family_id, profile_id) do update
    set role = excluded.role;

  insert into public.family_members (
    family_id,
    member_type,
    linked_profile_id,
    first_name,
    last_name,
    relationship
  )
  values (
    v_family_id,
    'person',
    v_profile_id,
    null,
    null,
    'self'
  )
  on conflict (family_id, linked_profile_id) where linked_profile_id is not null
  do update set
    member_type = 'person',
    first_name = null,
    last_name = null,
    relationship = 'self',
    pet_species = null,
    pet_species_label = null,
    avatar_path = null;

  return v_family_id;
end;
$$;

create function public.get_my_family_members()
returns table(
  id uuid,
  family_id uuid,
  member_type text,
  linked_profile_id uuid,
  first_name text,
  last_name text,
  relationship text,
  birth_date date,
  pet_species text,
  pet_species_label text,
  avatar_path text,
  created_at timestamptz,
  updated_at timestamptz,
  contact_id uuid,
  is_contact boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Utente non autenticato';
  end if;

  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  select f.id into v_family_id
  from public.families f
  join public.family_access fa
    on fa.family_id = f.id
   and fa.profile_id = v_profile_id
   and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id;

  if v_family_id is null then
    raise exception 'La tua Famiglia non e'' stata ancora creata';
  end if;

  return query
  select
    fm.id,
    fm.family_id,
    fm.member_type,
    fm.linked_profile_id,
    coalesce(linked.first_name, fm.first_name) as first_name,
    coalesce(linked.last_name, fm.last_name) as last_name,
    fm.relationship,
    fm.birth_date,
    fm.pet_species,
    fm.pet_species_label,
    coalesce(linked.avatar_path, fm.avatar_path) as avatar_path,
    fm.created_at,
    fm.updated_at,
    fm.contact_id,
    fm.contact_id is not null as is_contact
  from public.family_members fm
  left join public.profiles linked on linked.id = fm.linked_profile_id
  where fm.family_id = v_family_id
  order by
    case when fm.relationship = 'self' then 0 else 1 end,
    fm.created_at,
    fm.id;
end;
$$;

create function public.link_my_family_member_contact(
  p_member_id uuid,
  p_contact_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_member_type text;
  v_relationship text;
  v_member_contact_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;

  perform 1 from public.contacts c
  where c.id = p_contact_id and c.owner_profile_id = v_profile_id
  for update;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;

  select f.id into v_family_id
  from public.families f join public.family_access fa
    on fa.family_id = f.id and fa.profile_id = v_profile_id and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id
  for update of f;
  if v_family_id is null then raise exception 'La tua Famiglia non e'' stata ancora creata'; end if;

  select fm.member_type, fm.relationship, fm.contact_id
  into v_member_type, v_relationship, v_member_contact_id
  from public.family_members fm
  where fm.id = p_member_id and fm.family_id = v_family_id
  for update;
  if not found then raise exception 'Membro della Famiglia non trovato o non accessibile'; end if;
  if v_member_type <> 'person' then raise exception 'Un animale domestico non puo'' essere collegato a un Contatto'; end if;
  if lower(btrim(v_relationship)) = 'self' then raise exception 'Il membro personale collegato al tuo account non puo'' essere collegato a un Contatto'; end if;
  if v_member_contact_id is not null then raise exception 'Questo membro e'' gia'' collegato a un Contatto'; end if;
  if exists (select 1 from public.family_members fm where fm.family_id = v_family_id and fm.contact_id = p_contact_id) then
    raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
  end if;

  update public.family_members set contact_id = p_contact_id
  where id = p_member_id and family_id = v_family_id;
exception when unique_violation then
  raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
end;
$$;

create function public.unlink_my_family_member_contact(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_member_type text;
  v_relationship text;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select f.id into v_family_id
  from public.families f join public.family_access fa
    on fa.family_id = f.id and fa.profile_id = v_profile_id and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id
  for update of f;
  if v_family_id is null then raise exception 'La tua Famiglia non e'' stata ancora creata'; end if;
  select fm.member_type, fm.relationship into v_member_type, v_relationship
  from public.family_members fm where fm.id = p_member_id and fm.family_id = v_family_id for update;
  if not found then raise exception 'Membro della Famiglia non trovato o non accessibile'; end if;
  if v_member_type <> 'person' then raise exception 'Un animale domestico non puo'' essere collegato a un Contatto'; end if;
  if lower(btrim(v_relationship)) = 'self' then raise exception 'Il membro personale collegato al tuo account non puo'' essere scollegato da un Contatto'; end if;
  update public.family_members set contact_id = null where id = p_member_id and family_id = v_family_id;
end;
$$;

create function public.create_my_contact_from_family_member(p_member_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_member_type text;
  v_relationship text;
  v_existing_contact_id uuid;
  v_first_name text;
  v_last_name text;
  v_birth_date date;
  v_contact_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select f.id into v_family_id
  from public.families f join public.family_access fa
    on fa.family_id = f.id and fa.profile_id = v_profile_id and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id
  for update of f;
  if v_family_id is null then raise exception 'La tua Famiglia non e'' stata ancora creata'; end if;
  select fm.member_type, fm.relationship, fm.contact_id,
         coalesce(linked.first_name, fm.first_name), coalesce(linked.last_name, fm.last_name), fm.birth_date
  into v_member_type, v_relationship, v_existing_contact_id, v_first_name, v_last_name, v_birth_date
  from public.family_members fm
  left join public.profiles linked on linked.id = fm.linked_profile_id
  where fm.id = p_member_id and fm.family_id = v_family_id
  for update of fm;
  if not found then raise exception 'Membro della Famiglia non trovato o non accessibile'; end if;
  if v_member_type <> 'person' then raise exception 'Un animale domestico non puo'' essere trasformato in un Contatto'; end if;
  if lower(btrim(v_relationship)) = 'self' then raise exception 'Il membro personale collegato al tuo account non puo'' essere trasformato in un Contatto'; end if;
  if v_existing_contact_id is not null then raise exception 'Questo membro e'' gia'' collegato a un Contatto'; end if;
  if btrim(coalesce(v_first_name, '')) = '' then raise exception 'Il membro non ha un nome valido da copiare nel Contatto'; end if;
  insert into public.contacts (owner_profile_id, first_name, last_name, birth_date)
  values (v_profile_id, btrim(v_first_name), nullif(btrim(coalesce(v_last_name, '')), ''), v_birth_date)
  returning id into v_contact_id;
  update public.family_members set contact_id = v_contact_id where id = p_member_id and family_id = v_family_id;
  return v_contact_id;
end;
$$;

create function public.create_my_family_member_from_contact(
  p_contact_id uuid,
  p_relationship text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_first_name text;
  v_last_name text;
  v_birth_date date;
  v_relationship text := btrim(coalesce(p_relationship, ''));
  v_member_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select c.first_name, c.last_name, c.birth_date into v_first_name, v_last_name, v_birth_date
  from public.contacts c where c.id = p_contact_id and c.owner_profile_id = v_profile_id for update;
  if not found then raise exception 'Contatto non trovato o non accessibile'; end if;
  select f.id into v_family_id
  from public.families f join public.family_access fa
    on fa.family_id = f.id and fa.profile_id = v_profile_id and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id
  for update of f;
  if v_family_id is null then raise exception 'La tua Famiglia non e'' stata ancora creata'; end if;
  if v_relationship = '' then raise exception 'La relazione e'' obbligatoria'; end if;
  if lower(v_relationship) = 'self' then raise exception 'La relazione self e'' riservata al membro collegato al tuo account'; end if;
  if exists (select 1 from public.family_members fm where fm.family_id = v_family_id and fm.contact_id = p_contact_id) then
    raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
  end if;
  insert into public.family_members (
    family_id, member_type, linked_profile_id, contact_id, first_name, last_name,
    relationship, birth_date, pet_species, pet_species_label
  ) values (
    v_family_id, 'person', null, p_contact_id, btrim(v_first_name),
    nullif(btrim(coalesce(v_last_name, '')), ''), v_relationship, v_birth_date, null, null
  ) returning id into v_member_id;
  return v_member_id;
exception when unique_violation then
  raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
end;
$$;

create function public.create_my_family_member(
  p_member_type text,
  p_first_name text,
  p_last_name text default null,
  p_relationship text default null,
  p_birth_date date default null,
  p_pet_species text default null,
  p_pet_species_label text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_member_id uuid;
  v_member_type text := lower(btrim(coalesce(p_member_type, '')));
  v_pet_species text := nullif(lower(btrim(coalesce(p_pet_species, ''))), '');
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  select f.id into v_family_id
  from public.families f
  join public.family_access fa
    on fa.family_id = f.id
   and fa.profile_id = v_profile_id
   and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id
  for update of f;

  if v_family_id is null then
    raise exception 'La tua Famiglia non e'' stata ancora creata';
  end if;

  if v_member_type not in ('person', 'pet') then
    raise exception 'Tipo di membro non valido';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome e'' obbligatorio';
  end if;

  if btrim(coalesce(p_relationship, '')) = '' then
    raise exception 'La relazione e'' obbligatoria';
  end if;

  if lower(btrim(p_relationship)) = 'self' then
    raise exception 'La relazione self e'' riservata al membro collegato al tuo account';
  end if;

  if v_member_type = 'person' then
    if v_pet_species is not null or nullif(btrim(coalesce(p_pet_species_label, '')), '') is not null then
      raise exception 'Una persona non puo'' avere una specie animale';
    end if;
  elsif v_pet_species not in ('dog', 'cat', 'other') then
    raise exception 'Specie animale non valida';
  end if;

  -- Fase 1: il client non puo' collegare alcun altro Profile.
  insert into public.family_members (
    family_id,
    member_type,
    linked_profile_id,
    first_name,
    last_name,
    relationship,
    birth_date,
    pet_species,
    pet_species_label
  )
  values (
    v_family_id,
    v_member_type,
    null,
    btrim(p_first_name),
    nullif(btrim(coalesce(p_last_name, '')), ''),
    btrim(p_relationship),
    p_birth_date,
    case when v_member_type = 'pet' then v_pet_species else null end,
    case when v_member_type = 'pet' and v_pet_species = 'other'
      then nullif(btrim(coalesce(p_pet_species_label, '')), '')
      else null
    end
  )
  returning id into v_member_id;

  return v_member_id;
end;
$$;

create function public.update_my_family_member(
  p_member_id uuid,
  p_member_type text,
  p_first_name text,
  p_last_name text default null,
  p_relationship text default null,
  p_birth_date date default null,
  p_pet_species text default null,
  p_pet_species_label text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_linked_profile_id uuid;
  v_relationship text;
  v_member_type text := lower(btrim(coalesce(p_member_type, '')));
  v_pet_species text := nullif(lower(btrim(coalesce(p_pet_species, ''))), '');
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  select f.id into v_family_id
  from public.families f
  join public.family_access fa
    on fa.family_id = f.id
   and fa.profile_id = v_profile_id
   and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id
  for update of f;

  if v_family_id is null then
    raise exception 'La tua Famiglia non e'' stata ancora creata';
  end if;

  select fm.linked_profile_id, fm.relationship
  into v_linked_profile_id, v_relationship
  from public.family_members fm
  where fm.id = p_member_id
    and fm.family_id = v_family_id
  for update;

  if not found then
    raise exception 'Membro della Famiglia non trovato o non accessibile';
  end if;

  if v_linked_profile_id = v_profile_id and lower(btrim(v_relationship)) = 'self' then
    raise exception 'Il membro personale collegato al tuo account non puo'' essere modificato da questa funzione';
  end if;

  if v_member_type not in ('person', 'pet') then
    raise exception 'Tipo di membro non valido';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome e'' obbligatorio';
  end if;

  if btrim(coalesce(p_relationship, '')) = '' then
    raise exception 'La relazione e'' obbligatoria';
  end if;

  if lower(btrim(p_relationship)) = 'self' then
    raise exception 'La relazione self e'' riservata al membro collegato al tuo account';
  end if;

  if v_member_type = 'person' then
    if v_pet_species is not null or nullif(btrim(coalesce(p_pet_species_label, '')), '') is not null then
      raise exception 'Una persona non puo'' avere una specie animale';
    end if;
  elsif v_pet_species not in ('dog', 'cat', 'other') then
    raise exception 'Specie animale non valida';
  end if;

  update public.family_members
  set member_type = v_member_type,
      first_name = btrim(p_first_name),
      last_name = nullif(btrim(coalesce(p_last_name, '')), ''),
      relationship = btrim(p_relationship),
      birth_date = p_birth_date,
      pet_species = case when v_member_type = 'pet' then v_pet_species else null end,
      pet_species_label = case when v_member_type = 'pet' and v_pet_species = 'other'
        then nullif(btrim(coalesce(p_pet_species_label, '')), '')
        else null
      end
  where id = p_member_id
    and family_id = v_family_id;
end;
$$;

create function public.delete_my_family_member(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_family_id uuid;
  v_linked_profile_id uuid;
  v_relationship text;
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  select f.id into v_family_id
  from public.families f
  join public.family_access fa
    on fa.family_id = f.id
   and fa.profile_id = v_profile_id
   and fa.role = 'owner'
  where f.created_by_profile_id = v_profile_id
  for update of f;

  if v_family_id is null then
    raise exception 'La tua Famiglia non e'' stata ancora creata';
  end if;

  select fm.linked_profile_id, fm.relationship
  into v_linked_profile_id, v_relationship
  from public.family_members fm
  where fm.id = p_member_id
    and fm.family_id = v_family_id
  for update;

  if not found then
    raise exception 'Membro della Famiglia non trovato o non accessibile';
  end if;

  if v_linked_profile_id = v_profile_id and lower(btrim(v_relationship)) = 'self' then
    raise exception 'Il membro personale collegato al tuo account non puo'' essere eliminato';
  end if;

  delete from public.family_members
  where id = p_member_id
    and family_id = v_family_id;
end;
$$;

alter function public.set_family_updated_at() owner to postgres;
alter function public.get_my_family() owner to postgres;
alter function public.create_my_family() owner to postgres;
alter function public.get_my_family_members() owner to postgres;
alter function public.link_my_family_member_contact(uuid, uuid) owner to postgres;
alter function public.unlink_my_family_member_contact(uuid) owner to postgres;
alter function public.create_my_contact_from_family_member(uuid) owner to postgres;
alter function public.create_my_family_member_from_contact(uuid, text) owner to postgres;
alter function public.create_my_family_member(text, text, text, text, date, text, text) owner to postgres;
alter function public.update_my_family_member(uuid, text, text, text, text, date, text, text) owner to postgres;
alter function public.delete_my_family_member(uuid) owner to postgres;

revoke all on function public.set_family_updated_at() from public;
revoke all on function public.get_my_family() from public;
revoke all on function public.create_my_family() from public;
revoke all on function public.get_my_family_members() from public;
revoke all on function public.link_my_family_member_contact(uuid, uuid) from public;
revoke all on function public.unlink_my_family_member_contact(uuid) from public;
revoke all on function public.create_my_contact_from_family_member(uuid) from public;
revoke all on function public.create_my_family_member_from_contact(uuid, text) from public;
revoke all on function public.create_my_family_member(text, text, text, text, date, text, text) from public;
revoke all on function public.update_my_family_member(uuid, text, text, text, text, date, text, text) from public;
revoke all on function public.delete_my_family_member(uuid) from public;

grant execute on function public.get_my_family() to authenticated;
grant execute on function public.create_my_family() to authenticated;
grant execute on function public.get_my_family_members() to authenticated;
grant execute on function public.link_my_family_member_contact(uuid, uuid) to authenticated;
grant execute on function public.unlink_my_family_member_contact(uuid) to authenticated;
grant execute on function public.create_my_contact_from_family_member(uuid) to authenticated;
grant execute on function public.create_my_family_member_from_contact(uuid, text) to authenticated;
grant execute on function public.create_my_family_member(text, text, text, text, date, text, text) to authenticated;
grant execute on function public.update_my_family_member(uuid, text, text, text, text, date, text, text) to authenticated;
grant execute on function public.delete_my_family_member(uuid) to authenticated;

-- =============================================================================
-- 23. Attivita ricorrenti (stato finale della migration 2026-09-09)
-- =============================================================================
drop function if exists public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz);
drop function if exists public.get_area_activity(uuid,uuid);
drop function if exists public.get_my_visible_activities();
drop function if exists public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text);
drop function if exists public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text);

create function public.get_area_activities(p_area_id uuid,p_status text default null,p_activity_type text default null,p_assigned_to_me boolean default false,p_due_from timestamptz default null,p_due_to timestamptz default null)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz,recurrence_frequency text,recurrence_interval smallint,recurrence_weekdays smallint[],recurrence_until date,recurrence_timezone text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  return query select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone from public.area_activities a where a.area_id=p_area_id and (p_status is null or a.status=p_status) and (p_activity_type is null or a.activity_type=p_activity_type) and (p_due_from is null or a.due_at>=p_due_from) and (p_due_to is null or a.due_at<=p_due_to) and (a.visibility='area' or a.created_by_profile_id=v_profile or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile))) and (not p_assigned_to_me or exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile) or not exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id)) order by a.due_at nulls last,a.created_at desc;
end; $$;

create function public.get_my_visible_activity_occurrences(p_from timestamptz,p_to timestamptz)
returns table(activity_id uuid,area_id uuid,area_name text,area_type text,title text,notes text,activity_type text,status text,priority text,visibility text,is_all_day boolean,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz,occurrence_starts_at timestamptz,occurrence_ends_at timestamptz,recurrence_frequency text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'permission denied'; end if;
  if p_from is null or p_to is null or p_to<=p_from then raise exception 'Intervallo occorrenze non valido'; end if;
  if p_to>p_from+interval '400 days' then raise exception 'Intervallo occorrenze troppo ampio'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'permission denied'; end if;
  return query with visible_activities as (
    select a.*,ar.name as visible_area_name,ar.area_type as visible_area_type from public.area_memberships am join public.areas ar on ar.id=am.area_id join public.area_activities a on a.area_id=am.area_id
    where am.profile_id=v_profile_id and am.role in ('admin','member') and (a.visibility='area' or a.created_by_profile_id=v_profile_id or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile_id)))
  ), single_occurrences as (
    select a.id as activity_id,a.area_id,a.visible_area_name as area_name,a.visible_area_type as area_type,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,a.is_all_day,a.created_by_profile_id,a.created_at,a.updated_at,coalesce(a.starts_at,a.due_at) as occurrence_starts_at,coalesce(a.due_at,a.starts_at) as occurrence_ends_at,a.recurrence_frequency
    from visible_activities a where a.recurrence_frequency is null and a.status<>'cancelled' and coalesce(a.starts_at,a.due_at)>=p_from and coalesce(a.starts_at,a.due_at)<p_to
  ), recurring_candidates as (
    select a.*,candidate.local_day::date as occurrence_date,((candidate.local_day::date+(a.starts_at at time zone a.recurrence_timezone)::time) at time zone a.recurrence_timezone) as occurrence_starts_at,((candidate.local_day::date+(a.starts_at at time zone a.recurrence_timezone)::time)+((a.due_at at time zone a.recurrence_timezone)-(a.starts_at at time zone a.recurrence_timezone))) at time zone a.recurrence_timezone as occurrence_ends_at
    from visible_activities a cross join lateral generate_series(greatest((a.starts_at at time zone a.recurrence_timezone)::date,((p_from at time zone a.recurrence_timezone)::date-1))::timestamp,least(a.recurrence_until,((p_to at time zone a.recurrence_timezone)::date+1))::timestamp,interval '1 day') as candidate(local_day)
    where a.recurrence_frequency='weekly' and a.status='open' and extract(isodow from candidate.local_day)::smallint=any(a.recurrence_weekdays) and (((candidate.local_day::date-(extract(isodow from (a.starts_at at time zone a.recurrence_timezone))::integer-1))-((a.starts_at at time zone a.recurrence_timezone)::date-(extract(isodow from (a.starts_at at time zone a.recurrence_timezone))::integer-1)))/7)%a.recurrence_interval=0
  ), recurring_occurrences as (
    select a.id as activity_id,a.area_id,a.visible_area_name as area_name,a.visible_area_type as area_type,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,a.is_all_day,a.created_by_profile_id,a.created_at,a.updated_at,a.occurrence_starts_at,a.occurrence_ends_at,a.recurrence_frequency from recurring_candidates a where a.occurrence_starts_at>=p_from and a.occurrence_starts_at<p_to
  ) select * from single_occurrences union all select * from recurring_occurrences order by occurrence_starts_at,created_at,activity_id;
end; $$;

-- Ownership and grants are applied after every final activity RPC is defined.


create function public.get_area_activity(p_area_id uuid,p_activity_id uuid)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,visibility text,assignee_profile_ids uuid[],starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz,recurrence_frequency text,recurrence_interval smallint,recurrence_weekdays smallint[],recurrence_until date,recurrence_timezone text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  return query select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,array(select aa.profile_id from public.activity_assignees aa where aa.activity_id=a.id order by aa.assigned_at,aa.profile_id),a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone from public.area_activities a where a.id=p_activity_id and a.area_id=p_area_id and (a.visibility='area' or a.created_by_profile_id=v_profile or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile))); if not found then raise exception 'Attivita non trovata o non accessibile'; end if;
end; $$;

create function public.get_my_visible_activities()
returns table(activity_id uuid,area_id uuid,area_name text,area_type text,title text,notes text,activity_type text,status text,priority text,starts_at timestamptz,due_at timestamptz,is_all_day boolean,visibility text,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz,recurrence_frequency text,recurrence_interval smallint,recurrence_weekdays smallint[],recurrence_until date,recurrence_timezone text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'permission denied'; end if; select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'permission denied'; end if;
  return query select a.id,ar.id,ar.name,ar.area_type,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.visibility,a.created_by_profile_id,a.created_at,a.updated_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone from public.area_memberships am join public.areas ar on ar.id=am.area_id join public.area_activities a on a.area_id=am.area_id where am.profile_id=v_profile_id and am.role in ('admin','member') and (a.visibility='area' or a.created_by_profile_id=v_profile_id or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile_id))) order by coalesce(a.due_at,a.starts_at) asc nulls last,a.created_at asc,a.id asc;
end; $$;

create function public.create_area_activity(p_area_id uuid,p_title text,p_notes text,p_activity_type text,p_priority text,p_starts_at timestamptz,p_due_at timestamptz,p_is_all_day boolean,p_assignee_profile_ids uuid[],p_visibility text,p_recurrence_frequency text default null,p_recurrence_interval smallint default null,p_recurrence_weekdays smallint[] default null,p_recurrence_until date default null,p_recurrence_timezone text default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_ids uuid[]:=coalesce(p_assignee_profile_ids,'{}'); v_id uuid; v_frequency text:=nullif(lower(btrim(coalesce(p_recurrence_frequency,''))), ''); v_interval smallint:=p_recurrence_interval; v_weekdays smallint[]; v_until date:=p_recurrence_until; v_timezone text:=nullif(btrim(coalesce(p_recurrence_timezone,'')), '');
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  if p_recurrence_weekdays is not null then select array_agg(distinct weekday order by weekday) into v_weekdays from unnest(p_recurrence_weekdays) as days(weekday); end if;
  if btrim(coalesce(p_title,''))='' or p_activity_type not in ('task','reminder','deadline','appointment') or p_priority not in ('low','normal','high') or p_visibility not in ('private','creator_assignees','area') or (p_starts_at is not null and p_due_at is not null and p_due_at<p_starts_at) then raise exception 'Dati attivita non validi'; end if;
  if v_frequency is null then if v_interval is not null or v_weekdays is not null or v_until is not null or v_timezone is not null then raise exception 'Configurazione ricorrenza non valida'; end if;
  elsif v_frequency<>'weekly' or p_starts_at is null or v_interval is null or v_interval<=0 or v_weekdays is null or cardinality(v_weekdays)=0 or array_position(v_weekdays,null) is not null or not(v_weekdays<@array[1,2,3,4,5,6,7]::smallint[]) or v_until is null or v_timezone is null then raise exception 'Configurazione ricorrenza non valida';
  else perform 1 from pg_timezone_names where name=v_timezone; if not found then raise exception 'Timezone ricorrenza non valida'; end if; if v_until<(p_starts_at at time zone v_timezone)::date then raise exception 'La fine della ricorrenza non puo precedere la prima occorrenza'; end if; if extract(isodow from (p_starts_at at time zone v_timezone))::smallint<>all(v_weekdays) then raise exception 'Il giorno della prima occorrenza deve appartenere alla ricorrenza'; end if; end if;
  if (p_visibility='private' and cardinality(v_ids)>0) or (p_visibility='creator_assignees' and cardinality(v_ids)=0) then raise exception 'Visibilita e assegnatari non coerenti'; end if; if v_role='member' and exists(select 1 from unnest(v_ids)x where x is distinct from v_profile) then raise exception 'permission denied'; end if; if exists(select 1 from unnest(v_ids)x left join public.area_memberships am on am.area_id=p_area_id and am.profile_id=x where am.profile_id is null) then raise exception 'Assegnatario non appartenente all''Area'; end if;
  insert into public.area_activities(area_id,title,notes,activity_type,priority,visibility,starts_at,due_at,is_all_day,created_by_profile_id,recurrence_frequency,recurrence_interval,recurrence_weekdays,recurrence_until,recurrence_timezone) values(p_area_id,btrim(p_title),p_notes,p_activity_type,p_priority,p_visibility,p_starts_at,p_due_at,coalesce(p_is_all_day,false),v_profile,v_frequency,v_interval,v_weekdays,v_until,v_timezone) returning id into v_id;
  insert into public.activity_assignees(activity_id,area_id,profile_id,assigned_by_profile_id) select v_id,p_area_id,x,v_profile from(select distinct unnest(v_ids)x)s; return v_id;
end; $$;

create function public.update_area_activity(p_area_id uuid,p_activity_id uuid,p_title text,p_notes text,p_activity_type text,p_priority text,p_starts_at timestamptz,p_due_at timestamptz,p_is_all_day boolean,p_visibility text,p_recurrence_frequency text default null,p_recurrence_interval smallint default null,p_recurrence_weekdays smallint[] default null,p_recurrence_until date default null,p_recurrence_timezone text default null,p_update_recurrence boolean default false)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_current_visibility text; v_frequency text:=nullif(lower(btrim(coalesce(p_recurrence_frequency,''))), ''); v_interval smallint:=p_recurrence_interval; v_weekdays smallint[]; v_until date:=p_recurrence_until; v_timezone text:=nullif(btrim(coalesce(p_recurrence_timezone,'')), '');
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if; select created_by_profile_id,visibility into v_creator,v_current_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id for update; if not found then raise exception 'Attivita non trovata'; end if; if v_creator is distinct from v_profile and not(v_current_visibility='area' and p_visibility='area' and v_role='admin') then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title,''))='' or p_activity_type not in ('task','reminder','deadline','appointment') or p_priority not in ('low','normal','high') or p_visibility not in ('private','creator_assignees','area') or (p_starts_at is not null and p_due_at is not null and p_due_at<p_starts_at) then raise exception 'Dati attivita non validi'; end if;
  if p_update_recurrence then if p_recurrence_weekdays is not null then select array_agg(distinct weekday order by weekday) into v_weekdays from unnest(p_recurrence_weekdays) as days(weekday); end if; if v_frequency is null then v_interval:=null;v_weekdays:=null;v_until:=null;v_timezone:=null; elsif v_frequency<>'weekly' or p_starts_at is null or v_interval is null or v_interval<=0 or v_weekdays is null or cardinality(v_weekdays)=0 or array_position(v_weekdays,null) is not null or not(v_weekdays<@array[1,2,3,4,5,6,7]::smallint[]) or v_until is null or v_timezone is null then raise exception 'Configurazione ricorrenza non valida'; else perform 1 from pg_timezone_names where name=v_timezone; if not found then raise exception 'Timezone ricorrenza non valida'; end if; if v_until<(p_starts_at at time zone v_timezone)::date then raise exception 'La fine della ricorrenza non puo precedere la prima occorrenza'; end if; if extract(isodow from (p_starts_at at time zone v_timezone))::smallint<>all(v_weekdays) then raise exception 'Il giorno della prima occorrenza deve appartenere alla ricorrenza'; end if; end if; end if;
  if (p_visibility='private' and exists(select 1 from public.activity_assignees where activity_id=p_activity_id)) or (p_visibility='creator_assignees' and not exists(select 1 from public.activity_assignees where activity_id=p_activity_id)) then raise exception 'Visibilita e assegnatari non coerenti'; end if;
  update public.area_activities set title=btrim(p_title),notes=p_notes,activity_type=p_activity_type,priority=p_priority,visibility=p_visibility,starts_at=p_starts_at,due_at=p_due_at,is_all_day=coalesce(p_is_all_day,false),recurrence_frequency=case when p_update_recurrence then v_frequency else recurrence_frequency end,recurrence_interval=case when p_update_recurrence then v_interval else recurrence_interval end,recurrence_weekdays=case when p_update_recurrence then v_weekdays else recurrence_weekdays end,recurrence_until=case when p_update_recurrence then v_until else recurrence_until end,recurrence_timezone=case when p_update_recurrence then v_timezone else recurrence_timezone end where id=p_activity_id and area_id=p_area_id;
end; $$;

alter function public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz) owner to postgres;
alter function public.get_area_activity(uuid,uuid) owner to postgres;
alter function public.get_my_visible_activities() owner to postgres;
alter function public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text,text,smallint,smallint[],date,text) owner to postgres;
alter function public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,text,smallint,smallint[],date,text,boolean) owner to postgres;
alter function public.get_my_visible_activity_occurrences(timestamptz,timestamptz) owner to postgres;

revoke all on function public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz) from public;
revoke all on function public.get_area_activity(uuid,uuid) from public;
revoke all on function public.get_my_visible_activities() from public;
revoke all on function public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text,text,smallint,smallint[],date,text) from public;
revoke all on function public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,text,smallint,smallint[],date,text,boolean) from public;
revoke all on function public.get_my_visible_activity_occurrences(timestamptz,timestamptz) from public;

grant execute on function public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz) to authenticated;
grant execute on function public.get_area_activity(uuid,uuid) to authenticated;
grant execute on function public.get_my_visible_activities() to authenticated;

-- =============================================================================
-- 24. Scadenze personali
-- =============================================================================
-- Le occorrenze sono virtuali; solo le conferme vengono persistite.

create table public.deadlines (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (title = btrim(title) and char_length(title) > 0),
  category text not null check (category in ('vehicle', 'home', 'documents', 'animals', 'contracts_subscriptions', 'other')),
  reference text check (reference is null or reference = btrim(reference)),
  family_member_id uuid references public.family_members(id) on delete set null,
  first_due_on date not null,
  recurrence_months smallint check (recurrence_months is null or recurrence_months in (1, 6, 12, 24)),
  reminder_days smallint not null default 30 check (reminder_days in (0, 7, 15, 30)),
  notes text,
  status text not null default 'active' check (status in ('active', 'terminated')),
  terminated_on date,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint deadlines_termination_check check ((status = 'active' and terminated_on is null) or (status = 'terminated' and terminated_on is not null and terminated_on >= first_due_on))
);
create table public.deadline_occurrence_completions (
  deadline_id uuid not null references public.deadlines(id) on delete cascade,
  occurrence_on date not null, completed_at timestamptz not null default now(),
  completed_by_profile_id uuid references public.profiles(id) on delete set null, notes text,
  primary key (deadline_id, occurrence_on)
);
create index deadlines_owner_status_due_idx on public.deadlines(owner_profile_id, status, first_due_on, id);
create index deadlines_owner_family_member_idx on public.deadlines(owner_profile_id, family_member_id) where family_member_id is not null;

create function public.set_deadline_updated_at() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin new.updated_at = now(); return new; end;
$$;
create trigger deadlines_set_updated_at before update on public.deadlines for each row execute function public.set_deadline_updated_at();

-- Mantiene il giorno ancorato alla data base: 31/01 -> 28/29 febbraio -> 31/03.
-- Il 29 febbraio annuale usa il 28 febbraio nei non bisestili e torna al 29 nei bisestili.
create function public.deadline_occurrence_dates(p_first_due_on date,p_recurrence_months smallint,p_terminated_on date,p_from date,p_to date)
returns table(occurrence_on date) language plpgsql stable set search_path = public, pg_temp as $$
declare v_cap date; v_step integer; v_max_step integer; v_month date; v_day integer := extract(day from p_first_due_on)::integer; v_candidate date;
begin
  if p_first_due_on is null or p_from is null or p_to is null or p_from > p_to then return; end if;
  v_cap := least(p_to, coalesce(p_terminated_on, p_to)); if v_cap < p_first_due_on then return; end if;
  if p_recurrence_months is null then
    if p_first_due_on between p_from and v_cap then occurrence_on := p_first_due_on; return next; end if;
    return;
  end if;
  v_max_step := ((extract(year from v_cap)::integer-extract(year from p_first_due_on)::integer)*12+extract(month from v_cap)::integer-extract(month from p_first_due_on)::integer)/p_recurrence_months;
  for v_step in 0..greatest(v_max_step,0) loop
    v_month := (date_trunc('month',p_first_due_on)::date+make_interval(months=>v_step*p_recurrence_months))::date;
    v_candidate := make_date(extract(year from v_month)::integer,extract(month from v_month)::integer,least(v_day,extract(day from(v_month+interval '1 month - 1 day'))::integer));
    if v_candidate between p_from and v_cap then occurrence_on := v_candidate; return next; end if;
  end loop;
end;
$$;

alter table public.deadlines enable row level security;
alter table public.deadline_occurrence_completions enable row level security;
alter table public.deadlines no force row level security;
alter table public.deadline_occurrence_completions no force row level security;
revoke all on public.deadlines, public.deadline_occurrence_completions from public, anon, authenticated;

create function public.get_my_deadlines(p_status text default null)
returns table(id uuid,title text,category text,reference text,family_member_id uuid,first_due_on date,recurrence_months smallint,reminder_days smallint,notes text,status text,terminated_on date,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  if p_status is not null and p_status not in ('active','terminated') then raise exception 'Stato scadenza non valido'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query select d.id,d.title,d.category,d.reference,d.family_member_id,d.first_due_on,d.recurrence_months,d.reminder_days,d.notes,d.status,d.terminated_on,d.created_at,d.updated_at from public.deadlines d where d.owner_profile_id=v_profile_id and(p_status is null or d.status=p_status) order by d.status='terminated',d.first_due_on,d.created_at,d.id;
end;
$$;
create function public.get_my_deadline(p_deadline_id uuid)
returns table(id uuid,title text,category text,reference text,family_member_id uuid,first_due_on date,recurrence_months smallint,reminder_days smallint,notes text,status text,terminated_on date,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query select d.id,d.title,d.category,d.reference,d.family_member_id,d.first_due_on,d.recurrence_months,d.reminder_days,d.notes,d.status,d.terminated_on,d.created_at,d.updated_at from public.deadlines d where d.id=p_deadline_id and d.owner_profile_id=v_profile_id;
  if not found then raise exception 'Scadenza non trovata o non accessibile'; end if;
end;
$$;
create function public.assert_my_deadline_family_member(p_profile_id uuid,p_family_member_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_family_member_id is null then return; end if;
  if not exists(select 1 from public.family_members fm join public.families f on f.id=fm.family_id join public.family_access fa on fa.family_id=f.id and fa.profile_id=p_profile_id and fa.role='owner' where fm.id=p_family_member_id and f.created_by_profile_id=p_profile_id) then raise exception 'Membro Famiglia non trovato o non accessibile'; end if;
end;
$$;
create function public.create_my_deadline(p_title text,p_category text,p_first_due_on date,p_reference text default null,p_family_member_id uuid default null,p_recurrence_months smallint default null,p_reminder_days smallint default 30,p_notes text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_deadline_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if; select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if btrim(coalesce(p_title,''))='' then raise exception 'Il titolo della scadenza e'' obbligatorio'; end if; if p_category not in ('vehicle','home','documents','animals','contracts_subscriptions','other') then raise exception 'Categoria scadenza non valida'; end if; if p_first_due_on is null then raise exception 'La prima scadenza e'' obbligatoria'; end if; if p_recurrence_months is not null and p_recurrence_months not in (1,6,12,24) then raise exception 'Ricorrenza scadenza non valida'; end if; if coalesce(p_reminder_days,-1) not in (0,7,15,30) then raise exception 'Anticipo promemoria non valido'; end if;
  perform public.assert_my_deadline_family_member(v_profile_id,p_family_member_id);
  insert into public.deadlines(owner_profile_id,title,category,reference,family_member_id,first_due_on,recurrence_months,reminder_days,notes) values(v_profile_id,btrim(p_title),p_category,nullif(btrim(coalesce(p_reference,'')),''),p_family_member_id,p_first_due_on,p_recurrence_months,p_reminder_days,p_notes) returning id into v_deadline_id; return v_deadline_id;
end;
$$;
create function public.update_my_deadline(p_deadline_id uuid,p_title text,p_category text,p_first_due_on date,p_reference text default null,p_family_member_id uuid default null,p_recurrence_months smallint default null,p_reminder_days smallint default 30,p_notes text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_first_due_on date; v_recurrence_months smallint;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if; select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select d.first_due_on,d.recurrence_months into v_first_due_on,v_recurrence_months from public.deadlines d where d.id=p_deadline_id and d.owner_profile_id=v_profile_id and d.status='active' for update; if not found then raise exception 'Scadenza non trovata, terminata o non accessibile'; end if;
  if btrim(coalesce(p_title,''))='' then raise exception 'Il titolo della scadenza e'' obbligatorio'; end if; if p_category not in ('vehicle','home','documents','animals','contracts_subscriptions','other') then raise exception 'Categoria scadenza non valida'; end if; if p_first_due_on is null then raise exception 'La prima scadenza e'' obbligatoria'; end if; if p_recurrence_months is not null and p_recurrence_months not in (1,6,12,24) then raise exception 'Ricorrenza scadenza non valida'; end if; if coalesce(p_reminder_days,-1) not in (0,7,15,30) then raise exception 'Anticipo promemoria non valido'; end if;
  if(p_first_due_on is distinct from v_first_due_on or p_recurrence_months is distinct from v_recurrence_months) and exists(select 1 from public.deadline_occurrence_completions c where c.deadline_id=p_deadline_id) then raise exception 'Non puoi modificare data base o ricorrenza dopo una conferma: termina la serie e crea una nuova scadenza'; end if;
  perform public.assert_my_deadline_family_member(v_profile_id,p_family_member_id);
  update public.deadlines set title=btrim(p_title),category=p_category,reference=nullif(btrim(coalesce(p_reference,'')),''),family_member_id=p_family_member_id,first_due_on=p_first_due_on,recurrence_months=p_recurrence_months,reminder_days=p_reminder_days,notes=p_notes where id=p_deadline_id and owner_profile_id=v_profile_id;
end;
$$;
create function public.terminate_my_deadline(p_deadline_id uuid,p_terminated_on date default current_date) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_first_due_on date;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if; select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select d.first_due_on into v_first_due_on from public.deadlines d where d.id=p_deadline_id and d.owner_profile_id=v_profile_id and d.status='active' for update; if not found then raise exception 'Scadenza non trovata, gia'' terminata o non accessibile'; end if;
  if p_terminated_on is null or p_terminated_on<v_first_due_on then raise exception 'La data di terminazione non puo'' precedere la prima scadenza'; end if;
  update public.deadlines set status='terminated',terminated_on=p_terminated_on where id=p_deadline_id and owner_profile_id=v_profile_id;
end;
$$;
create function public.delete_my_deadline(p_deadline_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if; select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  delete from public.deadlines where id=p_deadline_id and owner_profile_id=v_profile_id; if not found then raise exception 'Scadenza non trovata o non accessibile'; end if;
end;
$$;
create function public.get_my_deadline_occurrences(p_from date,p_to date)
returns table(deadline_id uuid,title text,category text,reference text,family_member_id uuid,occurrence_on date,reminder_days smallint,status text,is_completed boolean,completed_at timestamptz,notes text,occurrence_state text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if; if p_from is null or p_to is null or p_from>p_to then raise exception 'Intervallo occorrenze non valido'; end if; if p_to>p_from+1826 then raise exception 'Intervallo occorrenze troppo ampio'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query select d.id,d.title,d.category,d.reference,d.family_member_id,o.occurrence_on,d.reminder_days,d.status,c.deadline_id is not null,c.completed_at,d.notes,case when c.deadline_id is not null then 'completed' when o.occurrence_on<current_date then 'overdue' when o.occurrence_on=current_date then 'today' else 'upcoming' end from public.deadlines d cross join lateral public.deadline_occurrence_dates(d.first_due_on,d.recurrence_months,d.terminated_on,p_from,p_to)o left join public.deadline_occurrence_completions c on c.deadline_id=d.id and c.occurrence_on=o.occurrence_on where d.owner_profile_id=v_profile_id order by o.occurrence_on,d.created_at,d.id;
end;
$$;
create function public.set_my_deadline_occurrence_completed(p_deadline_id uuid,p_occurrence_on date,p_completed boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid; v_first_due_on date; v_recurrence_months smallint; v_terminated_on date;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if; if p_occurrence_on is null then raise exception 'Data occorrenza obbligatoria'; end if; if p_completed is null then raise exception 'Stato completamento non valido'; end if; if p_occurrence_on>current_date then raise exception 'Non puoi confermare una scadenza futura'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select d.first_due_on,d.recurrence_months,d.terminated_on into v_first_due_on,v_recurrence_months,v_terminated_on from public.deadlines d where d.id=p_deadline_id and d.owner_profile_id=v_profile_id for update; if not found then raise exception 'Scadenza non trovata o non accessibile'; end if;
  if not exists(select 1 from public.deadline_occurrence_dates(v_first_due_on,v_recurrence_months,v_terminated_on,p_occurrence_on,p_occurrence_on)) then raise exception 'La data indicata non corrisponde a un''occorrenza della scadenza'; end if;
  if p_completed then insert into public.deadline_occurrence_completions(deadline_id,occurrence_on,completed_at,completed_by_profile_id) values(p_deadline_id,p_occurrence_on,now(),v_profile_id) on conflict(deadline_id,occurrence_on) do update set completed_at=excluded.completed_at,completed_by_profile_id=excluded.completed_by_profile_id; else delete from public.deadline_occurrence_completions where deadline_id=p_deadline_id and occurrence_on=p_occurrence_on; end if;
end;
$$;
create function public.get_my_deadline_alerts(p_until date)
returns table(deadline_id uuid,title text,category text,reference text,family_member_id uuid,occurrence_on date,reminder_days smallint,notes text,occurrence_state text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if; if p_until is null or p_until<current_date then raise exception 'Intervallo avvisi non valido'; end if; if p_until>current_date+1826 then raise exception 'Intervallo avvisi troppo ampio'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id=auth.uid(); if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query select d.id,d.title,d.category,d.reference,d.family_member_id,o.occurrence_on,d.reminder_days,d.notes,case when o.occurrence_on<current_date then 'overdue' when o.occurrence_on=current_date then 'today' else 'upcoming' end from public.deadlines d cross join lateral public.deadline_occurrence_dates(d.first_due_on,d.recurrence_months,null,d.first_due_on,p_until)o left join public.deadline_occurrence_completions c on c.deadline_id=d.id and c.occurrence_on=o.occurrence_on where d.owner_profile_id=v_profile_id and d.status='active' and c.deadline_id is null and current_date>=o.occurrence_on-d.reminder_days order by o.occurrence_on,d.created_at,d.id;
end;
$$;

alter table public.deadlines owner to postgres;
alter table public.deadline_occurrence_completions owner to postgres;
alter function public.set_deadline_updated_at() owner to postgres;
alter function public.deadline_occurrence_dates(date,smallint,date,date,date) owner to postgres;
alter function public.assert_my_deadline_family_member(uuid,uuid) owner to postgres;
alter function public.get_my_deadlines(text) owner to postgres;
alter function public.get_my_deadline(uuid) owner to postgres;
alter function public.create_my_deadline(text,text,date,text,uuid,smallint,smallint,text) owner to postgres;
alter function public.update_my_deadline(uuid,text,text,date,text,uuid,smallint,smallint,text) owner to postgres;
alter function public.terminate_my_deadline(uuid,date) owner to postgres;
alter function public.delete_my_deadline(uuid) owner to postgres;
alter function public.get_my_deadline_occurrences(date,date) owner to postgres;
alter function public.set_my_deadline_occurrence_completed(uuid,date,boolean) owner to postgres;
alter function public.get_my_deadline_alerts(date) owner to postgres;
revoke all on function public.set_deadline_updated_at() from public,anon,authenticated;
revoke all on function public.deadline_occurrence_dates(date,smallint,date,date,date) from public,anon,authenticated;
revoke all on function public.assert_my_deadline_family_member(uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_my_deadlines(text) from public,anon;
revoke all on function public.get_my_deadline(uuid) from public,anon;
revoke all on function public.create_my_deadline(text,text,date,text,uuid,smallint,smallint,text) from public,anon;
revoke all on function public.update_my_deadline(uuid,text,text,date,text,uuid,smallint,smallint,text) from public,anon;
revoke all on function public.terminate_my_deadline(uuid,date) from public,anon;
revoke all on function public.delete_my_deadline(uuid) from public,anon;
revoke all on function public.get_my_deadline_occurrences(date,date) from public,anon;
revoke all on function public.set_my_deadline_occurrence_completed(uuid,date,boolean) from public,anon;
revoke all on function public.get_my_deadline_alerts(date) from public,anon;
grant execute on function public.get_my_deadlines(text) to authenticated;
grant execute on function public.get_my_deadline(uuid) to authenticated;
grant execute on function public.create_my_deadline(text,text,date,text,uuid,smallint,smallint,text) to authenticated;
grant execute on function public.update_my_deadline(uuid,text,text,date,text,uuid,smallint,smallint,text) to authenticated;
grant execute on function public.terminate_my_deadline(uuid,date) to authenticated;
grant execute on function public.delete_my_deadline(uuid) to authenticated;
grant execute on function public.get_my_deadline_occurrences(date,date) to authenticated;
grant execute on function public.set_my_deadline_occurrence_completed(uuid,date,boolean) to authenticated;
grant execute on function public.get_my_deadline_alerts(date) to authenticated;
grant execute on function public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text,text,smallint,smallint[],date,text) to authenticated;
grant execute on function public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,text,smallint,smallint[],date,text,boolean) to authenticated;
grant execute on function public.get_my_visible_activity_occurrences(timestamptz,timestamptz) to authenticated;
