-- FamilArea: identita' condivisibile, dati account privati e avatar privato.
-- La firma legacy delle RPC partecipanti conserva p_birth_date solo per compatibilita'
-- con i client esistenti: il valore non viene piu' memorizzato ne' restituito.

begin;

-- Aggiorna prima le funzioni dipendenti dalla colonna che verra' rimossa.
create or replace function public.add_area_member(
  p_area_id uuid,
  p_first_name text,
  p_last_name text,
  p_birth_date date,
  p_role text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_new_profile_id uuid;
begin
  if p_role not in ('admin', 'member', 'managed') then
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
    raise exception 'permission denied: solo un admin dell''Area puo'' aggiungere partecipanti';
  end if;

  insert into public.profiles (first_name, last_name)
  values (btrim(p_first_name), nullif(btrim(coalesce(p_last_name, '')), ''))
  returning id into v_new_profile_id;

  insert into public.area_memberships (area_id, profile_id, role)
  values (p_area_id, v_new_profile_id, p_role);

  return v_new_profile_id;
end;
$$;

create or replace function public.update_area_member(
  p_area_id uuid,
  p_profile_id uuid,
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
  v_caller_profile_id uuid;
  v_target_user_id uuid;
begin
  select p.id into v_caller_profile_id
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
    raise exception 'permission denied: solo un admin dell''Area puo'' modificare i partecipanti';
  end if;

  select p.user_id into v_target_user_id
  from public.area_memberships am
  join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id
    and am.profile_id = p_profile_id
  for update of am, p;

  if not found then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  if exists (
    select 1
    from public.contact_participant_profiles cpp
    where cpp.profile_id = p_profile_id
  ) then
    raise exception 'Impossibile modificare questo partecipante: i dati provengono da un Contatto personale';
  end if;

  if v_target_user_id is not null then
    raise exception 'Impossibile modificare un profilo collegato a un account utente';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome e'' obbligatorio';
  end if;

  update public.profiles
  set first_name = btrim(p_first_name),
      last_name = nullif(btrim(coalesce(p_last_name, '')), '')
  where id = p_profile_id;
end;
$$;

drop function public.get_area_participants(uuid);
create function public.get_area_participants(p_area_id uuid)
returns table(
  profile_id uuid,
  first_name text,
  last_name text,
  role text,
  is_personal_contact_participant boolean
)
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

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  if not exists (
    select 1
    from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role in ('admin', 'member')
  ) then
    raise exception 'permission denied: partecipante non autorizzato per questa Area';
  end if;

  return query
  select
    am.profile_id,
    p.first_name,
    p.last_name,
    am.role,
    exists (
      select 1
      from public.contact_participant_profiles cpp
      where cpp.profile_id = am.profile_id
    )
  from public.area_memberships am
  join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id
  order by lower(p.first_name), lower(coalesce(p.last_name, '')), am.profile_id;
end;
$$;

alter table public.profiles
  add column avatar_path text;

alter table public.profiles
  drop column birth_date;

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
      where p.id = account_profile_private.profile_id
        and p.user_id = auth.uid()
    )
  );

create policy account_profile_private_owner_insert
  on public.account_profile_private
  for insert to authenticated
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_profile_private.profile_id
        and p.user_id = auth.uid()
    )
  );

create policy account_profile_private_owner_update
  on public.account_profile_private
  for update to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = account_profile_private.profile_id
        and p.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_profile_private.profile_id
        and p.user_id = auth.uid()
    )
  );

create policy account_preferences_owner_select
  on public.account_preferences
  for select to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id
        and p.user_id = auth.uid()
    )
  );

create policy account_preferences_owner_insert
  on public.account_preferences
  for insert to authenticated
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id
        and p.user_id = auth.uid()
    )
  );

create policy account_preferences_owner_update
  on public.account_preferences
  for update to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id
        and p.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = account_preferences.profile_id
        and p.user_id = auth.uid()
    )
  );

-- Bucket privato: il nome oggetto e' sempre <profile_id>/avatar.
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
  on storage.objects
  for select to authenticated
  using (
    bucket_id = 'profile-avatars'
    and exists (
      select 1
      from public.profiles p
      where p.id::text = split_part(name, '/', 1)
        and public.can_view_profile(p.id)
    )
  );

create policy profile_avatars_insert_own_profile
  on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar'
      from public.profiles p
      where p.user_id = auth.uid()
    )
  );

create policy profile_avatars_update_own_profile
  on storage.objects
  for update to authenticated
  using (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar'
      from public.profiles p
      where p.user_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar'
      from public.profiles p
      where p.user_id = auth.uid()
    )
  );

create policy profile_avatars_delete_own_profile
  on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'profile-avatars'
    and name = (
      select p.id::text || '/avatar'
      from public.profiles p
      where p.user_id = auth.uid()
    )
  );

revoke all on function public.set_account_profile_updated_at() from public;
revoke all on function public.assert_auth_account_profile() from public;
revoke all on function public.add_area_member(uuid, text, text, date, text) from public;
revoke all on function public.update_area_member(uuid, uuid, text, text, date) from public;
revoke all on function public.get_area_participants(uuid) from public;
grant execute on function public.add_area_member(uuid, text, text, date, text) to authenticated;
grant execute on function public.update_area_member(uuid, uuid, text, text, date) to authenticated;
grant execute on function public.get_area_participants(uuid) to authenticated;

commit;
