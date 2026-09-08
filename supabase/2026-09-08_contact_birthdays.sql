-- FamilArea: compleanni privati dei Contatti nel Calendario personale.
-- I compleanni sono occorrenze virtuali: non vengono creati Eventi.

begin;

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
    c.id,
    c.first_name,
    c.last_name,
    c.birth_date,
    c.created_at,
    c.updated_at,
    (
      select count(ai.id)::bigint
      from public.area_invites ai
      where ai.source_contact_id = c.id
        and ai.created_by_profile_id = v_owner_profile_id
        and ai.status = 'pending'
    ) as pending_invites_count,
    (
      select cm.value
      from public.contact_methods cm
      where cm.contact_id = c.id
        and cm.type = 'email'
      order by cm.is_primary desc, cm.created_at, cm.id
      limit 1
    ) as primary_email,
    (
      select cm.value
      from public.contact_methods cm
      where cm.contact_id = c.id
        and cm.type = 'phone'
      order by cm.is_primary desc, cm.created_at, cm.id
      limit 1
    ) as primary_phone,
    c.show_birthday_in_calendar
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

create function public.set_my_contact_birthday_calendar(
  p_contact_id uuid,
  p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_birth_date date;
begin
  if p_enabled is null then
    raise exception 'Valore non valido per la visualizzazione del compleanno';
  end if;

  select p.id
  into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  select c.birth_date
  into v_birth_date
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_profile_id = v_owner_profile_id
  for update;

  if not found then
    raise exception 'Contatto non trovato o non accessibile';
  end if;

  if p_enabled and v_birth_date is null then
    raise exception 'Aggiungi una data di nascita prima di mostrare il compleanno nel Calendario';
  end if;

  update public.contacts
  set show_birthday_in_calendar = p_enabled
  where id = p_contact_id
    and owner_profile_id = v_owner_profile_id;
end;
$$;

create function public.get_my_contact_birthdays(p_year integer)
returns table(
  contact_id uuid,
  first_name text,
  last_name text,
  occurs_on date
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
  v_is_leap_year boolean;
begin
  if p_year is null or p_year < 1 or p_year > 9999 then
    raise exception 'Anno non valido';
  end if;

  select p.id
  into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  v_is_leap_year := (p_year % 4 = 0 and (p_year % 100 <> 0 or p_year % 400 = 0));

  return query
  select
    c.id,
    c.first_name,
    c.last_name,
    case
      when extract(month from c.birth_date) = 2
       and extract(day from c.birth_date) = 29
       and not v_is_leap_year then null
      else make_date(
        p_year,
        extract(month from c.birth_date)::integer,
        extract(day from c.birth_date)::integer
      )
    end as occurs_on
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
    and c.show_birthday_in_calendar
    and c.birth_date is not null
    and not (
      extract(month from c.birth_date) = 2
      and extract(day from c.birth_date) = 29
      and not v_is_leap_year
    )
  order by extract(month from c.birth_date), extract(day from c.birth_date), lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

revoke all on function public.get_my_contacts() from public;
revoke all on function public.set_my_contact_birthday_calendar(uuid, boolean) from public;
revoke all on function public.get_my_contact_birthdays(integer) from public;
grant execute on function public.get_my_contacts() to authenticated;
grant execute on function public.set_my_contact_birthday_calendar(uuid, boolean) to authenticated;
grant execute on function public.get_my_contact_birthdays(integer) to authenticated;

commit;
