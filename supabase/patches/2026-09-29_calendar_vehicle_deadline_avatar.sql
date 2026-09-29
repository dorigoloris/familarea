-- FamilArea — vehicle identity for deadline occurrences in the Calendar.

begin;

create or replace function public.can_read_my_deadline_item_image_path(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_path is not null and exists (
    select 1
    from public.deadline_items di
    join public.accounts owner_account on owner_account.id = di.owner_account_id
    where di.category = 'vehicle'
      and p_path = owner_account.id::text || '/' || di.id::text || '/image'
      and (
        owner_account.auth_user_id = auth.uid()
        or exists (
          select 1
          from public.accounts viewer_account
          join public.person_calendar_links link
            on link.viewer_account_id = viewer_account.id
           and link.owner_account_id = di.owner_account_id
          where viewer_account.auth_user_id = auth.uid()
            and viewer_account.account_type = 'personal'
            and link.visible
            and public.can_view_person_calendar(di.owner_account_id, viewer_account.id)
        )
      )
  )
$$;

create or replace function public.can_manage_my_deadline_item_image_path(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_path is not null and exists (
    select 1
    from public.deadline_items di
    join public.accounts owner_account on owner_account.id = di.owner_account_id
    where di.category = 'vehicle'
      and owner_account.auth_user_id = auth.uid()
      and owner_account.account_type = 'personal'
      and p_path = owner_account.id::text || '/' || di.id::text || '/image'
  )
$$;

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
      'family_member_name',nullif(btrim(concat_ws(' ',fm.first_name,fm.last_name)),''),
      'family_member_type',fm.member_type,
      'family_member_avatar_path',fm.avatar_path,
      'deadline_item_id',di.id,
      'deadline_item_name',di.name,
      'deadline_item_category',di.category,
      'deadline_item_type',di.item_type,
      'deadline_item_image_path',di.image_path,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.deadlines d on d.owner_account_id = s.account_id and d.status = 'active'
    left join public.family_members fm on fm.id = d.family_member_id
    left join public.deadline_items di on di.id = d.deadline_item_id and di.owner_account_id = d.owner_account_id
    cross join lateral generate_series(
      d.first_due_on, least(coalesce(d.terminated_on,v_to_date),v_to_date),
      make_interval(months => coalesce(d.recurrence_months,1200))
    ) o(occurrence_on)
    left join public.deadline_occurrence_completions c
      on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
    where o.occurrence_on between p_from::date and v_to_date;
end $$;

alter function public.can_read_my_deadline_item_image_path(text) owner to postgres;
alter function public.can_manage_my_deadline_item_image_path(text) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;
revoke all on function public.can_read_my_deadline_item_image_path(text), public.can_manage_my_deadline_item_image_path(text) from public, anon;
grant execute on function public.can_read_my_deadline_item_image_path(text), public.can_manage_my_deadline_item_image_path(text) to authenticated;
revoke all on function public.get_calendar_occurrences(timestamptz,timestamptz) from public, anon;
grant execute on function public.get_calendar_occurrences(timestamptz,timestamptz) to authenticated;

commit;
