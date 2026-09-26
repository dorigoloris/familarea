-- Include recurring Events whose next occurrence is still in the future.
-- Suggestions stay virtual: no occurrence rows are persisted.

begin;

create or replace function public.event_is_suggested(p_event_id uuid, p_account_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select exists (
    select 1
    from public.events e
    join public.profiles profile on profile.account_id = p_account_id
    join public.profile_interests pi on pi.profile_id = profile.id
    join public.event_interests ei on ei.event_id = e.id and ei.interest_id = pi.interest_id
    join public.interests i on i.id = ei.interest_id
    join public.interest_categories c on c.id = i.category_id
    where e.id = p_event_id
      and e.status = 'active'
      and i.origin = 'catalog'
      and i.publication_status = 'published'
      and i.status = 'active'
      and c.status = 'active'
      and e.owner_account_id is distinct from p_account_id
      and not (e.area_id is null and e.created_by_account_id = p_account_id)
      and public.event_personal_source(e.id, p_account_id) is null
      and exists (
        select 1
        from public.expand_recurrence_occurrences(
          e.starts_at, e.ends_at, e.recurrence_frequency,
          e.recurrence_interval, e.recurrence_weekdays, e.recurrence_until,
          e.recurrence_timezone, now(), now() + interval '400 days'
        ) future_occurrence
      )
      and not exists (
        select 1 from public.event_participants ep
        where ep.event_id = e.id
          and ep.status in ('active', 'removed')
          and (
            ep.profile_id = profile.id
            or exists (
              select 1 from public.contact_profile_links l
              where l.profile_id = profile.id and l.contact_id = ep.contact_id
            )
          )
      )
      and not exists (
        select 1 from public.event_invites ei_pending
        join public.accounts account on account.id = p_account_id
        join auth.users auth_user on auth_user.id = account.auth_user_id
        where ei_pending.event_id = e.id
          and ei_pending.status = 'pending'
          and ei_pending.expires_at > now()
          and lower(ei_pending.recipient_email) = lower(auth_user.email)
      )
  )
$$;

create or replace function public.get_my_event_suggestions()
returns setof jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_profile uuid := public.require_personal_profile();
  v_account uuid := public.require_personal_account();
begin
  return query
    select jsonb_build_object(
      'event_id', e.id,
      'title', e.title,
      'description', e.description,
      'starts_at', occurrence.occurrence_starts_at,
      'ends_at', occurrence.occurrence_ends_at,
      'is_all_day', e.is_all_day,
      'location', e.location,
      'area_id', e.area_id,
      'area_name', a.name,
      'organizer_name', coalesce(o.name, nullif(btrim(concat_ws(' ', organizer_profile.first_name, organizer_profile.last_name)), ''), 'Organizzatore'),
      'matching_interests', matches.items
    )
    from public.events e
    left join public.areas a on a.id = e.area_id
    left join public.accounts organizer on organizer.id = coalesce(e.owner_account_id, a.owner_account_id)
    left join public.organizations o on o.account_id = organizer.id
    left join public.profiles organizer_profile on organizer_profile.account_id = organizer.id
    cross join lateral (
      select occ.occurrence_starts_at, occ.occurrence_ends_at
      from public.expand_recurrence_occurrences(
        e.starts_at, e.ends_at, e.recurrence_frequency,
        e.recurrence_interval, e.recurrence_weekdays, e.recurrence_until,
        e.recurrence_timezone, now(), now() + interval '400 days'
      ) occ
      order by occ.occurrence_starts_at
      limit 1
    ) occurrence
    cross join lateral (
      select jsonb_agg(jsonb_build_object(
        'interest_id', i.id, 'display_name', i.display_name, 'category_name', c.name
      ) order by c.name, i.display_name) as items
      from public.profile_interests pi
      join public.interests i on i.id = pi.interest_id
      join public.interest_categories c on c.id = i.category_id
      join public.event_interests ei on ei.interest_id = i.id and ei.event_id = e.id
      where pi.profile_id = v_profile
        and i.origin = 'catalog' and i.publication_status = 'published' and i.status = 'active'
        and c.status = 'active'
    ) matches
    where public.event_is_suggested(e.id, v_account)
    order by occurrence.occurrence_starts_at, e.created_at, e.id;
end $$;

alter function public.event_is_suggested(uuid,uuid) owner to postgres;
alter function public.get_my_event_suggestions() owner to postgres;

revoke all on function public.event_is_suggested(uuid,uuid) from public, anon, authenticated;
revoke all on function public.get_my_event_suggestions() from public, anon;
grant execute on function public.get_my_event_suggestions() to authenticated;

commit;