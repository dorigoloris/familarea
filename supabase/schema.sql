-- =============================================================================
-- FamilArea — schema di riferimento (verificato contro il database remoto)
-- =============================================================================
-- Questo file NON è stato eseguito contro il database remoto.
-- Rispecchia la configurazione verificata manualmente su Supabase il 2026-09-04:
-- GRANT, RLS/FORCE RLS, funzioni SECURITY DEFINER, policy e privilegi EXECUTE
-- sono stati confermati uno per uno contro il progetto reale (flusso testato:
-- Login → Le mie Aree → apertura Area → elenco membri).
--
-- Convenzioni:
--  - tutte le scritture su profiles/areas/area_memberships avvengono SOLO
--    tramite le funzioni RPC SECURITY DEFINER (create_area, add_area_member)
--    o tramite il trigger handle_new_user. Al ruolo "authenticated" non viene
--    mai concesso INSERT/DELETE diretto su queste tabelle.
--  - le funzioni helper usate nelle policy RLS (is_area_member, can_view_profile)
--    sono SECURITY DEFINER di proprietà del proprietario delle tabelle: essendo
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
  created_at  timestamptz not null default now()
);
comment on table public.profiles is
  'Un profilo per ogni persona nota a FamilArea. user_id è NULL per i profili "gestiti" (senza account) creati da add_area_member.';

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
  'Contatti aggiuntivi (email/telefono) per un profilo, tipicamente usati per profili gestiti senza account. Non ancora usata dal client: nessuna policy di accesso definita finché non serve.';

create unique index if not exists profile_contacts_one_primary_per_type
  on public.profile_contacts (area_id, profile_id, contact_type)
  where is_primary = true;

alter table public.profiles          enable row level security;
alter table public.areas             enable row level security;
alter table public.area_memberships  enable row level security;
alter table public.profile_contacts  enable row level security;

-- confermato sul remoto: FORCE RLS = false su tutte e 4 (necessario perché le
-- funzioni SECURITY DEFINER sotto possano bypassare la RLS come table owner).
alter table public.profiles          no force row level security;
alter table public.areas             no force row level security;
alter table public.area_memberships  no force row level security;
alter table public.profile_contacts  no force row level security;

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
  );
$$;
comment on function public.is_area_member(uuid) is
  'Vero se l''utente autenticato ha una membership (qualsiasi ruolo) nell''Area indicata. Usata nelle policy di areas/area_memberships.';

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
    );
$$;
comment on function public.can_view_profile(uuid) is
  'Vero se il profilo è quello dell''utente autenticato, oppure condivide con lui almeno un''Area.';

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
  'Crea una nuova Area e assegna il chiamante come admin. Il profilo del chiamante deve già esistere (creato da handle_new_user).';

revoke all on function public.create_area(text, text) from public;
grant execute on function public.create_area(text, text) to authenticated;

-- =============================================================================
-- 5. RPC: aggiunta membro (profilo senza account) — solo admin dell'Area
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
    raise exception 'permission denied: solo un admin dell''Area può aggiungere membri';
  end if;

  insert into public.profiles (first_name, last_name, birth_date)
  values (btrim(p_first_name), nullif(btrim(coalesce(p_last_name, '')), ''), p_birth_date)
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
-- 5b. RPC: modifica anagrafica di un membro — solo admin dell'Area
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
    raise exception 'permission denied: solo un admin dell''Area può modificare i membri';
  end if;

  if not exists (
    select 1 from public.area_memberships
    where area_id = p_area_id
      and profile_id = p_profile_id
  ) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome è obbligatorio';
  end if;

  update public.profiles
  set first_name = btrim(p_first_name),
      last_name  = nullif(btrim(coalesce(p_last_name, '')), ''),
      birth_date = p_birth_date
  where id = p_profile_id;
end;
$$;
comment on function public.update_area_member(uuid, uuid, text, text, date) is
  'Aggiorna nome, cognome e data di nascita di un membro dell''Area. Richiede che il chiamante sia admin di quella Area; non modifica user_id né altre colonne.';

revoke all on function public.update_area_member(uuid, uuid, text, text, date) from public;
grant execute on function public.update_area_member(uuid, uuid, text, text, date) to authenticated;

-- =============================================================================
-- 5c. RPC: contatti contestuali all'Area — solo admin dell'Area
-- =============================================================================

create or replace function public.require_area_contact_admin(p_area_id uuid, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
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
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
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
  v_contact_type text := lower(btrim(p_contact_type));
  v_contact_value text;
  v_is_primary boolean;
  v_existing_count integer;
  v_contact_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
  if v_contact_type is null or v_contact_type not in ('email', 'phone') then raise exception 'Tipo di contatto non valido'; end if;

  v_contact_value := case when v_contact_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_contact_value, '') = '' then raise exception 'Il valore del contatto Ã¨ obbligatorio'; end if;
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
  v_contact_type text;
  v_contact_value text;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type into v_contact_type from public.profile_contacts
  where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_contact_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;

  v_contact_value := case when v_contact_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_contact_value, '') = '' then raise exception 'Il valore del contatto Ã¨ obbligatorio'; end if;
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
  v_contact_type text;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
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
  v_contact_type text;
  v_was_primary boolean;
  v_replacement_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puÃ² gestire i contatti';
  end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = p_profile_id) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;
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
-- Nessun INSERT/DELETE/UPDATE diretto per "authenticated": tutte le scritture
-- passano dalle funzioni SECURITY DEFINER sopra, che girano con i privilegi
-- del proprietario delle tabelle.

revoke all on public.profiles          from public, authenticated;
revoke all on public.areas             from public, authenticated;
revoke all on public.area_memberships  from public, authenticated;
revoke all on public.profile_contacts  from public, authenticated;

grant select on public.profiles to authenticated;
grant update (first_name, last_name, birth_date) on public.profiles to authenticated;

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
-- accesso da "authenticated" finché non verrà introdotta una RPC dedicata a
-- leggere/scrivere i contatti.
