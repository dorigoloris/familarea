-- FamilArea — private avatar images for managed Family members.
-- The image belongs to family_members; it never creates an account or Profile.

begin;

alter table public.family_members
  add column if not exists avatar_path text;

create or replace function public.can_read_managed_family_member_avatar_path(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_path is not null and exists (
    select 1
    from public.accounts a
    join public.families f on f.owner_account_id = a.id
    join public.family_members fm on fm.family_id = f.id
    where a.auth_user_id = auth.uid()
      and a.account_type = 'personal'
      and p_path = a.id::text || '/' || fm.id::text || '/avatar'
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

create or replace function public.get_my_managed_family_member_avatar_path(
  p_member_id uuid
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_avatar_path text;
begin
  perform public.assert_manage_owned_family_member(p_member_id);

  select fm.avatar_path
  into v_avatar_path
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_member_id
    and f.owner_account_id = v_owner_account_id;

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
  v_owner_account_id uuid := public.require_personal_account();
  v_expected_path text := v_owner_account_id::text || '/' || p_member_id::text || '/avatar';
  v_member public.family_members%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_member_id);

  if p_avatar_path is not null and p_avatar_path <> v_expected_path then
    raise exception 'invalid family member avatar path';
  end if;

  update public.family_members fm
  set avatar_path = p_avatar_path
  where fm.id = p_member_id
    and fm.family_id in (
      select f.id from public.families f where f.owner_account_id = v_owner_account_id
    )
  returning fm.* into v_member;

  if not found then
    raise exception 'family member unavailable';
  end if;

  return jsonb_build_object('id', v_member.id, 'avatar_path', v_member.avatar_path);
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'family-member-avatars',
  'family-member-avatars',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

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

create or replace function public.get_calendar_occurrences(p_from timestamptz, p_to timestamptz)
returns setof jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_account uuid := public.require_current_account();
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return query
    with calendar_accounts as (
      select v_account as account_id, false as is_shared
      where coalesce((select l.visible from public.person_calendar_links l
        where l.owner_account_id = v_account and l.viewer_account_id = v_account), true)
      union all
      select l.owner_account_id, true
      from public.person_calendar_links l
      where l.viewer_account_id = v_account and l.owner_account_id <> v_account
        and l.visible and public.can_view_person_calendar(l.owner_account_id, v_account)
    )
    select jsonb_build_object(
      'kind','activity','id',a.id,'activity_id',a.id,'title',a.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,
      'all_day',a.is_all_day,'area_id',a.area_id,'status',a.status,
      'area_name',(select ar.name from public.areas ar where ar.id = a.area_id),
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.activities a on a.status <> 'cancelled'
      and (a.owner_account_id = s.account_id or (a.area_id is not null and exists (
        select 1 from public.areas ar where ar.id = a.area_id and (
          ar.owner_account_id = s.account_id or exists (
            select 1 from public.area_memberships am
            join public.profiles ap on ap.id = am.profile_id
            where am.area_id = ar.id and ap.account_id = s.account_id
          )
        )
      )))
    cross join lateral public.expand_recurrence_occurrences(
      coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,
      a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,
      a.recurrence_timezone,p_from,p_to
    ) o
    union all
    select jsonb_build_object(
      'kind','event','id',e.id,'event_id',e.id,'title',e.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,
      'all_day',e.is_all_day,'area_id',e.area_id,'status',e.status,
      'area_name',(select ar.name from public.areas ar where ar.id = e.area_id),
      'calendar_private',e.calendar_private,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.events e on e.status <> 'cancelled'
      and (s.account_id = v_account or not e.calendar_private)
      and public.event_personal_source(e.id, s.account_id) is not null
    cross join lateral public.expand_recurrence_occurrences(
      e.starts_at,e.ends_at,e.recurrence_frequency,e.recurrence_interval,
      e.recurrence_weekdays,e.recurrence_until,e.recurrence_timezone,p_from,p_to
    ) o
    union all
    select jsonb_build_object(
      'kind','deadline','deadline_id',d.id,'title',d.title,
      'due_on',o.occurrence_on,'occurs_on',o.occurrence_on,'all_day',true,
      'is_completed',c.deadline_id is not null,
      'family_member_id',fm.id,
      'family_member_name',nullif(btrim(concat_ws(' ',fm.first_name,fm.last_name)),'') ,
      'family_member_type',fm.member_type,
      'family_member_avatar_path',fm.avatar_path,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.deadlines d on d.owner_account_id = s.account_id and d.status = 'active'
    left join public.family_members fm on fm.id = d.family_member_id
    cross join lateral generate_series(
      d.first_due_on, least(coalesce(d.terminated_on,v_to_date),v_to_date),
      make_interval(months => coalesce(d.recurrence_months,1200))
    ) o(occurrence_on)
    left join public.deadline_occurrence_completions c
      on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
    where o.occurrence_on between p_from::date and v_to_date;
end $$;

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
  v_owner_account_id uuid := public.require_personal_account();
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid occurrence range';
  end if;

  perform public.assert_manage_owned_family_member(p_member_id);

  return query
  select jsonb_build_object(
    'kind', 'deadline',
    'deadline_id', d.id,
    'title', d.title,
    'due_on', o.occurrence_on,
    'occurs_on', o.occurrence_on,
    'all_day', true,
    'is_completed', c.deadline_id is not null,
    'family_member_id', fm.id,
    'family_member_name', nullif(btrim(concat_ws(' ', fm.first_name, fm.last_name)), ''),
    'family_member_type', fm.member_type,
    'family_member_avatar_path', fm.avatar_path,
    'calendar_owner_account_id', v_owner_account_id,
    'calendar_is_shared', false
  )
  from public.deadlines d
  join public.family_members fm on fm.id = d.family_member_id
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, v_to_date), v_to_date),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id
   and c.occurrence_on = o.occurrence_on
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and d.status = 'active'
    and o.occurrence_on between p_from::date and v_to_date;
end;
$$;

alter function public.can_read_managed_family_member_avatar_path(text) owner to postgres;
alter function public.can_manage_managed_family_member_avatar_path(text) owner to postgres;
alter function public.get_my_managed_family_member_avatar_path(uuid) owner to postgres;
alter function public.set_my_managed_family_member_avatar(uuid, text) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;
alter function public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) owner to postgres;

revoke all on function public.can_read_managed_family_member_avatar_path(text), public.can_manage_managed_family_member_avatar_path(text) from public, anon, authenticated;
revoke all on function public.get_my_managed_family_member_avatar_path(uuid), public.set_my_managed_family_member_avatar(uuid,text) from public, anon;
revoke all on function public.get_calendar_occurrences(timestamptz,timestamptz), public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) from public, anon;
grant execute on function public.get_my_managed_family_member_avatar_path(uuid), public.set_my_managed_family_member_avatar(uuid,text) to authenticated;
grant execute on function public.get_calendar_occurrences(timestamptz,timestamptz), public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) to authenticated;

commit;
