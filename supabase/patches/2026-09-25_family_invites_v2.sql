-- FamilArea — Famiglia V2, fase 1: inviti email-bound e membership confermata.
-- family_members resta la rubrica privata della famiglia; family_access registra solo accessi confermati.

alter table public.family_access drop constraint family_access_role_check;
alter table public.family_access add constraint family_access_role_check
  check (role in ('owner', 'adult', 'member'));

alter table public.contact_profile_links drop constraint contact_profile_links_linked_via_check;
alter table public.contact_profile_links add constraint contact_profile_links_linked_via_check
  check (linked_via in ('event_invite', 'verified', 'contact_share', 'family_invite'));

create unique index if not exists family_members_unique_linked_profile_per_family
  on public.family_members (family_id, linked_profile_id)
  where linked_profile_id is not null;

create table public.family_invites (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  family_member_id uuid not null references public.family_members(id) on delete cascade,
  inviter_account_id uuid not null references public.accounts(id) on delete restrict,
  recipient_email text not null,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'revoked', 'expired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  accepted_at timestamptz,
  accepted_by_profile_id uuid references public.profiles(id) on delete set null,
  declined_at timestamptz,
  declined_by_profile_id uuid references public.profiles(id) on delete set null,
  revoked_at timestamptz,
  check (recipient_email = public.normalize_contact_email(recipient_email)),
  check (expires_at > created_at)
);

create unique index family_invites_one_pending_member_recipient
  on public.family_invites (family_member_id, recipient_email)
  where status = 'pending';
create index family_invites_recipient_status_expires_idx
  on public.family_invites (recipient_email, status, expires_at);
create index family_invites_family_member_idx
  on public.family_invites (family_id, family_member_id);

alter table public.family_invites enable row level security;
revoke all on public.family_invites from public, anon, authenticated;

create or replace function public.create_family_invite(
  p_family_member_id uuid,
  p_recipient_email text,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_owner_account_id uuid;
  v_member public.family_members%rowtype;
  v_email text;
  v_expires_at timestamptz;
  v_invite public.family_invites%rowtype;
begin
  v_owner_account_id := public.require_personal_account();
  v_email := public.normalize_contact_email(p_recipient_email);
  v_expires_at := coalesce(p_expires_at, now() + interval '14 days');
  if v_expires_at <= now() then raise exception 'family invite expiry must be in the future'; end if;

  select fm.* into v_member
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_family_member_id and f.owner_account_id = v_owner_account_id
  for update of fm;
  if not found then raise exception 'family member unavailable'; end if;

  update public.family_invites
  set status = 'expired', updated_at = now()
  where family_member_id = v_member.id
    and recipient_email = v_email
    and status = 'pending'
    and expires_at <= now();

  if exists (
    select 1 from public.family_invites
    where family_member_id = v_member.id and recipient_email = v_email and status = 'pending'
  ) then
    raise exception 'family invite already pending';
  end if;

  insert into public.family_invites(family_id, family_member_id, inviter_account_id, recipient_email, expires_at)
  values(v_member.family_id, v_member.id, v_owner_account_id, v_email, v_expires_at)
  returning * into v_invite;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'family_id', v_invite.family_id,
    'family_member_id', v_invite.family_member_id,
    'recipient_email', v_invite.recipient_email,
    'status', v_invite.status,
    'created_at', v_invite.created_at,
    'expires_at', v_invite.expires_at
  );
end $$;

create or replace function public.get_my_family_invites()
returns table(
  invite_id uuid,
  family_id uuid,
  family_name text,
  inviter_account_id uuid,
  inviter_profile_id uuid,
  inviter_first_name text,
  inviter_last_name text,
  family_member_id uuid,
  relationship text,
  status text,
  created_at timestamptz,
  expires_at timestamptz
)
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_recipient record;
begin
  select * into v_recipient from public.contact_share_recipient_identity();
  update public.family_invites as fi
  set status = 'expired', updated_at = now()
  where fi.recipient_email = v_recipient.email and fi.status = 'pending' and fi.expires_at <= now();

  return query
  select fi.id, fi.family_id, f.name, fi.inviter_account_id, p.id, p.first_name, p.last_name,
         fi.family_member_id, fm.relationship, fi.status, fi.created_at, fi.expires_at
  from public.family_invites fi
  join public.families f on f.id = fi.family_id
  join public.family_members fm on fm.id = fi.family_member_id and fm.family_id = fi.family_id
  left join public.profiles p on p.account_id = fi.inviter_account_id
  where fi.recipient_email = v_recipient.email
  order by case when fi.status = 'pending' then 0 else 1 end, fi.created_at desc;
end $$;

create or replace function public.accept_my_family_invite(p_invite_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_recipient record;
  v_invite public.family_invites%rowtype;
  v_member public.family_members%rowtype;
  v_owner_account_id uuid;
  v_linked_profile_id uuid;
  v_existing_member_id uuid;
  v_has_email boolean;
begin
  select * into v_recipient from public.contact_share_recipient_identity();
  select * into v_invite from public.family_invites where id = p_invite_id for update;
  if not found then raise exception 'family invite unavailable'; end if;
  if v_invite.recipient_email <> v_recipient.email then raise exception 'family invite unavailable'; end if;

  if v_invite.status = 'accepted' and v_invite.accepted_by_profile_id = v_recipient.profile_id then
    return jsonb_build_object('invite_id', v_invite.id, 'family_id', v_invite.family_id, 'family_member_id', v_invite.family_member_id, 'status', 'accepted');
  end if;
  if v_invite.status <> 'pending' or v_invite.expires_at <= now() then raise exception 'family invite unavailable'; end if;

  select fm.* into v_member
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = v_invite.family_member_id and fm.family_id = v_invite.family_id
  for update of fm, f;
  if not found then raise exception 'family invite unavailable'; end if;
  select owner_account_id into v_owner_account_id
  from public.families
  where id = v_member.family_id;

  if v_member.linked_profile_id is not null and v_member.linked_profile_id <> v_recipient.profile_id then
    raise exception 'family member already linked to another profile';
  end if;
  select id into v_existing_member_id from public.family_members
  where family_id = v_invite.family_id and linked_profile_id = v_recipient.profile_id and id <> v_member.id
  limit 1;
  if v_existing_member_id is not null then raise exception 'profile already linked to another family member'; end if;

  if v_member.contact_id is not null then
    if not exists (
      select 1 from public.contacts c where c.id = v_member.contact_id and c.owner_account_id = v_owner_account_id
    ) then
      raise exception 'family contact unavailable';
    end if;
    select l.profile_id into v_linked_profile_id
    from public.contact_profile_links l
    where l.contact_id = v_member.contact_id and l.owner_account_id = v_owner_account_id
    for update;
    if v_linked_profile_id is not null and v_linked_profile_id <> v_recipient.profile_id then
      raise exception 'family contact already linked to another profile';
    end if;

    select exists(
      select 1 from public.contact_methods cm
      where cm.contact_id = v_member.contact_id
        and cm.method_type = 'email'
        and lower(btrim(cm.value)) = v_recipient.email
    ) into v_has_email;
    if not v_has_email then
      insert into public.contact_methods(contact_id, method_type, value, is_primary)
      values(
        v_member.contact_id,
        'email',
        v_recipient.email,
        not exists(select 1 from public.contact_methods cm where cm.contact_id = v_member.contact_id and cm.method_type = 'email')
      );
    end if;

    insert into public.contact_profile_links(contact_id, owner_account_id, profile_id, linked_via)
    values(v_member.contact_id, v_owner_account_id, v_recipient.profile_id, 'family_invite')
    on conflict do nothing;
    if not exists(
      select 1 from public.contact_profile_links l
      where l.contact_id = v_member.contact_id
        and l.owner_account_id = v_owner_account_id
        and l.profile_id = v_recipient.profile_id
    ) then
      raise exception 'family contact already linked to another profile';
    end if;
  end if;

  insert into public.family_access(family_id, profile_id, role)
  values(v_invite.family_id, v_recipient.profile_id, 'member')
  on conflict (family_id, profile_id) do nothing;

  update public.family_members
  set linked_profile_id = v_recipient.profile_id, updated_at = now()
  where id = v_member.id;
  update public.family_invites
  set status = 'accepted', updated_at = now(), accepted_at = now(), accepted_by_profile_id = v_recipient.profile_id
  where id = v_invite.id;

  return jsonb_build_object('invite_id', v_invite.id, 'family_id', v_invite.family_id, 'family_member_id', v_member.id, 'status', 'accepted');
end $$;

create or replace function public.decline_my_family_invite(p_invite_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_recipient record;
  v_invite public.family_invites%rowtype;
begin
  select * into v_recipient from public.contact_share_recipient_identity();
  select * into v_invite from public.family_invites where id = p_invite_id for update;
  if not found or v_invite.recipient_email <> v_recipient.email then raise exception 'family invite unavailable'; end if;
  if v_invite.status <> 'pending' or v_invite.expires_at <= now() then raise exception 'family invite unavailable'; end if;
  update public.family_invites
  set status = 'declined', updated_at = now(), declined_at = now(), declined_by_profile_id = v_recipient.profile_id
  where id = v_invite.id;
  return jsonb_build_object('invite_id', v_invite.id, 'status', 'declined');
end $$;

create or replace function public.revoke_family_invite(p_invite_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_owner_account_id uuid;
  v_invite public.family_invites%rowtype;
begin
  v_owner_account_id := public.require_personal_account();
  select fi.* into v_invite
  from public.family_invites fi
  join public.families f on f.id = fi.family_id
  where fi.id = p_invite_id and f.owner_account_id = v_owner_account_id
  for update of fi;
  if not found or v_invite.status <> 'pending' then raise exception 'family invite unavailable'; end if;
  update public.family_invites set status = 'revoked', updated_at = now(), revoked_at = now() where id = v_invite.id;
  return jsonb_build_object('invite_id', v_invite.id, 'status', 'revoked');
end $$;

alter function public.create_family_invite(uuid,text,timestamptz) owner to postgres;
alter function public.get_my_family_invites() owner to postgres;
alter function public.accept_my_family_invite(uuid) owner to postgres;
alter function public.decline_my_family_invite(uuid) owner to postgres;
alter function public.revoke_family_invite(uuid) owner to postgres;
revoke all on function public.create_family_invite(uuid,text,timestamptz), public.get_my_family_invites(), public.accept_my_family_invite(uuid), public.decline_my_family_invite(uuid), public.revoke_family_invite(uuid) from public, anon;
grant execute on function public.create_family_invite(uuid,text,timestamptz), public.get_my_family_invites(), public.accept_my_family_invite(uuid), public.decline_my_family_invite(uuid), public.revoke_family_invite(uuid) to authenticated;
