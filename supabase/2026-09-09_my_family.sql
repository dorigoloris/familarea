-- FamilArea: dominio personale "La mia Famiglia".
-- Questo dominio e' indipendente da Aree, Contatti e profili managed legacy.

begin;

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
  updated_at timestamptz
)
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
    fm.updated_at
  from public.family_members fm
  left join public.profiles linked on linked.id = fm.linked_profile_id
  where fm.family_id = v_family_id
  order by
    case when fm.relationship = 'self' then 0 else 1 end,
    fm.created_at,
    fm.id;
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
alter function public.create_my_family_member(text, text, text, text, date, text, text) owner to postgres;
alter function public.update_my_family_member(uuid, text, text, text, text, date, text, text) owner to postgres;
alter function public.delete_my_family_member(uuid) owner to postgres;

revoke all on function public.set_family_updated_at() from public;
revoke all on function public.get_my_family() from public;
revoke all on function public.create_my_family() from public;
revoke all on function public.get_my_family_members() from public;
revoke all on function public.create_my_family_member(text, text, text, text, date, text, text) from public;
revoke all on function public.update_my_family_member(uuid, text, text, text, text, date, text, text) from public;
revoke all on function public.delete_my_family_member(uuid) from public;

grant execute on function public.get_my_family() to authenticated;
grant execute on function public.create_my_family() to authenticated;
grant execute on function public.get_my_family_members() to authenticated;
grant execute on function public.create_my_family_member(text, text, text, text, date, text, text) to authenticated;
grant execute on function public.update_my_family_member(uuid, text, text, text, text, date, text, text) to authenticated;
grant execute on function public.delete_my_family_member(uuid) to authenticated;

commit;
