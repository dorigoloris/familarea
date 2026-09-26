-- FamilArea — apply the self calendar view preference to every personal source.
-- This affects calendar occurrences only; it does not change authorization.

begin;

create or replace function public.get_calendar_occurrences(p_from timestamptz, p_to timestamptz)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return query
    select jsonb_build_object('kind','activity','id',a.id,'activity_id',a.id,'title',a.title,'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',a.is_all_day,'area_id',a.area_id,'status',a.status)
    from public.activities a cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o
    where a.status<>'cancelled'
      and ((a.area_id is null and a.owner_account_id=v_account and coalesce((
        select vp.visible from public.calendar_view_preferences vp
        where vp.viewer_account_id=v_account and vp.source_account_id=v_account and vp.family_id is null
      ),true)) or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id))))
    union all
    select jsonb_strip_nulls(jsonb_build_object('kind','event','id',e.id,'event_id',e.id,'title',e.title,'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',e.is_all_day,'area_id',e.area_id,'status',e.status,'visibility_source',s.visibility_source,'shared_by_display_name',case when s.visibility_source='family' then public.event_shared_by_display_name(e) end))
    from public.events e cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
    cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,null,null,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o
    where s.visibility_source is not null and e.status<>'cancelled'
      and (public.calendar_event_source_visible(e,s.visibility_source)
        or (s.visibility_source='owner' and (
          (e.area_id is not null and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id)))
          or exists (
            select 1 from public.event_participants ep
            join public.profiles p on p.id=ep.profile_id
            where ep.event_id=e.id and ep.status='active' and p.account_id=v_account
          )
        )))
    union all
    select jsonb_build_object('kind','deadline','deadline_id',x->>'deadline_id','title',x->>'title','due_on',x->>'occurrence_on','occurs_on',x->>'occurrence_on','all_day',true,'is_completed',coalesce((x->>'completed')::boolean,false))
    from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date) x
    where coalesce((
      select vp.visible from public.calendar_view_preferences vp
      where vp.viewer_account_id=v_account and vp.source_account_id=v_account and vp.family_id is null
    ),true);
end $$;

alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;

commit;