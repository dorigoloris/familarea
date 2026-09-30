-- FamilArea — Persona assistita: membro non digitale gestito nella Famiglia.
-- Signature account-based: corrispondono alle RPC invocate dal frontend corrente.

begin;

alter table public.family_members
  drop constraint if exists family_members_member_type_check;

alter table public.family_members
  add constraint family_members_member_type_check
  check (member_type in ('person', 'pet', 'assisted_person'));

alter table public.family_members
  add constraint family_members_assisted_person_check check (
    member_type <> 'assisted_person'
    or (
      linked_profile_id is null
      and contact_id is null
      and pet_species is null
    )
  );

create or replace function public.create_family_member(
  p_first_name text,
  p_relationship text,
  p_member_type text default 'person',
  p_last_name text default null,
  p_birth_date date default null,
  p_pet_species text default null,
  p_contact_id uuid default null
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_family uuid;
  v_member_id uuid;
begin
  select id into v_family from public.families where owner_account_id = public.require_personal_account();
  if v_family is null then raise exception 'family not found'; end if;
  if p_member_type = 'assisted_person' and p_contact_id is not null then raise exception 'an assisted person cannot be linked to a contact'; end if;
  if p_member_type = 'assisted_person' and nullif(btrim(p_pet_species), '') is not null then raise exception 'an assisted person cannot have a pet species'; end if;
  if p_contact_id is not null and not exists(select 1 from public.contacts c where c.id = p_contact_id and c.owner_account_id = public.require_personal_account()) then raise exception 'invalid contact'; end if;
  if p_contact_id is not null and exists(select 1 from public.family_members fm where fm.family_id = v_family and fm.contact_id = p_contact_id) then raise exception 'Questo contatto fa gia parte della Famiglia.'; end if;
  insert into public.family_members(family_id,first_name,last_name,relationship,member_type,birth_date,pet_species,contact_id)
  values(
    v_family, nullif(btrim(p_first_name), ''), nullif(btrim(p_last_name), ''), nullif(btrim(p_relationship), ''),
    p_member_type, p_birth_date,
    nullif(btrim(p_pet_species), ''),
    p_contact_id
  ) returning id into v_member_id;
  return v_member_id;
exception when unique_violation then raise exception 'Questo contatto fa gia parte della Famiglia.';
end $$;

create or replace function public.update_family_member(
  p_member_id uuid,
  p_first_name text,
  p_relationship text,
  p_member_type text,
  p_last_name text default null,
  p_birth_date date default null,
  p_pet_species text default null,
  p_contact_id uuid default null
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v public.family_members%rowtype;
  v_family uuid;
begin
  select id into v_family from public.families where owner_account_id = public.require_personal_account();
  if v_family is null then raise exception 'family not found'; end if;
  if p_member_type = 'assisted_person' and p_contact_id is not null then raise exception 'an assisted person cannot be linked to a contact'; end if;
  if p_member_type = 'assisted_person' and nullif(btrim(p_pet_species), '') is not null then raise exception 'an assisted person cannot have a pet species'; end if;
  if p_contact_id is not null and not exists(select 1 from public.contacts c where c.id = p_contact_id and c.owner_account_id = public.require_personal_account()) then raise exception 'invalid contact'; end if;
  if p_contact_id is not null and exists(select 1 from public.family_members fm where fm.family_id = v_family and fm.contact_id = p_contact_id and fm.id <> p_member_id) then raise exception 'Questo contatto fa gia parte della Famiglia.'; end if;
  update public.family_members fm
  set first_name = nullif(btrim(p_first_name), ''),
      last_name = nullif(btrim(p_last_name), ''),
      relationship = nullif(btrim(p_relationship), ''),
      member_type = p_member_type,
      birth_date = p_birth_date,
      pet_species = nullif(btrim(p_pet_species), ''),
      contact_id = p_contact_id
  where fm.id = p_member_id and fm.family_id = v_family
  returning fm.* into v;
  if not found then raise exception 'permission denied'; end if;
  return to_jsonb(v);
exception when unique_violation then raise exception 'Questo contatto fa gia parte della Famiglia.';
end $$;

create or replace function public.create_family_invite(
  p_family_member_id uuid,
  p_recipient_email text,
  p_expires_at timestamptz default null
) returns jsonb
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
  select fm.* into v_member from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_family_member_id and f.owner_account_id = v_owner_account_id for update of fm;
  if not found or v_member.member_type <> 'person' then raise exception 'only a person can receive a family invite'; end if;
  update public.family_invites set status = 'expired', updated_at = now()
  where family_member_id = v_member.id and recipient_email = v_email and status = 'pending' and expires_at <= now();
  if exists (select 1 from public.family_invites where family_member_id = v_member.id and recipient_email = v_email and status = 'pending') then raise exception 'family invite already pending'; end if;
  insert into public.family_invites(family_id, family_member_id, inviter_account_id, recipient_email, expires_at)
  values(v_member.family_id, v_member.id, v_owner_account_id, v_email, v_expires_at) returning * into v_invite;
  return jsonb_build_object(
    'invite_id', v_invite.id, 'family_id', v_invite.family_id, 'family_member_id', v_invite.family_member_id,
    'recipient_email', v_invite.recipient_email, 'status', v_invite.status, 'created_at', v_invite.created_at,
    'expires_at', v_invite.expires_at
  );
end $$;

-- Gli inviti legacy per soggetti non digitali non devono restare accettabili.
update public.family_invites fi
set status = 'revoked', updated_at = now(), revoked_at = now()
from public.family_members fm
where fi.family_member_id = fm.id
  and fi.family_id = fm.family_id
  and fi.status = 'pending'
  and fm.member_type <> 'person';

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
  if v_member.member_type <> 'person' then raise exception 'only a person can accept a family invite'; end if;
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

alter function public.create_family_member(text,text,text,text,date,text,uuid) owner to postgres;
alter function public.update_family_member(uuid,text,text,text,text,date,text,uuid) owner to postgres;
alter function public.create_family_invite(uuid,text,timestamptz) owner to postgres;
alter function public.accept_my_family_invite(uuid) owner to postgres;
revoke all on function public.create_family_member(text,text,text,text,date,text,uuid), public.update_family_member(uuid,text,text,text,text,date,text,uuid), public.create_family_invite(uuid,text,timestamptz), public.accept_my_family_invite(uuid) from public, anon;
grant execute on function public.create_family_member(text,text,text,text,date,text,uuid), public.update_family_member(uuid,text,text,text,text,date,text,uuid), public.create_family_invite(uuid,text,timestamptz), public.accept_my_family_invite(uuid) to authenticated;

commit;
