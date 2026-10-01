-- FamilArea — gestione collaborativa della Famiglia.
-- Owner, member e adult possono svolgere operazioni operative; la proprietà resta owner-only.

begin;

create or replace function public.can_manage_family(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with caller as (
    select public.require_personal_account() as account_id
  ), caller_profile as (
    select p.id
    from public.profiles p
    join caller c on c.account_id = p.account_id
  )
  select p_family_id is not null and exists (
    select 1
    from public.families f
    cross join caller c
    where f.id = p_family_id
      and (
        f.owner_account_id = c.account_id
        or exists (
          select 1
          from public.family_access fa
          join caller_profile cp on cp.id = fa.profile_id
          where fa.family_id = f.id
            and fa.role in ('member', 'adult')
        )
      )
  );
$$;

create or replace function public.require_manage_family(p_family_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.can_manage_family(p_family_id) then
    raise exception 'permission denied';
  end if;
end;
$$;

create or replace function public.assert_manage_owned_family_member(
  p_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_family_id uuid;
begin
  if p_member_id is null then
    raise exception 'family member unavailable';
  end if;

  select fm.family_id into v_family_id
  from public.family_members fm
  where fm.id = p_member_id;

  if v_family_id is null then
    raise exception 'family member unavailable';
  end if;

  perform public.require_manage_family(v_family_id);
end;
$$;

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
  v_actor_account_id uuid := public.require_personal_account();
  v_family uuid;
  v_is_owner boolean;
  v_member_id uuid;
begin
  select f.id, (f.owner_account_id = v_actor_account_id)
    into v_family, v_is_owner
  from public.families f
  left join public.profiles p on p.account_id = v_actor_account_id
  left join public.family_access fa
    on fa.family_id = f.id
   and fa.profile_id = p.id
   and fa.role in ('member', 'adult')
  where f.owner_account_id = v_actor_account_id
     or fa.profile_id is not null
  order by (f.owner_account_id = v_actor_account_id) desc, f.created_at
  limit 1;

  if v_family is null then raise exception 'family not found'; end if;
  perform public.require_manage_family(v_family);

  if not v_is_owner and p_contact_id is not null then
    raise exception 'contacts may only be managed by the family owner';
  end if;
  if p_member_type = 'assisted_person' and p_contact_id is not null then raise exception 'an assisted person cannot be linked to a contact'; end if;
  if p_member_type = 'assisted_person' and nullif(btrim(p_pet_species), '') is not null then raise exception 'an assisted person cannot have a pet species'; end if;
  if p_contact_id is not null and not exists(select 1 from public.contacts c where c.id = p_contact_id and c.owner_account_id = v_actor_account_id) then raise exception 'invalid contact'; end if;
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
  v_actor_account_id uuid := public.require_personal_account();
  v_actor_profile_id uuid;
  v_owner_profile_id uuid;
  v_member public.family_members%rowtype;
  v_owner_account_id uuid;
  v_is_owner boolean;
  v_effective_contact_id uuid;
begin
  select fm.*
    into v_member
  from public.family_members fm
  where fm.id = p_member_id
  for update of fm;
  if not found then raise exception 'permission denied'; end if;
  select f.owner_account_id into v_owner_account_id
  from public.families f
  where f.id = v_member.family_id;

  perform public.require_manage_family(v_member.family_id);
  v_is_owner := v_owner_account_id = v_actor_account_id;
  select p.id into v_actor_profile_id from public.profiles p where p.account_id = v_actor_account_id;
  select p.id into v_owner_profile_id from public.profiles p where p.account_id = v_owner_account_id;

  if v_member.linked_profile_id is not null
     and (v_member.linked_profile_id = v_actor_profile_id or v_member.linked_profile_id = v_owner_profile_id) then
    raise exception 'family member cannot be modified';
  end if;

  -- I contatti appartengono all'owner: un gestore non-owner non può modificarne il collegamento.
  v_effective_contact_id := case when v_is_owner then p_contact_id else v_member.contact_id end;
  if p_member_type = 'assisted_person' and v_effective_contact_id is not null then raise exception 'an assisted person cannot be linked to a contact'; end if;
  if p_member_type = 'assisted_person' and nullif(btrim(p_pet_species), '') is not null then raise exception 'an assisted person cannot have a pet species'; end if;
  if v_is_owner and v_effective_contact_id is not null and not exists(select 1 from public.contacts c where c.id = v_effective_contact_id and c.owner_account_id = v_actor_account_id) then raise exception 'invalid contact'; end if;
  if v_is_owner and v_effective_contact_id is not null and exists(select 1 from public.family_members fm where fm.family_id = v_member.family_id and fm.contact_id = v_effective_contact_id and fm.id <> p_member_id) then raise exception 'Questo contatto fa gia parte della Famiglia.'; end if;

  update public.family_members fm
  set first_name = nullif(btrim(p_first_name), ''),
      last_name = nullif(btrim(p_last_name), ''),
      relationship = nullif(btrim(p_relationship), ''),
      member_type = p_member_type,
      birth_date = p_birth_date,
      pet_species = nullif(btrim(p_pet_species), ''),
      contact_id = v_effective_contact_id
  where fm.id = p_member_id
  returning fm.* into v_member;

  return to_jsonb(v_member);
exception when unique_violation then raise exception 'Questo contatto fa gia parte della Famiglia.';
end $$;

create or replace function public.delete_family_member(p_member_id uuid)
returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
  v_actor_profile_id uuid;
  v_owner_profile_id uuid;
  v_member public.family_members%rowtype;
  v_owner_account_id uuid;
begin
  select fm.*
    into v_member
  from public.family_members fm
  where fm.id = p_member_id
  for update of fm;
  if not found then raise exception 'permission denied'; end if;
  select f.owner_account_id into v_owner_account_id
  from public.families f
  where f.id = v_member.family_id;

  perform public.require_manage_family(v_member.family_id);
  select p.id into v_actor_profile_id from public.profiles p where p.account_id = v_actor_account_id;
  select p.id into v_owner_profile_id from public.profiles p where p.account_id = v_owner_account_id;
  if v_member.linked_profile_id is not null
     and (v_member.linked_profile_id = v_actor_profile_id or v_member.linked_profile_id = v_owner_profile_id) then
    raise exception 'family member cannot be removed';
  end if;

  delete from public.family_members where id = v_member.id;
end $$;

create or replace function public.create_family_invite(
  p_family_member_id uuid,
  p_recipient_email text,
  p_expires_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
  v_member public.family_members%rowtype;
  v_email text;
  v_expires_at timestamptz;
  v_invite public.family_invites%rowtype;
begin
  v_email := public.normalize_contact_email(p_recipient_email);
  v_expires_at := coalesce(p_expires_at, now() + interval '14 days');
  if v_expires_at <= now() then raise exception 'family invite expiry must be in the future'; end if;

  select fm.* into v_member
  from public.family_members fm
  where fm.id = p_family_member_id
  for update;
  if not found then raise exception 'family member unavailable'; end if;
  perform public.require_manage_family(v_member.family_id);
  if v_member.member_type <> 'person' then raise exception 'only a person can receive a family invite'; end if;

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
  values(v_member.family_id, v_member.id, v_actor_account_id, v_email, v_expires_at)
  returning * into v_invite;

  return jsonb_build_object(
    'invite_id', v_invite.id, 'family_id', v_invite.family_id, 'family_member_id', v_invite.family_member_id,
    'recipient_email', v_invite.recipient_email, 'status', v_invite.status, 'created_at', v_invite.created_at,
    'expires_at', v_invite.expires_at
  );
end $$;

create or replace function public.revoke_family_invite(p_invite_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_invite public.family_invites%rowtype;
begin
  select fi.* into v_invite
  from public.family_invites fi
  where fi.id = p_invite_id
  for update;
  if not found or v_invite.status <> 'pending' then raise exception 'family invite unavailable'; end if;
  perform public.require_manage_family(v_invite.family_id);

  update public.family_invites
  set status = 'revoked', updated_at = now(), revoked_at = now()
  where id = v_invite.id;
  return jsonb_build_object('invite_id', v_invite.id, 'status', 'revoked');
end $$;

create or replace function public.get_my_family()
returns jsonb
language sql
stable security definer
set search_path=public,pg_temp as $$
  with viewer as (
    select a.id as account_id, p.id as profile_id
    from public.accounts a
    join public.profiles p on p.account_id = a.id
    where a.auth_user_id = auth.uid() and a.account_type = 'personal'
  ), selected_family as (
    select f.*, v.profile_id as viewer_profile_id,
           (f.owner_account_id = v.account_id) as viewer_is_owner,
           case when f.owner_account_id = v.account_id then 'owner' else fa.role end as viewer_role,
           (f.owner_account_id = v.account_id or fa.role in ('member', 'adult')) as viewer_can_manage
    from public.families f
    cross join viewer v
    left join public.family_access fa on fa.family_id = f.id and fa.profile_id = v.profile_id
    where f.owner_account_id = v.account_id or fa.profile_id is not null
    order by (f.owner_account_id = v.account_id) desc, f.created_at
    limit 1
  )
  select jsonb_build_object(
    'family', to_jsonb(sf) - 'viewer_profile_id' - 'viewer_is_owner' - 'viewer_role' - 'viewer_can_manage',
    'viewer', jsonb_build_object(
      'profile_id', sf.viewer_profile_id,
      'is_owner', sf.viewer_is_owner,
      'role', sf.viewer_role,
      'can_manage', sf.viewer_can_manage
    ),
    'owner', jsonb_build_object(
      'profile_id', owner_profile.id,
      'first_name', owner_profile.first_name,
      'last_name', owner_profile.last_name,
      'birth_date', owner_profile.birth_date,
      'avatar_path', owner_profile.avatar_path
    ),
    'members', coalesce((
      select jsonb_agg(
        (case when sf.viewer_is_owner then to_jsonb(fm) else to_jsonb(fm) - 'contact_id' end)
        || jsonb_build_object(
          'first_name', case when sf.viewer_is_owner then coalesce(owner_contact.first_name, fm.first_name) else fm.first_name end,
          'last_name', case when sf.viewer_is_owner then coalesce(owner_contact.last_name, fm.last_name) else fm.last_name end,
          'profile_avatar_path', case when confirmed_access.profile_id is not null then linked_profile.avatar_path else null end,
          'membership_status', case
            when confirmed_access.profile_id is not null then 'confirmed'
            when sf.viewer_can_manage and pending_invite.id is not null then 'pending'
            else 'private'
          end,
          'pending_invite_id', case when sf.viewer_can_manage then pending_invite.id else null end
        )
        order by lower(fm.first_name), lower(coalesce(fm.last_name, '')), fm.id
      )
      from public.family_members fm
      left join public.contacts owner_contact
        on owner_contact.id = fm.contact_id
       and owner_contact.owner_account_id = sf.owner_account_id
       and sf.viewer_is_owner
      left join public.family_access confirmed_access
        on confirmed_access.family_id = sf.id
       and confirmed_access.profile_id = fm.linked_profile_id
      left join public.profiles linked_profile on linked_profile.id = confirmed_access.profile_id
      left join lateral (
        select fi.id
        from public.family_invites fi
        where sf.viewer_can_manage
          and fi.family_id = sf.id
          and fi.family_member_id = fm.id
          and fi.status = 'pending'
          and fi.expires_at > now()
        order by fi.created_at desc
        limit 1
      ) pending_invite on true
      where fm.family_id = sf.id
    ), '[]'::jsonb)
  )
  from selected_family sf
  join public.profiles owner_profile on owner_profile.account_id = sf.owner_account_id
$$;

create or replace function public.get_my_managed_family_member(
  p_member_id uuid
)
returns table(
  id uuid,
  first_name text,
  last_name text,
  member_type text,
  pet_species text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  return query
  select fm.id, fm.first_name, fm.last_name, fm.member_type, fm.pet_species
  from public.family_members fm
  where fm.id = p_member_id;
end;
$$;

create or replace function public.get_my_deadlines_for_managed_member(
  p_member_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  return query
  select to_jsonb(d)
  from public.deadlines d
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
  order by d.first_due_on, d.created_at, d.id;
end;
$$;

create or replace function public.get_my_managed_family_member_avatar_path(
  p_member_id uuid
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_avatar_path text;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select fm.avatar_path into v_avatar_path
  from public.family_members fm
  where fm.id = p_member_id;
  return v_avatar_path;
end;
$$;

create or replace function public.set_my_managed_family_member_avatar(
  p_member_id uuid,
  p_avatar_path text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_expected_path text;
  v_member public.family_members%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;
  v_expected_path := v_owner_account_id::text || '/' || p_member_id::text || '/avatar';

  if p_avatar_path is not null and p_avatar_path <> v_expected_path then
    raise exception 'invalid family member avatar path';
  end if;

  update public.family_members fm
  set avatar_path = p_avatar_path
  where fm.id = p_member_id
  returning fm.* into v_member;
  if not found then raise exception 'family member unavailable'; end if;

  return jsonb_build_object('id', v_member.id, 'avatar_path', v_member.avatar_path);
end;
$$;

create or replace function public.can_read_managed_family_member_avatar_path(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_path is not null and exists (
    select 1
    from public.families f
    join public.family_members fm on fm.family_id = f.id
    where p_path = f.owner_account_id::text || '/' || fm.id::text || '/avatar'
      and public.can_manage_family(f.id)
  )
$$;

create or replace function public.can_manage_managed_family_member_avatar_path(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.can_read_managed_family_member_avatar_path(p_path)
$$;

drop policy if exists family_member_avatars_select_authorized on storage.objects;
drop policy if exists family_member_avatars_insert_authorized on storage.objects;
drop policy if exists family_member_avatars_update_authorized on storage.objects;
drop policy if exists family_member_avatars_delete_authorized on storage.objects;

create policy family_member_avatars_select_authorized
on storage.objects for select to authenticated
using (
  bucket_id = 'family-member-avatars'
  and public.can_read_managed_family_member_avatar_path(name)
);

create policy family_member_avatars_insert_authorized
on storage.objects for insert to authenticated
with check (
  bucket_id = 'family-member-avatars'
  and public.can_manage_managed_family_member_avatar_path(name)
);

create policy family_member_avatars_update_authorized
on storage.objects for update to authenticated
using (
  bucket_id = 'family-member-avatars'
  and public.can_manage_managed_family_member_avatar_path(name)
)
with check (
  bucket_id = 'family-member-avatars'
  and public.can_manage_managed_family_member_avatar_path(name)
);

create policy family_member_avatars_delete_authorized
on storage.objects for delete to authenticated
using (
  bucket_id = 'family-member-avatars'
  and public.can_manage_managed_family_member_avatar_path(name)
);

create or replace function public.get_my_managed_family_member_calendar(
  p_member_id uuid,
  p_from timestamptz,
  p_to timestamptz
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_from is null or p_to is null or p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  return query
  select jsonb_build_object(
    'kind', 'deadline', 'deadline_id', d.id, 'title', d.title,
    'due_on', o.occurrence_on, 'occurs_on', o.occurrence_on, 'all_day', true,
    'is_completed', c.deadline_id is not null, 'family_member_id', fm.id,
    'family_member_name', nullif(btrim(concat_ws(' ', fm.first_name, fm.last_name)), ''),
    'family_member_type', fm.member_type, 'family_member_avatar_path', fm.avatar_path,
    'calendar_owner_account_id', v_owner_account_id, 'calendar_is_shared', false
  )
  from public.deadlines d
  join public.family_members fm on fm.id = d.family_member_id
  cross join lateral generate_series(
    d.first_due_on, least(coalesce(d.terminated_on, v_to_date), v_to_date),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and d.status = 'active'
    and o.occurrence_on between p_from::date and v_to_date;
end;
$$;

create or replace function public.get_my_managed_deadline(
  p_member_id uuid,
  p_deadline_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_deadline jsonb;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;
  select to_jsonb(d) into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id and d.owner_account_id = v_owner_account_id and d.family_member_id = p_member_id;
  if v_deadline is null then raise exception 'deadline unavailable'; end if;
  return v_deadline;
end;
$$;

create or replace function public.update_my_managed_deadline(
  p_member_id uuid,
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_deadline public.deadlines%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;
  update public.deadlines d
  set title = nullif(btrim(p_title), ''), category = nullif(btrim(p_category), ''),
      first_due_on = p_first_due_on, recurrence_months = p_recurrence_months,
      reminder_days = coalesce(p_reminder_days, 30), notes = nullif(btrim(p_notes), '')
  where d.id = p_deadline_id and d.owner_account_id = v_owner_account_id and d.family_member_id = p_member_id
  returning d.* into v_deadline;
  if not found then raise exception 'deadline unavailable'; end if;
  return to_jsonb(v_deadline);
end;
$$;

create or replace function public.complete_my_managed_deadline_occurrence(
  p_deadline_id uuid,
  p_managed_member_id uuid,
  p_occurrence_on date,
  p_completed boolean default true
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
  v_owner_account_id uuid;
  v_deadline public.deadlines%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_managed_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_managed_member_id;
  select d.* into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id and d.owner_account_id = v_owner_account_id and d.family_member_id = p_managed_member_id;
  if not found then raise exception 'deadline unavailable'; end if;
  if not exists (
    select 1 from generate_series(
      v_deadline.first_due_on, least(coalesce(v_deadline.terminated_on, p_occurrence_on), p_occurrence_on),
      make_interval(months => coalesce(v_deadline.recurrence_months, 1200))
    ) occurrence(occurrence_on)
    where occurrence.occurrence_on::date = p_occurrence_on
  ) then raise exception 'deadline occurrence unavailable'; end if;
  if p_completed then
    insert into public.deadline_occurrence_completions(deadline_id, occurrence_on, completed_by_account_id)
    values(p_deadline_id, p_occurrence_on, v_actor_account_id)
    on conflict(deadline_id, occurrence_on) do nothing;
  else
    delete from public.deadline_occurrence_completions
    where deadline_id = p_deadline_id and occurrence_on = p_occurrence_on;
  end if;
end;
$$;

create or replace function public.delete_my_managed_deadline(
  p_deadline_id uuid,
  p_managed_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  perform public.assert_manage_owned_family_member(p_managed_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_managed_member_id;
  delete from public.deadlines d
  where d.id = p_deadline_id and d.owner_account_id = v_owner_account_id and d.family_member_id = p_managed_member_id;
  if not found then raise exception 'deadline unavailable'; end if;
end;
$$;

create or replace function public.create_deadline(
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_family_member_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_current_account();
  v_owner_account_id uuid := v_actor_account_id;
  v_id uuid;
begin
  if p_family_member_id is not null then
    perform public.assert_manage_owned_family_member(p_family_member_id);
    select f.owner_account_id into v_owner_account_id
    from public.family_members fm join public.families f on f.id = fm.family_id
    where fm.id = p_family_member_id;
  end if;
  insert into public.deadlines(
    owner_account_id, title, category, first_due_on, recurrence_months,
    reminder_days, notes, family_member_id
  ) values (
    v_owner_account_id, nullif(btrim(p_title), ''), nullif(btrim(p_category), ''),
    p_first_due_on, p_recurrence_months, coalesce(p_reminder_days, 30),
    nullif(btrim(p_notes), ''), p_family_member_id
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.get_deadline_occurrence(
  p_deadline_id uuid,
  p_occurrence_on date
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'deadline_id', d.id, 'title', d.title, 'occurrence_on', o.occurrence_on::date,
    'completed', c.deadline_id is not null
  )
  from public.deadlines d
  left join public.family_members fm on fm.id = d.family_member_id
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, p_occurrence_on), p_occurrence_on),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on::date
  where d.id = p_deadline_id
    and d.status = 'active'
    and o.occurrence_on::date = p_occurrence_on
    and (
      d.owner_account_id = public.require_current_account()
      or (fm.family_id is not null and public.can_manage_family(fm.family_id))
    );
$$;

alter function public.can_manage_family(uuid) owner to postgres;
alter function public.require_manage_family(uuid) owner to postgres;
alter function public.assert_manage_owned_family_member(uuid) owner to postgres;
alter function public.create_family_member(text,text,text,text,date,text,uuid) owner to postgres;
alter function public.update_family_member(uuid,text,text,text,text,date,text,uuid) owner to postgres;
alter function public.delete_family_member(uuid) owner to postgres;
alter function public.create_family_invite(uuid,text,timestamptz) owner to postgres;
alter function public.revoke_family_invite(uuid) owner to postgres;
alter function public.get_my_family() owner to postgres;
alter function public.get_my_managed_family_member(uuid) owner to postgres;
alter function public.get_my_deadlines_for_managed_member(uuid) owner to postgres;
alter function public.get_my_managed_family_member_avatar_path(uuid) owner to postgres;
alter function public.set_my_managed_family_member_avatar(uuid,text) owner to postgres;
alter function public.can_read_managed_family_member_avatar_path(text) owner to postgres;
alter function public.can_manage_managed_family_member_avatar_path(text) owner to postgres;
alter function public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) owner to postgres;
alter function public.get_my_managed_deadline(uuid,uuid) owner to postgres;
alter function public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text) owner to postgres;
alter function public.complete_my_managed_deadline_occurrence(uuid,uuid,date,boolean) owner to postgres;
alter function public.delete_my_managed_deadline(uuid,uuid) owner to postgres;
alter function public.create_deadline(text,text,date,smallint,smallint,text,uuid) owner to postgres;
alter function public.get_deadline_occurrence(uuid,date) owner to postgres;

revoke all on function public.can_manage_family(uuid), public.require_manage_family(uuid), public.assert_manage_owned_family_member(uuid) from public, anon;
revoke all on function public.create_family_member(text,text,text,text,date,text,uuid), public.update_family_member(uuid,text,text,text,text,date,text,uuid), public.delete_family_member(uuid), public.create_family_invite(uuid,text,timestamptz), public.revoke_family_invite(uuid), public.get_my_family(), public.get_my_managed_family_member(uuid), public.get_my_deadlines_for_managed_member(uuid), public.get_my_managed_family_member_avatar_path(uuid), public.set_my_managed_family_member_avatar(uuid,text), public.can_read_managed_family_member_avatar_path(text), public.can_manage_managed_family_member_avatar_path(text), public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz), public.get_my_managed_deadline(uuid,uuid), public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text), public.complete_my_managed_deadline_occurrence(uuid,uuid,date,boolean), public.delete_my_managed_deadline(uuid,uuid), public.create_deadline(text,text,date,smallint,smallint,text,uuid), public.get_deadline_occurrence(uuid,date) from public, anon;
grant execute on function public.can_manage_family(uuid) to authenticated;
grant execute on function public.create_family_member(text,text,text,text,date,text,uuid), public.update_family_member(uuid,text,text,text,text,date,text,uuid), public.delete_family_member(uuid), public.create_family_invite(uuid,text,timestamptz), public.revoke_family_invite(uuid), public.get_my_family(), public.get_my_managed_family_member(uuid), public.get_my_deadlines_for_managed_member(uuid), public.get_my_managed_family_member_avatar_path(uuid), public.set_my_managed_family_member_avatar(uuid,text), public.can_read_managed_family_member_avatar_path(text), public.can_manage_managed_family_member_avatar_path(text), public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz), public.get_my_managed_deadline(uuid,uuid), public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text), public.complete_my_managed_deadline_occurrence(uuid,uuid,date,boolean), public.delete_my_managed_deadline(uuid,uuid), public.create_deadline(text,text,date,smallint,smallint,text,uuid), public.get_deadline_occurrence(uuid,date) to authenticated;

commit;
