-- =============================================================================
-- FamilArea - inviti alle Aree, fase 1
-- =============================================================================
-- Questa fase non collega e non converte profili managed o derivati da Contatti.

begin;

create table public.area_invites (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(id) on delete cascade,
  recipient_email text not null
    check (
      recipient_email = lower(btrim(recipient_email))
      and recipient_email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
    ),
  first_name text check (first_name is null or (first_name = btrim(first_name) and char_length(first_name) > 0)),
  last_name text check (last_name is null or (last_name = btrim(last_name) and char_length(last_name) > 0)),
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'revoked', 'expired')),
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

create unique index area_invites_one_pending_email_per_area_idx
  on public.area_invites(area_id, recipient_email)
  where status = 'pending';
create index area_invites_recipient_status_idx
  on public.area_invites(recipient_email, status, expires_at, created_at desc);
create index area_invites_area_status_idx
  on public.area_invites(area_id, status, created_at desc);

alter table public.area_invites enable row level security;
alter table public.area_invites no force row level security;
revoke all on public.area_invites from public, authenticated;

create function public.create_area_invite(
  p_area_id uuid,
  p_email text,
  p_first_name text default null,
  p_last_name text default null
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
  if not found then raise exception 'Area non trovata'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role = 'admin'
  ) then raise exception 'permission denied'; end if;

  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Email non valida';
  end if;

  -- Gli inviti scaduti non sono piu' pending e non bloccano un reinvito.
  update public.area_invites
  set status = 'expired'
  where area_id = p_area_id
    and recipient_email = v_email
    and status = 'pending'
    and expires_at <= now();

  -- Il messaggio non distingue un'email non registrata da un account esistente.
  if exists (
    select 1
    from auth.users u
    join public.profiles p on p.user_id = u.id
    join public.area_memberships am on am.profile_id = p.id
    where lower(btrim(u.email)) = v_email
      and am.area_id = p_area_id
      and am.role in ('admin', 'member')
  ) then raise exception 'Impossibile creare l''invito per questo indirizzo'; end if;

  if exists (
    select 1 from public.area_invites ai
    where ai.area_id = p_area_id
      and ai.recipient_email = v_email
      and ai.status = 'pending'
  ) then raise exception 'Esiste gia'' un invito in attesa per questo indirizzo'; end if;

  insert into public.area_invites(
    area_id, recipient_email, first_name, last_name, expires_at, created_by_profile_id
  ) values (
    p_area_id,
    v_email,
    nullif(btrim(coalesce(p_first_name, '')), ''),
    nullif(btrim(coalesce(p_last_name, '')), ''),
    now() + interval '7 days',
    v_caller_profile_id
  ) returning id into v_invite_id;

  return v_invite_id;
end;
$$;

create function public.get_area_invites(p_area_id uuid)
returns table(
  invite_id uuid,
  recipient_email text,
  first_name text,
  last_name text,
  status text,
  expires_at timestamptz,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin'
  ) then raise exception 'permission denied'; end if;

  return query
  select ai.id, ai.recipient_email, ai.first_name, ai.last_name,
    case when ai.status = 'pending' and ai.expires_at <= now() then 'expired' else ai.status end,
    ai.expires_at, ai.created_at
  from public.area_invites ai
  where ai.area_id = p_area_id
  order by ai.created_at desc, ai.id;
end;
$$;

create function public.revoke_area_invite(p_area_id uuid, p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_caller_profile_id uuid; v_status text;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin'
  ) then raise exception 'permission denied'; end if;

  update public.area_invites
  set status = 'expired'
  where id = p_invite_id and area_id = p_area_id and status = 'pending' and expires_at <= now();

  select ai.status into v_status
  from public.area_invites ai
  where ai.id = p_invite_id and ai.area_id = p_area_id
  for update;
  if not found then raise exception 'Invito non trovato in questa Area'; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' piu'' revocabile'; end if;

  update public.area_invites
  set status = 'revoked', revoked_at = now(), revoked_by_profile_id = v_caller_profile_id
  where id = p_invite_id and area_id = p_area_id;
end;
$$;

create function public.get_my_area_invites()
returns table(
  invite_id uuid,
  area_id uuid,
  area_name text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  inviter_first_name text,
  inviter_last_name text
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
    ai.expires_at, ai.created_at, inviter.first_name, inviter.last_name
  from public.area_invites ai
  join public.areas a on a.id = ai.area_id
  join public.profiles inviter on inviter.id = ai.created_by_profile_id
  where ai.recipient_email = v_email
  order by
    case when ai.status = 'pending' and ai.expires_at > now() then 0 else 1 end,
    ai.created_at desc,
    ai.id;
end;
$$;

create function public.accept_area_invite(p_invite_id uuid)
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
  v_membership_role text;
begin
  select p.id, lower(btrim(u.email)) into v_caller_profile_id, v_email
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_caller_profile_id is null or v_email is null then
    raise exception 'Email dell''account non verificata o profilo non trovato';
  end if;

  -- Lettura iniziale solo per ottenere l'Area; la riga viene riletta dopo il lock Area.
  select ai.area_id into v_area_id from public.area_invites ai where ai.id = p_invite_id;
  if v_area_id is null then raise exception 'Invito non trovato'; end if;
  perform 1 from public.areas where id = v_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;

  update public.area_invites
  set status = 'expired'
  where id = p_invite_id and area_id = v_area_id and status = 'pending' and expires_at <= now();

  select ai.recipient_email, ai.status, ai.expires_at, ai.accepted_by_profile_id
  into v_recipient_email, v_status, v_expires_at, v_accepted_by_profile_id
  from public.area_invites ai
  where ai.id = p_invite_id and ai.area_id = v_area_id
  for update;
  if not found then raise exception 'Invito non trovato'; end if;
  if v_recipient_email <> v_email then raise exception 'permission denied'; end if;
  if v_status = 'accepted' and v_accepted_by_profile_id = v_caller_profile_id then return; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' accettabile'; end if;
  if v_expires_at <= now() then raise exception 'Invito scaduto'; end if;

  perform 1 from public.profiles p where p.id = v_caller_profile_id for update;
  if not found then raise exception 'Profilo non trovato'; end if;
  select am.role into v_membership_role
  from public.area_memberships am
  where am.area_id = v_area_id and am.profile_id = v_caller_profile_id
  for update;

  if v_membership_role is null then
    insert into public.area_memberships(area_id, profile_id, role)
    values (v_area_id, v_caller_profile_id, 'member');
  elsif v_membership_role = 'managed' then
    -- Non modifica altri profili managed: riguarda solo il profilo del chiamante.
    update public.area_memberships
    set role = 'member'
    where area_id = v_area_id and profile_id = v_caller_profile_id;
  end if;

  update public.area_invites
  set status = 'accepted', responded_at = now(), accepted_by_profile_id = v_caller_profile_id
  where id = p_invite_id and area_id = v_area_id;
end;
$$;

create function public.decline_area_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_email text; v_area_id uuid; v_recipient_email text; v_status text;
begin
  select lower(btrim(u.email)) into v_email
  from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then raise exception 'Email dell''account non verificata'; end if;

  select ai.area_id into v_area_id from public.area_invites ai where ai.id = p_invite_id;
  if v_area_id is null then raise exception 'Invito non trovato'; end if;
  perform 1 from public.areas where id = v_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;

  update public.area_invites
  set status = 'expired'
  where id = p_invite_id and area_id = v_area_id and status = 'pending' and expires_at <= now();

  select ai.recipient_email, ai.status into v_recipient_email, v_status
  from public.area_invites ai
  where ai.id = p_invite_id and ai.area_id = v_area_id
  for update;
  if not found then raise exception 'Invito non trovato'; end if;
  if v_recipient_email <> v_email then raise exception 'permission denied'; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' rifiutabile'; end if;

  update public.area_invites
  set status = 'declined', responded_at = now()
  where id = p_invite_id and area_id = v_area_id;
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

commit;
