-- FamilArea — account-level Contact Share senders for Personal and Organization accounts.
-- Prerequisite: 2026-10-08_contact_share_inbox_decline.sql.
-- Keeps legacy profile/token flows while adding a canonical account link for contacts.

begin;

alter table public.contact_shares
  add column if not exists sender_account_id uuid references public.accounts(id) on delete cascade;

update public.contact_shares cs
set sender_account_id = p.account_id
from public.profiles p
where cs.sender_account_id is null
  and cs.sender_profile_id = p.id;

alter table public.contact_shares
  alter column sender_profile_id drop not null,
  alter column sender_account_id set not null;

drop index if exists public.contact_shares_one_pending_sender_recipient_idx;
create unique index if not exists contact_shares_one_pending_sender_account_recipient_idx
  on public.contact_shares(sender_account_id, recipient_email)
  where status = 'pending';

create table if not exists public.contact_account_links (
  contact_id uuid primary key,
  owner_account_id uuid not null,
  linked_account_id uuid not null references public.accounts(id) on delete cascade,
  linked_at timestamptz not null default now(),
  linked_via text not null check (linked_via in ('contact_share')),
  unique (owner_account_id, linked_account_id),
  foreign key (contact_id, owner_account_id)
    references public.contacts(id, owner_account_id) on delete cascade
);

alter table public.contact_account_links enable row level security;
revoke all on public.contact_account_links from public, anon, authenticated;

insert into public.contact_account_links(contact_id, owner_account_id, linked_account_id, linked_via)
select l.contact_id, l.owner_account_id, p.account_id, 'contact_share'
from public.contact_profile_links l
join public.profiles p on p.id = l.profile_id
on conflict do nothing;

create or replace function public.contact_share_sender_identity(p_account_id uuid)
returns table(
  account_id uuid,
  profile_id uuid,
  account_type text,
  email text,
  first_name text,
  last_name text,
  display_name text,
  phone text,
  avatar_path text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return query
  select
    a.id,
    p.id,
    a.account_type::text,
    public.normalize_contact_email(u.email),
    case when a.account_type = 'organization' then o.name else p.first_name end,
    case when a.account_type = 'organization' then null else p.last_name end,
    case
      when a.account_type = 'organization' then nullif(btrim(o.name), '')
      else nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '')
    end,
    case when a.account_type = 'organization' then nullif(btrim(o.contact_phone), '') else null end,
    case when a.account_type = 'organization' then o.avatar_path else p.avatar_path end
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  left join public.profiles p on p.account_id = a.id
  left join public.organizations o on o.account_id = a.id
  where a.id = p_account_id
    and a.account_type in ('personal', 'organization')
    and u.email_confirmed_at is not null
    and (
      (a.account_type = 'personal' and p.id is not null)
      or (a.account_type = 'organization' and o.id is not null)
    );
end;
$$;

create or replace function public.get_my_contact_share_identity()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sender record;
begin
  select * into v_sender
  from public.contact_share_sender_identity(public.require_current_account());
  if v_sender.account_id is null or v_sender.email is null or v_sender.display_name is null then
    raise exception 'verified account contact identity required';
  end if;
  return jsonb_build_object(
    'account_id', v_sender.account_id,
    'account_type', v_sender.account_type,
    'display_name', v_sender.display_name,
    'email', v_sender.email,
    'phone', v_sender.phone,
    'avatar_path', v_sender.avatar_path
  );
end;
$$;

create or replace function public.create_contact_share(p_recipient_email text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_sender record;
  v_email text;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_id uuid;
  v_expires_at timestamptz := now() + interval '14 days';
begin
  select * into v_sender
  from public.contact_share_sender_identity(public.require_current_account());
  if v_sender.account_id is null or v_sender.email is null then
    raise exception 'verified account contact identity required';
  end if;

  v_email := public.normalize_contact_email(p_recipient_email);
  if v_email = v_sender.email then
    raise exception 'cannot share with your own email';
  end if;

  update public.contact_shares
  set status = 'expired'
  where sender_account_id = v_sender.account_id
    and recipient_email = v_email
    and status = 'pending'
    and expires_at <= now();

  update public.contact_shares
  set status = 'revoked', revoked_at = now()
  where sender_account_id = v_sender.account_id
    and recipient_email = v_email
    and status = 'pending';

  insert into public.contact_shares(
    sender_account_id, sender_profile_id, recipient_email, token_hash, expires_at
  )
  values (
    v_sender.account_id, v_sender.profile_id, v_email,
    public.hash_contact_share_token(v_token), v_expires_at
  )
  returning id into v_id;

  return jsonb_build_object('share_id', v_id, 'token', v_token, 'expires_at', v_expires_at);
end;
$$;

create or replace function public.get_contact_share_for_recipient(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_share public.contact_shares%rowtype;
  v_sender record;
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();
  select * into v_share
  from public.contact_shares
  where token_hash = public.hash_contact_share_token(p_token)
  for update;
  if not found then raise exception 'contact share unavailable'; end if;

  if v_share.status = 'pending' and v_share.expires_at <= now() then
    update public.contact_shares set status = 'expired' where id = v_share.id;
    v_share.status := 'expired';
  end if;
  if v_share.status <> 'pending' or v_share.recipient_email <> v_recipient.email then
    raise exception 'contact share unavailable';
  end if;

  select * into v_sender from public.contact_share_sender_identity(v_share.sender_account_id);
  if v_sender.account_id is null then raise exception 'contact share unavailable'; end if;

  return jsonb_build_object(
    'first_name', v_sender.first_name,
    'last_name', v_sender.last_name,
    'display_name', v_sender.display_name,
    'email', v_sender.email,
    'phone', v_sender.phone,
    'expires_at', v_share.expires_at
  );
end;
$$;

create or replace function public.accept_contact_share_by_id_impl(
  p_share_id uuid,
  p_existing_contact_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_share public.contact_shares%rowtype;
  v_sender record;
  v_contact uuid;
  v_linked_account_id uuid;
  v_link_profile uuid;
  v_count integer;
  v_has_email boolean;
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();
  select * into v_share from public.contact_shares where id = p_share_id for update;
  if not found then raise exception 'contact share unavailable'; end if;
  if v_share.status <> 'pending'
     or v_share.expires_at <= now()
     or v_share.recipient_email <> v_recipient.email then
    raise exception 'contact share unavailable';
  end if;

  select * into v_sender from public.contact_share_sender_identity(v_share.sender_account_id);
  if v_sender.account_id is null or v_sender.email is null then
    raise exception 'contact share unavailable';
  end if;

  select contact_id into v_contact
  from public.contact_account_links
  where owner_account_id = v_recipient.account_id
    and linked_account_id = v_sender.account_id;

  if p_existing_contact_id is not null then
    if v_contact is not null and v_contact <> p_existing_contact_id then
      raise exception 'contact share conflict';
    end if;
    if not exists (
      select 1 from public.contacts c
      where c.id = p_existing_contact_id
        and c.owner_account_id = v_recipient.account_id
    ) then
      raise exception 'selected contact unavailable';
    end if;
    select linked_account_id into v_linked_account_id
    from public.contact_account_links
    where contact_id = p_existing_contact_id;
    if v_linked_account_id is not null and v_linked_account_id <> v_sender.account_id then
      raise exception 'contact share conflict';
    end if;
    if v_sender.profile_id is not null then
      select profile_id into v_link_profile
      from public.contact_profile_links
      where contact_id = p_existing_contact_id;
      if v_link_profile is not null and v_link_profile <> v_sender.profile_id then
        raise exception 'contact share conflict';
      end if;
    end if;
    v_contact := p_existing_contact_id;
  elsif v_contact is null then
    select count(distinct c.id), min(c.id::text)::uuid
    into v_count, v_contact
    from public.contacts c
    join public.contact_methods m on m.contact_id = c.id
    where c.owner_account_id = v_recipient.account_id
      and m.method_type = 'email'
      and lower(btrim(m.value)) = v_sender.email;
    if v_count > 1 then raise exception 'contact share conflict'; end if;
    if v_contact is null then
      insert into public.contacts(owner_account_id, first_name, last_name)
      values (v_recipient.account_id, v_sender.first_name, nullif(v_sender.last_name, ''))
      returning id into v_contact;
    else
      select linked_account_id into v_linked_account_id
      from public.contact_account_links
      where contact_id = v_contact;
      if v_linked_account_id is not null and v_linked_account_id <> v_sender.account_id then
        raise exception 'contact share conflict';
      end if;
    end if;
  end if;

  select exists (
    select 1 from public.contact_methods
    where contact_id = v_contact
      and method_type = 'email'
      and lower(btrim(value)) = v_sender.email
  ) into v_has_email;
  if not v_has_email then
    insert into public.contact_methods(contact_id, method_type, value, is_primary)
    values (
      v_contact, 'email', v_sender.email,
      not exists (select 1 from public.contact_methods where contact_id = v_contact and method_type = 'email')
    );
  end if;

  if v_sender.phone is not null and not exists (
    select 1 from public.contact_methods
    where contact_id = v_contact and method_type = 'phone' and btrim(value) = v_sender.phone
  ) then
    insert into public.contact_methods(contact_id, method_type, value, is_primary)
    values (
      v_contact, 'phone', v_sender.phone,
      not exists (select 1 from public.contact_methods where contact_id = v_contact and method_type = 'phone')
    );
  end if;

  insert into public.contact_account_links(contact_id, owner_account_id, linked_account_id, linked_via)
  values (v_contact, v_recipient.account_id, v_sender.account_id, 'contact_share')
  on conflict do nothing;
  if not exists (
    select 1 from public.contact_account_links
    where contact_id = v_contact
      and owner_account_id = v_recipient.account_id
      and linked_account_id = v_sender.account_id
  ) then
    raise exception 'contact share conflict';
  end if;

  if v_sender.profile_id is not null then
    insert into public.contact_profile_links(contact_id, owner_account_id, profile_id, linked_via)
    values (v_contact, v_recipient.account_id, v_sender.profile_id, 'contact_share')
    on conflict do nothing;
    if not exists (
      select 1 from public.contact_profile_links
      where contact_id = v_contact
        and owner_account_id = v_recipient.account_id
        and profile_id = v_sender.profile_id
    ) then
      raise exception 'contact share conflict';
    end if;
  end if;

  update public.contact_shares
  set status = 'completed',
      completed_at = now(),
      completed_by_profile_id = v_recipient.profile_id,
      completed_by_account_id = v_recipient.account_id
  where id = v_share.id;

  return jsonb_build_object('contact_id', v_contact);
end;
$$;

create or replace function public.get_my_contact_share_invites()
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();

  update public.contact_shares
  set status = 'expired'
  where recipient_email = v_recipient.email
    and status = 'pending'
    and expires_at <= now();

  return query
  select jsonb_build_object(
    'share_id', cs.id,
    'sender_account_id', sender.account_id,
    'sender_account_type', sender.account_type,
    'sender_first_name', sender.first_name,
    'sender_last_name', sender.last_name,
    'sender_display_name', sender.display_name,
    'sender_email', sender.email,
    'sender_avatar_path', sender.avatar_path,
    'status', cs.status,
    'created_at', cs.created_at,
    'expires_at', cs.expires_at
  )
  from public.contact_shares cs
  join lateral public.contact_share_sender_identity(cs.sender_account_id) sender on true
  where cs.recipient_email = v_recipient.email
    and cs.status = 'pending'
    and cs.expires_at > now()
  order by cs.created_at desc, cs.id;
end;
$$;

create or replace function public.revoke_contact_share(p_share_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sender record;
begin
  select * into v_sender
  from public.contact_share_sender_identity(public.require_current_account());
  if v_sender.account_id is null then raise exception 'verified account contact identity required'; end if;

  update public.contact_shares
  set status = 'revoked', revoked_at = now()
  where id = p_share_id
    and sender_account_id = v_sender.account_id
    and status = 'pending'
    and expires_at > now();
  if not found then raise exception 'contact share unavailable'; end if;
end;
$$;

create or replace function public.get_my_pending_contact_shares()
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sender record;
begin
  select * into v_sender
  from public.contact_share_sender_identity(public.require_current_account());
  if v_sender.account_id is null then raise exception 'verified account contact identity required'; end if;

  update public.contact_shares
  set status = 'expired'
  where sender_account_id = v_sender.account_id
    and status = 'pending'
    and expires_at <= now();

  return query
  select jsonb_build_object(
    'share_id', id,
    'recipient_email', recipient_email,
    'expires_at', expires_at
  )
  from public.contact_shares
  where sender_account_id = v_sender.account_id
    and status = 'pending'
  order by created_at desc;
end;
$$;

alter function public.contact_share_sender_identity(uuid) owner to postgres;
alter function public.get_my_contact_share_identity() owner to postgres;
alter function public.create_contact_share(text) owner to postgres;
alter function public.get_contact_share_for_recipient(text) owner to postgres;
alter function public.accept_contact_share_by_id_impl(uuid, uuid) owner to postgres;
alter function public.get_my_contact_share_invites() owner to postgres;
alter function public.revoke_contact_share(uuid) owner to postgres;
alter function public.get_my_pending_contact_shares() owner to postgres;

revoke all on function public.contact_share_sender_identity(uuid) from public, anon, authenticated;
revoke all on function public.accept_contact_share_by_id_impl(uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_my_contact_share_identity() from public, anon;
revoke all on function public.create_contact_share(text), public.get_contact_share_for_recipient(text), public.accept_contact_share(text), public.accept_contact_share(text, uuid), public.revoke_contact_share(uuid), public.get_my_pending_contact_shares() from public, anon;
grant execute on function public.get_my_contact_share_identity() to authenticated;
grant execute on function public.create_contact_share(text), public.get_contact_share_for_recipient(text), public.accept_contact_share(text), public.accept_contact_share(text, uuid), public.revoke_contact_share(uuid), public.get_my_pending_contact_shares() to authenticated;

commit;
