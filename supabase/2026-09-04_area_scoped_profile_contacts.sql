-- =============================================================================
-- FamilArea — migrazione incrementale: contatti contestuali all'Area
-- =============================================================================
-- Da eseguire manualmente sul database Supabase remoto esistente.
-- Non sceglie mai arbitrariamente un'Area: i contatti di profili presenti in
-- piÃ¹ Aree bloccano la migrazione finchÃ© non vengono classificati manualmente.

begin;

alter table public.profile_contacts add column if not exists area_id uuid;

-- Assegna l'Area esclusivamente ai profili con una sola membership.
update public.profile_contacts pc
set area_id = am.area_id
from public.area_memberships am
where pc.area_id is null
  and am.profile_id = pc.profile_id
  and not exists (
    select 1
    from public.area_memberships am_other
    where am_other.profile_id = am.profile_id
      and am_other.area_id <> am.area_id
  );

do $$
begin
  if exists (select 1 from public.profile_contacts where area_id is null) then
    raise exception
      'Migrazione profile_contacts interrotta: esistono contatti senza un''Area determinabile in modo univoco. Assegnare manualmente area_id alle righe di profili senza membership o presenti in piÃ¹ Aree, poi rieseguire.';
  end if;

  if exists (
    select 1
    from public.profile_contacts
    where contact_type = 'email'
    group by area_id, profile_id, lower(btrim(contact_value))
    having count(*) > 1
  ) then
    raise exception
      'Migrazione profile_contacts interrotta: la normalizzazione delle email produrrebbe duplicati nello stesso profilo e Area.';
  end if;

  if exists (
    select 1
    from public.profile_contacts
    where contact_type = 'phone'
      and contact_value !~ '^\+[1-9][0-9]{1,14}$'
  ) then
    raise exception
      'Migrazione profile_contacts interrotta: esistono telefoni non in formato E.164.';
  end if;

  if exists (
    select 1
    from public.profile_contacts
    group by area_id, profile_id, contact_type
    having count(*) filter (where is_primary) > 1
  ) then
    raise exception
      'Migrazione profile_contacts interrotta: esistono piÃ¹ contatti principali dello stesso tipo nel medesimo profilo e Area.';
  end if;
end;
$$;

-- La normalizzazione Ã¨ sicura dopo il controllo delle collisioni sopra.
update public.profile_contacts
set contact_value = lower(btrim(contact_value))
where contact_type = 'email';

-- Per gruppi storici senza principale, promuove in modo deterministico il piÃ¹ vecchio.
with groups_without_primary as (
  select area_id, profile_id, contact_type
  from public.profile_contacts
  group by area_id, profile_id, contact_type
  having count(*) filter (where is_primary) = 0
), ranked as (
  select pc.id,
         row_number() over (
           partition by pc.area_id, pc.profile_id, pc.contact_type
           order by pc.created_at, pc.id
         ) as position
  from public.profile_contacts pc
  join groups_without_primary g
    on g.area_id = pc.area_id
   and g.profile_id = pc.profile_id
   and g.contact_type = pc.contact_type
)
update public.profile_contacts pc
set is_primary = true
from ranked r
where pc.id = r.id and r.position = 1;

alter table public.profile_contacts
  alter column area_id set not null,
  add constraint profile_contacts_area_id_fkey
    foreign key (area_id) references public.areas (id) on delete cascade,
  add constraint profile_contacts_area_profile_membership_fkey
    foreign key (area_id, profile_id)
    references public.area_memberships (area_id, profile_id) on delete cascade,
  add constraint profile_contacts_email_normalized_check
    check (contact_type <> 'email' or contact_value = lower(btrim(contact_value))),
  add constraint profile_contacts_phone_e164_check
    check (contact_type <> 'phone' or contact_value ~ '^\+[1-9][0-9]{1,14}$');

alter table public.profile_contacts
  drop constraint profile_contacts_profile_id_contact_type_contact_value_key,
  add constraint profile_contacts_area_profile_type_value_key
    unique (area_id, profile_id, contact_type, contact_value);

create unique index profile_contacts_one_primary_per_type
  on public.profile_contacts (area_id, profile_id, contact_type)
  where is_primary = true;

create or replace function public.require_area_contact_admin(p_area_id uuid, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_caller_profile_id uuid;
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

create or replace function public.get_area_member_contacts(p_area_id uuid, p_profile_id uuid)
returns table (id uuid, contact_type text, contact_value text, is_primary boolean, created_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.require_area_contact_admin(p_area_id, p_profile_id);
  return query select pc.id, pc.contact_type, pc.contact_value, pc.is_primary, pc.created_at
  from public.profile_contacts pc where pc.area_id = p_area_id and pc.profile_id = p_profile_id
  order by pc.contact_type, pc.is_primary desc, pc.created_at, pc.id;
end; $$;

create or replace function public.add_area_member_contact(p_area_id uuid, p_profile_id uuid, p_contact_type text, p_contact_value text, p_is_primary boolean default false)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text := lower(btrim(p_contact_type)); v_value text; v_primary boolean; v_id uuid;
begin
  perform public.require_area_contact_admin(p_area_id, p_profile_id);
  if v_type is null or v_type not in ('email', 'phone') then raise exception 'Tipo di contatto non valido'; end if;
  v_value := case when v_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_value, '') = '' then raise exception 'Il valore del contatto Ã¨ obbligatorio'; end if;
  if v_type = 'phone' and v_value !~ '^\+[1-9][0-9]{1,14}$' then raise exception 'Il telefono deve essere nel formato internazionale E.164'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  v_primary := coalesce(p_is_primary, false) or not exists (
    select 1 from public.profile_contacts where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_type
  );
  if v_primary then update public.profile_contacts set is_primary = false where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_type; end if;
  insert into public.profile_contacts (area_id, profile_id, contact_type, contact_value, is_primary)
  values (p_area_id, p_profile_id, v_type, v_value, v_primary) returning id into v_id;
  return v_id;
end; $$;

create or replace function public.update_area_member_contact(p_area_id uuid, p_profile_id uuid, p_contact_id uuid, p_contact_value text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text; v_value text;
begin
  perform public.require_area_contact_admin(p_area_id, p_profile_id);
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type into v_type from public.profile_contacts where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  v_value := case when v_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_value, '') = '' then raise exception 'Il valore del contatto Ã¨ obbligatorio'; end if;
  if v_type = 'phone' and v_value !~ '^\+[1-9][0-9]{1,14}$' then raise exception 'Il telefono deve essere nel formato internazionale E.164'; end if;
  update public.profile_contacts set contact_value = v_value where id = p_contact_id;
end; $$;

create or replace function public.set_area_member_contact_primary(p_area_id uuid, p_profile_id uuid, p_contact_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text;
begin
  perform public.require_area_contact_admin(p_area_id, p_profile_id);
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type into v_type from public.profile_contacts where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  update public.profile_contacts set is_primary = false where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_type;
  update public.profile_contacts set is_primary = true where id = p_contact_id;
end; $$;

create or replace function public.delete_area_member_contact(p_area_id uuid, p_profile_id uuid, p_contact_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text; v_was_primary boolean; v_replacement_id uuid;
begin
  perform public.require_area_contact_admin(p_area_id, p_profile_id);
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type, is_primary into v_type, v_was_primary from public.profile_contacts where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  delete from public.profile_contacts where id = p_contact_id;
  if v_was_primary then
    select id into v_replacement_id from public.profile_contacts where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_type order by created_at, id limit 1;
    if v_replacement_id is not null then update public.profile_contacts set is_primary = true where id = v_replacement_id; end if;
  end if;
end; $$;

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

commit;
