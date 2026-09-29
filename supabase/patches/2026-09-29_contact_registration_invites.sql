-- FamilArea — inviti di registrazione collegati a un Contact privato.
-- V1: il consumo richiede token, account personale, email corrispondente e Profile.
-- L'obbligo di email verificata è isolato nella funzione dedicata per il futuro
-- passaggio a Confirm email senza modificare il modello dell'invito.

begin;

alter table public.contact_profile_links
  drop constraint contact_profile_links_linked_via_check;

alter table public.contact_profile_links
  add constraint contact_profile_links_linked_via_check
  check (linked_via in (
    'event_invite',
    'verified',
    'contact_share',
    'family_invite',
    'contact_suggestion',
    'contact_registration_invite'
  ));

create table public.contact_registration_invites (
  id uuid primary key default gen_random_uuid(),
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  contact_id uuid not null,
  recipient_email text not null
    check (recipient_email = public.normalize_contact_email(recipient_email)),
  token_hash text not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'revoked', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  completed_at timestamptz,
  completed_by_profile_id uuid references public.profiles(id) on delete set null,
  revoked_at timestamptz,
  constraint contact_registration_invites_contact_owner_fkey
    foreign key (contact_id, owner_account_id)
    references public.contacts(id, owner_account_id)
    on delete cascade,
  constraint contact_registration_invites_expiration_check
    check (expires_at > created_at),
  constraint contact_registration_invites_completed_check
    check ((status = 'completed') = (completed_at is not null and completed_by_profile_id is not null)),
  constraint contact_registration_invites_revoked_check
    check ((status = 'revoked') = (revoked_at is not null))
);

create unique index contact_registration_invites_one_pending_contact_email_idx
  on public.contact_registration_invites(contact_id, recipient_email)
  where status = 'pending';

create index contact_registration_invites_recipient_status_expires_idx
  on public.contact_registration_invites(recipient_email, status, expires_at, created_at desc);

alter table public.contact_registration_invites enable row level security;
revoke all on public.contact_registration_invites from public, anon, authenticated;

create function public.hash_contact_registration_invite_token(p_token text)
returns text
language sql
immutable
set search_path = public, extensions, pg_temp
as $$
  select encode(extensions.digest(convert_to(coalesce(p_token, ''), 'UTF8'), 'sha256'), 'hex')
$$;

-- Future hardening seam: after enabling Confirm email, redefine only this
-- function to return true. All consuming code already evaluates it.
create function public.contact_registration_invite_requires_verified_email()
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$ select false $$;

create function public.create_contact_registration_invite(
  p_contact_id uuid,
  p_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_recipient_email text;
  v_invite public.contact_registration_invites%rowtype;
  v_sender_name text;
begin
  if p_contact_id is null or coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'contact registration invite unavailable';
  end if;

  select public.normalize_contact_email(cm.value)
  into v_recipient_email
  from public.contacts c
  join public.contact_methods cm on cm.contact_id = c.id and cm.method_type = 'email'
  where c.id = p_contact_id
    and c.owner_account_id = v_owner_account_id
  order by cm.is_primary desc, cm.id
  limit 1
  for update of c;

  if v_recipient_email is null then
    raise exception 'contact registration invite email unavailable';
  end if;

  update public.contact_registration_invites cri
  set status = 'revoked', revoked_at = now()
  where cri.contact_id = p_contact_id
    and cri.recipient_email = v_recipient_email
    and cri.status = 'pending';

  insert into public.contact_registration_invites(
    owner_account_id, contact_id, recipient_email, token_hash
  ) values (
    v_owner_account_id, p_contact_id, v_recipient_email, p_token_hash
  ) returning * into v_invite;

  select coalesce(
    o.name,
    nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''),
    'Un utente FamilArea'
  ) into v_sender_name
  from public.accounts a
  left join public.organizations o on o.account_id = a.id
  left join public.profiles p on p.account_id = a.id
  where a.id = v_owner_account_id;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'recipient_email', v_invite.recipient_email,
    'sender_name', v_sender_name,
    'expires_at', v_invite.expires_at
  );
end;
$$;

-- This is intentionally the only anonymous surface: possession of the opaque
-- token reveals only the email that was invited, never Contact or sender data.
create function public.get_contact_registration_invite_context(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invite public.contact_registration_invites%rowtype;
begin
  if nullif(btrim(coalesce(p_token, '')), '') is null then
    raise exception 'contact registration invite unavailable';
  end if;

  select * into v_invite
  from public.contact_registration_invites
  where token_hash = public.hash_contact_registration_invite_token(p_token)
  for update;

  if not found then
    raise exception 'contact registration invite unavailable';
  end if;

  if v_invite.status = 'pending' and v_invite.expires_at <= now() then
    update public.contact_registration_invites
    set status = 'expired'
    where id = v_invite.id;
    v_invite.status := 'expired';
  end if;

  if v_invite.status <> 'pending' then
    raise exception 'contact registration invite unavailable';
  end if;

  return jsonb_build_object(
    'recipient_email', v_invite.recipient_email,
    'expires_at', v_invite.expires_at
  );
end;
$$;

create function public.consume_contact_registration_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_profile_id uuid;
  v_email text;
  v_email_confirmed_at timestamptz;
  v_invite public.contact_registration_invites%rowtype;
  v_linked_profile_id uuid;
begin
  select p.id, public.normalize_contact_email(u.email), u.email_confirmed_at
  into v_profile_id, v_email, v_email_confirmed_at
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  join public.profiles p on p.account_id = a.id
  where a.id = v_account_id
    and a.auth_user_id = auth.uid()
    and a.account_type = 'personal';

  if v_profile_id is null then
    raise exception 'contact registration invite unavailable';
  end if;

  if public.contact_registration_invite_requires_verified_email()
     and v_email_confirmed_at is null then
    raise exception 'verified email required';
  end if;

  select * into v_invite
  from public.contact_registration_invites
  where token_hash = public.hash_contact_registration_invite_token(p_token)
  for update;

  if not found then
    raise exception 'contact registration invite unavailable';
  end if;

  if v_invite.status = 'completed' then
    if v_invite.completed_by_profile_id = v_profile_id then
      return jsonb_build_object('contact_id', v_invite.contact_id, 'already_completed', true);
    end if;
    raise exception 'contact registration invite unavailable';
  end if;

  if v_invite.status = 'pending' and v_invite.expires_at <= now() then
    update public.contact_registration_invites
    set status = 'expired'
    where id = v_invite.id;
    v_invite.status := 'expired';
  end if;

  if v_invite.status <> 'pending'
     or v_invite.recipient_email <> v_email
     or not exists (
       select 1
       from public.contacts c
       where c.id = v_invite.contact_id
         and c.owner_account_id = v_invite.owner_account_id
     ) then
    raise exception 'contact registration invite unavailable';
  end if;

  select cpl.profile_id
  into v_linked_profile_id
  from public.contact_profile_links cpl
  where cpl.contact_id = v_invite.contact_id
  for update;

  if v_linked_profile_id is not null and v_linked_profile_id <> v_profile_id then
    raise exception 'contact/profile link conflict';
  end if;

  if v_linked_profile_id is null then
    if exists (
      select 1
      from public.contact_profile_links cpl
      where cpl.owner_account_id = v_invite.owner_account_id
        and cpl.profile_id = v_profile_id
        and cpl.contact_id <> v_invite.contact_id
    ) then
      raise exception 'contact/profile link conflict';
    end if;

    insert into public.contact_profile_links(
      contact_id, owner_account_id, profile_id, linked_via
    ) values (
      v_invite.contact_id,
      v_invite.owner_account_id,
      v_profile_id,
      'contact_registration_invite'
    ) on conflict (contact_id) do nothing;

    select cpl.profile_id
    into v_linked_profile_id
    from public.contact_profile_links cpl
    where cpl.contact_id = v_invite.contact_id;

    if v_linked_profile_id <> v_profile_id then
      raise exception 'contact/profile link conflict';
    end if;
  end if;

  update public.contact_registration_invites
  set status = 'completed',
      completed_at = now(),
      completed_by_profile_id = v_profile_id
  where id = v_invite.id;

  return jsonb_build_object('contact_id', v_invite.contact_id, 'already_completed', false);
end;
$$;

create function public.revoke_contact_registration_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  update public.contact_registration_invites
  set status = 'revoked', revoked_at = now()
  where id = p_invite_id
    and owner_account_id = v_owner_account_id
    and status = 'pending';

  if not found then
    raise exception 'contact registration invite unavailable';
  end if;
end;
$$;

revoke all on function public.hash_contact_registration_invite_token(text),
  public.contact_registration_invite_requires_verified_email() from public, anon, authenticated;
revoke all on function public.create_contact_registration_invite(uuid, text),
  public.get_contact_registration_invite_context(text),
  public.consume_contact_registration_invite(text),
  public.revoke_contact_registration_invite(uuid) from public, anon;

grant execute on function public.create_contact_registration_invite(uuid, text),
  public.consume_contact_registration_invite(text),
  public.revoke_contact_registration_invite(uuid) to authenticated;
grant execute on function public.get_contact_registration_invite_context(text) to anon, authenticated;

alter function public.hash_contact_registration_invite_token(text) owner to postgres;
alter function public.contact_registration_invite_requires_verified_email() owner to postgres;
alter function public.create_contact_registration_invite(uuid, text) owner to postgres;
alter function public.get_contact_registration_invite_context(text) owner to postgres;
alter function public.consume_contact_registration_invite(text) owner to postgres;
alter function public.revoke_contact_registration_invite(uuid) owner to postgres;

commit;
