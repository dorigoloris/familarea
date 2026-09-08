-- FamilArea: un invito normale crea o riusa un Contatto personale privato.
-- Non crea profili tecnici, membership o bridge Contact -> Partecipante.

begin;

alter table public.area_invites
  add column source_contact_id uuid;

alter table public.area_invites
  add constraint area_invites_source_contact_fkey
  foreign key (source_contact_id)
  references public.contacts(id)
  on delete set null;

create index area_invites_pending_source_contact_idx
  on public.area_invites(created_by_profile_id, source_contact_id)
  where status = 'pending' and source_contact_id is not null;

create or replace function public.create_area_invite(
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
  v_first_name text := nullif(btrim(coalesce(p_first_name, '')), '');
  v_last_name text := nullif(btrim(coalesce(p_last_name, '')), '');
  v_invite_id uuid;
  v_source_contact_id uuid;
begin
  select p.id
  into v_caller_profile_id
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

  -- Il flusso legacy managed resta invariato e non genera Contatti.
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
  else
    if v_first_name is null then
      raise exception 'Il nome del destinatario e'' obbligatorio';
    end if;

    -- Serializza ricerca e creazione per owner + email, senza imporre
    -- alcuna unicita' globale tra rubriche di utenti diversi.
    perform pg_advisory_xact_lock(
      hashtextextended(v_caller_profile_id::text || ':' || v_email, 0)
    );
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
    select 1
    from public.area_invites ai
    where ai.area_id = p_area_id
      and ai.recipient_email = v_email
      and ai.status = 'pending'
  ) then
    raise exception 'Esiste gia'' un invito in attesa per questo indirizzo';
  end if;

  if p_target_managed_profile_id is null then
    -- In caso di duplicati storici sceglie stabilmente il Contact piu' vecchio.
    select c.id
    into v_source_contact_id
    from public.contacts c
    join public.contact_methods cm on cm.contact_id = c.id
    where c.owner_profile_id = v_caller_profile_id
      and cm.type = 'email'
      and lower(btrim(cm.value)) = v_email
    order by c.created_at, c.id, cm.created_at, cm.id
    limit 1
    for update of c, cm;

    if v_source_contact_id is null then
      insert into public.contacts(owner_profile_id, first_name, last_name)
      values (v_caller_profile_id, v_first_name, v_last_name)
      returning id into v_source_contact_id;

      insert into public.contact_methods(contact_id, type, value, is_primary)
      values (v_source_contact_id, 'email', v_email, true);
    end if;
  end if;

  insert into public.area_invites(
    area_id, recipient_email, first_name, last_name, expires_at,
    created_by_profile_id, target_managed_profile_id, source_contact_id
  )
  values (
    p_area_id, v_email, v_first_name, v_last_name, now() + interval '7 days',
    v_caller_profile_id, p_target_managed_profile_id, v_source_contact_id
  )
  returning id into v_invite_id;

  return v_invite_id;
end;
$$;

drop function public.get_my_contacts();

create function public.get_my_contacts()
returns table(
  id uuid,
  first_name text,
  last_name text,
  birth_date date,
  created_at timestamptz,
  updated_at timestamptz,
  pending_invites_count bigint
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
  select c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at,
         count(ai.id)::bigint
  from public.contacts c
  left join public.area_invites ai
    on ai.source_contact_id = c.id
   and ai.created_by_profile_id = v_owner_profile_id
   and ai.status = 'pending'
  where c.owner_profile_id = v_owner_profile_id
  group by c.id, c.first_name, c.last_name, c.birth_date, c.created_at, c.updated_at
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

revoke all on function public.create_area_invite(uuid, text, text, text, uuid) from public;
revoke all on function public.get_my_contacts() from public;
grant execute on function public.create_area_invite(uuid, text, text, text, uuid) to authenticated;
grant execute on function public.get_my_contacts() to authenticated;

commit;
