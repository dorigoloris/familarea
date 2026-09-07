-- FamilArea — rubrica personale privata dell'utente autenticato.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  first_name text not null check (first_name = btrim(first_name) and char_length(first_name) > 0),
  last_name text check (last_name is null or last_name = btrim(last_name)),
  birth_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index contacts_owner_name_idx
  on public.contacts(owner_profile_id, lower(first_name), lower(coalesce(last_name, '')), id);

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

-- Le email sono confrontate senza distinzione maiuscole/minuscole; i telefoni
-- restano intenzionalmente nel formato inserito dall'utente.
create unique index contact_methods_email_case_insensitive_unique
  on public.contact_methods(contact_id, lower(value))
  where type = 'email';

create unique index contact_methods_one_primary_per_type
  on public.contact_methods(contact_id, type)
  where is_primary;

alter table public.contacts enable row level security;
alter table public.contact_methods enable row level security;
alter table public.contacts no force row level security;
alter table public.contact_methods no force row level security;

create function public.set_personal_contact_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger contacts_set_updated_at
  before update on public.contacts
  for each row execute function public.set_personal_contact_updated_at();

create trigger contact_methods_set_updated_at
  before update on public.contact_methods
  for each row execute function public.set_personal_contact_updated_at();

create function public.get_my_contacts()
returns table(
  id uuid,
  first_name text,
  last_name text,
  birth_date date,
  created_at timestamptz,
  updated_at timestamptz
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

  return query
  select c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

create function public.get_my_contact(p_contact_id uuid)
returns table(
  id uuid,
  first_name text,
  last_name text,
  birth_date date,
  created_at timestamptz,
  updated_at timestamptz,
  methods jsonb
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

  return query
  select
    c.id,
    c.first_name,
    c.last_name,
    c.birth_date,
    c.created_at,
    c.updated_at,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', cm.id,
            'type', cm.type,
            'value', cm.value,
            'is_primary', cm.is_primary,
            'created_at', cm.created_at,
            'updated_at', cm.updated_at
          ) order by cm.type, cm.is_primary desc, cm.created_at, cm.id
        )
        from public.contact_methods cm
        where cm.contact_id = c.id
      ),
      '[]'::jsonb
    )
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_profile_id = v_owner_profile_id;

  if not found then
    raise exception 'Contatto non trovato o non accessibile';
  end if;
end;
$$;

create function public.create_my_contact(
  p_first_name text,
  p_last_name text default null,
  p_birth_date date default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_contact_id uuid;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;
  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome del contatto e'' obbligatorio';
  end if;

  insert into public.contacts(owner_profile_id, first_name, last_name, birth_date)
  values (
    v_owner_profile_id,
    btrim(p_first_name),
    nullif(btrim(coalesce(p_last_name, '')), ''),
    p_birth_date
  )
  returning id into v_contact_id;

  return v_contact_id;
end;
$$;

create function public.update_my_contact(
  p_contact_id uuid,
  p_first_name text,
  p_last_name text,
  p_birth_date date
)
returns void
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
  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome del contatto e'' obbligatorio';
  end if;

  update public.contacts
  set first_name = btrim(p_first_name),
      last_name = nullif(btrim(coalesce(p_last_name, '')), ''),
      birth_date = p_birth_date
  where id = p_contact_id
    and owner_profile_id = v_owner_profile_id;

  if not found then
    raise exception 'Contatto non trovato o non accessibile';
  end if;
end;
$$;

create function public.delete_my_contact(p_contact_id uuid)
returns void
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

  delete from public.contacts
  where id = p_contact_id
    and owner_profile_id = v_owner_profile_id;

  if not found then
    raise exception 'Contatto non trovato o non accessibile';
  end if;
end;
$$;

create function public.add_my_contact_method(
  p_contact_id uuid,
  p_type text,
  p_value text,
  p_is_primary boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_type text := lower(btrim(p_type));
  v_value text;
  v_is_primary boolean;
  v_method_id uuid;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;
  if coalesce(v_type, '') not in ('email', 'phone') then
    raise exception 'Tipo di recapito non valido';
  end if;

  v_value := btrim(coalesce(p_value, ''));
  if v_value = '' then
    raise exception 'Il valore del recapito e'' obbligatorio';
  end if;
  if v_type = 'email' then
    v_value := lower(v_value);
  end if;

  perform 1
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_profile_id = v_owner_profile_id
  for update;
  if not found then
    raise exception 'Contatto non trovato o non accessibile';
  end if;

  v_is_primary := coalesce(p_is_primary, false) or not exists (
    select 1
    from public.contact_methods cm
    where cm.contact_id = p_contact_id
      and cm.type = v_type
  );

  if v_is_primary then
    update public.contact_methods
    set is_primary = false
    where contact_id = p_contact_id
      and type = v_type;
  end if;

  insert into public.contact_methods(contact_id, type, value, is_primary)
  values (p_contact_id, v_type, v_value, v_is_primary)
  returning id into v_method_id;

  return v_method_id;
end;
$$;

create function public.update_my_contact_method(
  p_method_id uuid,
  p_type text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_contact_id uuid;
  v_is_primary boolean;
  v_type text := lower(btrim(p_type));
  v_value text;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;
  if coalesce(v_type, '') not in ('email', 'phone') then
    raise exception 'Tipo di recapito non valido';
  end if;

  v_value := btrim(coalesce(p_value, ''));
  if v_value = '' then
    raise exception 'Il valore del recapito e'' obbligatorio';
  end if;
  if v_type = 'email' then
    v_value := lower(v_value);
  end if;

  select cm.contact_id, cm.is_primary
  into v_contact_id, v_is_primary
  from public.contact_methods cm
  join public.contacts c on c.id = cm.contact_id
  where cm.id = p_method_id
    and c.owner_profile_id = v_owner_profile_id
  for update of c, cm;

  if v_contact_id is null then
    raise exception 'Recapito non trovato o non accessibile';
  end if;

  if v_is_primary then
    update public.contact_methods
    set is_primary = false
    where contact_id = v_contact_id
      and type = v_type
      and id <> p_method_id;
  end if;

  update public.contact_methods
  set type = v_type,
      value = v_value
  where id = p_method_id
    and contact_id = v_contact_id;
end;
$$;

create function public.set_my_contact_method_primary(p_method_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_contact_id uuid;
  v_type text;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  select cm.contact_id, cm.type
  into v_contact_id, v_type
  from public.contact_methods cm
  join public.contacts c on c.id = cm.contact_id
  where cm.id = p_method_id
    and c.owner_profile_id = v_owner_profile_id
  for update of c, cm;

  if v_contact_id is null then
    raise exception 'Recapito non trovato o non accessibile';
  end if;

  update public.contact_methods
  set is_primary = false
  where contact_id = v_contact_id
    and type = v_type;
  update public.contact_methods
  set is_primary = true
  where id = p_method_id
    and contact_id = v_contact_id;
end;
$$;

create function public.delete_my_contact_method(p_method_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_contact_id uuid;
begin
  select p.id into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  select cm.contact_id
  into v_contact_id
  from public.contact_methods cm
  join public.contacts c on c.id = cm.contact_id
  where cm.id = p_method_id
    and c.owner_profile_id = v_owner_profile_id
  for update of c, cm;

  if v_contact_id is null then
    raise exception 'Recapito non trovato o non accessibile';
  end if;

  delete from public.contact_methods
  where id = p_method_id
    and contact_id = v_contact_id;
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

commit;
