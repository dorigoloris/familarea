-- FamilArea — estensione RPC dettaglio attività.
-- Migration incrementale da applicare dopo 2026-09-05_activity_selective_visibility.sql.

begin;

drop function if exists public.get_area_activity(uuid,uuid);

create function public.get_area_activity(p_area_id uuid,p_activity_id uuid)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,visibility text,assignee_profile_ids uuid[],starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;

  return query
  select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,
    array(select aa.profile_id from public.activity_assignees aa where aa.activity_id=a.id order by aa.assigned_at,aa.profile_id),
    a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at
  from public.area_activities a
  where a.id=p_activity_id and a.area_id=p_area_id
    and (a.visibility='area' or a.created_by_profile_id=v_profile or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile)));

  if not found then raise exception 'Attivita non trovata o non accessibile'; end if;
end; $$;

revoke all on function public.get_area_activity(uuid,uuid) from public;
grant execute on function public.get_area_activity(uuid,uuid) to authenticated;

commit;
