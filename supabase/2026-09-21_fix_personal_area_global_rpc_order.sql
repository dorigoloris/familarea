-- Correct unambiguous ordering references in the global personal/Area views.

create or replace function public.get_my_visible_activities()
returns table(activity_id uuid,area_id uuid,area_name text,area_type text,title text,notes text,activity_type text,status text,priority text,starts_at timestamptz,due_at timestamptz,is_all_day boolean,visibility text,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz,recurrence_frequency text,recurrence_interval smallint,recurrence_weekdays smallint[],recurrence_until date,recurrence_timezone text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  return query select * from (
    select a.id,ar.id,ar.name,ar.area_type,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.visibility,a.created_by_profile_id,a.created_at,a.updated_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone from public.area_memberships am join public.areas ar on ar.id=am.area_id join public.area_activities a on a.area_id=am.area_id where am.profile_id=v_profile_id and am.role in ('admin','member') and (a.visibility='area' or a.created_by_profile_id=v_profile_id or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile_id)))
    union all
    select a.id,null::uuid,null::text,null::text,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.visibility,a.created_by_profile_id,a.created_at,a.updated_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone from public.area_activities a where a.area_id is null and a.created_by_profile_id=v_profile_id
  ) visible order by 10 asc nulls last,16 asc,1 asc;
end;
$$;

create or replace function public.get_my_visible_events()
returns table(event_id uuid,area_id uuid,area_name text,area_type text,title text,notes text,location text,starts_at timestamptz,ends_at timestamptz,is_all_day boolean,status text,visibility text,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz,own_participation_status text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  return query select * from (
    select e.id,ar.id,ar.name,ar.area_type,e.title,e.notes,e.location,e.starts_at,e.ends_at,e.is_all_day,e.status,e.visibility,e.created_by_profile_id,e.created_at,e.updated_at,mine.participation_status from public.area_memberships am join public.areas ar on ar.id=am.area_id join public.area_events e on e.area_id=am.area_id left join public.event_participants mine on mine.event_id=e.id and mine.area_id=e.area_id and mine.profile_id=v_profile_id where am.profile_id=v_profile_id and am.role in ('admin','member') and (e.visibility='area' or e.created_by_profile_id=v_profile_id or (e.visibility='creator_participants' and mine.profile_id is not null))
    union all
    select e.id,null::uuid,null::text,null::text,e.title,e.notes,e.location,e.starts_at,e.ends_at,e.is_all_day,e.status,e.visibility,e.created_by_profile_id,e.created_at,e.updated_at,null::text from public.area_events e where e.area_id is null and e.created_by_profile_id=v_profile_id
  ) visible order by 8 asc,14 asc,1 asc;
end;
$$;

create or replace function public.get_my_visible_lists()
returns table(list_id uuid,area_id uuid,area_name text,title text,description text,visibility text,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz,total_item_count bigint,completed_item_count bigint)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  return query select * from (
    select l.id,ar.id,ar.name,l.title,l.description,l.visibility,l.created_by_profile_id,l.created_at,l.updated_at,(select count(*) from public.area_list_items i where i.list_id=l.id),(select count(*) from public.area_list_items i where i.list_id=l.id and i.status='completed') from public.area_memberships am join public.areas ar on ar.id=am.area_id join public.area_lists l on l.area_id=am.area_id where am.profile_id=v_profile_id and am.role in ('admin','member') and (l.visibility='area' or l.created_by_profile_id=v_profile_id or (l.visibility='creator_participants' and exists(select 1 from public.area_list_participants alp where alp.list_id=l.id and alp.profile_id=v_profile_id)))
    union all
    select l.id,null::uuid,null::text,l.title,l.description,l.visibility,l.created_by_profile_id,l.created_at,l.updated_at,(select count(*) from public.area_list_items i where i.list_id=l.id),(select count(*) from public.area_list_items i where i.list_id=l.id and i.status='completed') from public.area_lists l where l.area_id is null and l.created_by_profile_id=v_profile_id
  ) visible order by 9 desc,8 desc,1;
end;
$$;

create or replace function public.get_my_visible_activity_occurrences(p_from timestamptz,p_to timestamptz)
returns table(activity_id uuid,area_id uuid,area_name text,area_type text,title text,notes text,activity_type text,status text,priority text,visibility text,is_all_day boolean,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz,occurrence_starts_at timestamptz,occurrence_ends_at timestamptz,recurrence_frequency text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  if p_from is null or p_to is null or p_to<=p_from then raise exception 'Intervallo occorrenze non valido'; end if;
  if p_to>p_from+interval '400 days' then raise exception 'Intervallo occorrenze troppo ampio'; end if;
  return query with visible_activities as (
    select a.*,ar.name as visible_area_name,ar.area_type as visible_area_type from public.area_memberships am join public.areas ar on ar.id=am.area_id join public.area_activities a on a.area_id=am.area_id where am.profile_id=v_profile_id and am.role in ('admin','member') and (a.visibility='area' or a.created_by_profile_id=v_profile_id or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile_id)))
    union all
    select a.*,null::text,null::text from public.area_activities a where a.area_id is null and a.created_by_profile_id=v_profile_id
  ), single_occurrences as (
    select a.id as activity_id,a.area_id,a.visible_area_name as area_name,a.visible_area_type as area_type,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,a.is_all_day,a.created_by_profile_id,a.created_at,a.updated_at,coalesce(a.starts_at,a.due_at) as occurrence_starts_at,coalesce(a.due_at,a.starts_at) as occurrence_ends_at,a.recurrence_frequency from visible_activities a where a.recurrence_frequency is null and coalesce(a.starts_at,a.due_at) is not null and coalesce(a.starts_at,a.due_at)>=p_from and coalesce(a.starts_at,a.due_at)<p_to
  ), recurring_candidates as (
    select a.*,((a.starts_at at time zone a.recurrence_timezone)::date) as starts_local_date,((p_from at time zone a.recurrence_timezone)::date) as range_start_date,((p_to at time zone a.recurrence_timezone)::date) as range_end_date from visible_activities a where a.recurrence_frequency='weekly' and a.status='open' and a.starts_at is not null
  ), recurring_occurrences as (
    select a.id as activity_id,a.area_id,a.visible_area_name as area_name,a.visible_area_type as area_type,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,a.is_all_day,a.created_by_profile_id,a.created_at,a.updated_at,((d::date+(a.starts_at at time zone a.recurrence_timezone)::time) at time zone a.recurrence_timezone) as occurrence_starts_at,case when a.due_at is null then ((d::date+(a.starts_at at time zone a.recurrence_timezone)::time) at time zone a.recurrence_timezone) else (((d::date+(a.due_at at time zone a.recurrence_timezone)::time) at time zone a.recurrence_timezone)+(a.due_at-a.starts_at)) end as occurrence_ends_at,a.recurrence_frequency from recurring_candidates a cross join lateral generate_series(greatest(a.starts_local_date,a.range_start_date),least(a.recurrence_until,a.range_end_date),interval '1 day') d where extract(isodow from d)::smallint=any(a.recurrence_weekdays) and ((d::date-a.starts_local_date)/7)%a.recurrence_interval=0
  ) select * from single_occurrences union all select * from recurring_occurrences order by occurrence_starts_at,created_at,activity_id;
end;
$$;
