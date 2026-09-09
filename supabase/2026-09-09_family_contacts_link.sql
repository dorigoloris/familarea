-- FamilArea: collegamento opzionale tra membri della Famiglia e Contatti.
-- I due domini restano distinti: non esiste sincronizzazione automatica.

begin;

alter table public.family_members
  add column contact_id uuid null
    references public.contacts(id) on delete set null;

alter table public.family_members
  add constraint family_members_contact_only_for_nonself_person_check
  check (
    contact_id is null
    or (
      member_type = 'person'
      and lower(btrim(relationship)) <> 'self'
    )
  );

create unique index family_members_unique_contact_per_family
  on public.family_members (family_id, contact_id)
  where contact_id is not null;

drop function public.get_my_family_members();

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
  if auth.uid() is null then
    raise exception 'Utente non autenticato';
  end if;

  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();
  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  -- Un Contact viene bloccato prima della Famiglia: e' coerente con la
  -- cancellazione owner-only del Contact, che lo blocca prima del SET NULL FK.
  perform 1
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_profile_id = v_profile_id
  for update;
  if not found then
    raise exception 'Contatto non trovato o non accessibile';
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

  select fm.member_type, fm.relationship, fm.contact_id
  into v_member_type, v_relationship, v_member_contact_id
  from public.family_members fm
  where fm.id = p_member_id
    and fm.family_id = v_family_id
  for update;
  if not found then
    raise exception 'Membro della Famiglia non trovato o non accessibile';
  end if;
  if v_member_type <> 'person' then
    raise exception 'Un animale domestico non puo'' essere collegato a un Contatto';
  end if;
  if lower(btrim(v_relationship)) = 'self' then
    raise exception 'Il membro personale collegato al tuo account non puo'' essere collegato a un Contatto';
  end if;
  if v_member_contact_id is not null then
    raise exception 'Questo membro e'' gia'' collegato a un Contatto';
  end if;
  if exists (
    select 1
    from public.family_members fm
    where fm.family_id = v_family_id
      and fm.contact_id = p_contact_id
  ) then
    raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
  end if;

  update public.family_members
  set contact_id = p_contact_id
  where id = p_member_id
    and family_id = v_family_id;
exception
  when unique_violation then
    raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
end;
$$;

create function public.unlink_my_family_member_contact(
  p_member_id uuid
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
  where f.created_by_profile_id = v_profile_id
  for update of f;
  if v_family_id is null then
    raise exception 'La tua Famiglia non e'' stata ancora creata';
  end if;

  select fm.member_type, fm.relationship
  into v_member_type, v_relationship
  from public.family_members fm
  where fm.id = p_member_id
    and fm.family_id = v_family_id
  for update;
  if not found then
    raise exception 'Membro della Famiglia non trovato o non accessibile';
  end if;
  if v_member_type <> 'person' then
    raise exception 'Un animale domestico non puo'' essere collegato a un Contatto';
  end if;
  if lower(btrim(v_relationship)) = 'self' then
    raise exception 'Il membro personale collegato al tuo account non puo'' essere scollegato da un Contatto';
  end if;

  -- Idempotente: aggiornare NULL a NULL e' un successo senza effetti collaterali.
  update public.family_members
  set contact_id = null
  where id = p_member_id
    and family_id = v_family_id;
end;
$$;

create function public.create_my_contact_from_family_member(
  p_member_id uuid
)
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
  where f.created_by_profile_id = v_profile_id
  for update of f;
  if v_family_id is null then
    raise exception 'La tua Famiglia non e'' stata ancora creata';
  end if;

  select
    fm.member_type,
    fm.relationship,
    fm.contact_id,
    coalesce(linked.first_name, fm.first_name),
    coalesce(linked.last_name, fm.last_name),
    fm.birth_date
  into
    v_member_type,
    v_relationship,
    v_existing_contact_id,
    v_first_name,
    v_last_name,
    v_birth_date
  from public.family_members fm
  left join public.profiles linked on linked.id = fm.linked_profile_id
  where fm.id = p_member_id
    and fm.family_id = v_family_id
  for update of fm;
  if not found then
    raise exception 'Membro della Famiglia non trovato o non accessibile';
  end if;
  if v_member_type <> 'person' then
    raise exception 'Un animale domestico non puo'' essere trasformato in un Contatto';
  end if;
  if lower(btrim(v_relationship)) = 'self' then
    raise exception 'Il membro personale collegato al tuo account non puo'' essere trasformato in un Contatto';
  end if;
  if v_existing_contact_id is not null then
    raise exception 'Questo membro e'' gia'' collegato a un Contatto';
  end if;
  if btrim(coalesce(v_first_name, '')) = '' then
    raise exception 'Il membro non ha un nome valido da copiare nel Contatto';
  end if;

  insert into public.contacts (owner_profile_id, first_name, last_name, birth_date)
  values (
    v_profile_id,
    btrim(v_first_name),
    nullif(btrim(coalesce(v_last_name, '')), ''),
    v_birth_date
  )
  returning id into v_contact_id;

  update public.family_members
  set contact_id = v_contact_id
  where id = p_member_id
    and family_id = v_family_id;

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
  if auth.uid() is null then
    raise exception 'Utente non autenticato';
  end if;

  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();
  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  -- Mantiene lo stesso ordine dei lock delle operazioni che partono da un
  -- Contact esistente: Contact, poi Famiglia.
  select c.first_name, c.last_name, c.birth_date
  into v_first_name, v_last_name, v_birth_date
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_profile_id = v_profile_id
  for update;
  if not found then
    raise exception 'Contatto non trovato o non accessibile';
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

  if v_relationship = '' then
    raise exception 'La relazione e'' obbligatoria';
  end if;
  if lower(v_relationship) = 'self' then
    raise exception 'La relazione self e'' riservata al membro collegato al tuo account';
  end if;
  if exists (
    select 1
    from public.family_members fm
    where fm.family_id = v_family_id
      and fm.contact_id = p_contact_id
  ) then
    raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
  end if;

  insert into public.family_members (
    family_id,
    member_type,
    linked_profile_id,
    contact_id,
    first_name,
    last_name,
    relationship,
    birth_date,
    pet_species,
    pet_species_label
  )
  values (
    v_family_id,
    'person',
    null,
    p_contact_id,
    btrim(v_first_name),
    nullif(btrim(coalesce(v_last_name, '')), ''),
    v_relationship,
    v_birth_date,
    null,
    null
  )
  returning id into v_member_id;

  return v_member_id;
exception
  when unique_violation then
    raise exception 'Questo Contatto e'' gia'' collegato a un altro membro della Famiglia';
end;
$$;

alter function public.get_my_family_members() owner to postgres;
alter function public.link_my_family_member_contact(uuid, uuid) owner to postgres;
alter function public.unlink_my_family_member_contact(uuid) owner to postgres;
alter function public.create_my_contact_from_family_member(uuid) owner to postgres;
alter function public.create_my_family_member_from_contact(uuid, text) owner to postgres;

revoke all on function public.get_my_family_members() from public;
revoke all on function public.link_my_family_member_contact(uuid, uuid) from public;
revoke all on function public.unlink_my_family_member_contact(uuid) from public;
revoke all on function public.create_my_contact_from_family_member(uuid) from public;
revoke all on function public.create_my_family_member_from_contact(uuid, text) from public;

grant execute on function public.get_my_family_members() to authenticated;
grant execute on function public.link_my_family_member_contact(uuid, uuid) to authenticated;
grant execute on function public.unlink_my_family_member_contact(uuid) to authenticated;
grant execute on function public.create_my_contact_from_family_member(uuid) to authenticated;
grant execute on function public.create_my_family_member_from_contact(uuid, text) to authenticated;

commit;
