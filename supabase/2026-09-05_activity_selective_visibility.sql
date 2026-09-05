-- FamilArea — visibilità selettiva delle attività.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

alter table public.area_activities add column if not exists visibility text;
update public.area_activities set visibility = 'area' where visibility is null;
alter table public.area_activities alter column visibility set default 'area';
alter table public.area_activities alter column visibility set not null;
alter table public.area_activities drop constraint if exists area_activities_visibility_check;
alter table public.area_activities add constraint area_activities_visibility_check
  check (visibility in ('private', 'creator_assignees', 'area'));

-- Le firme cambiate vengono eliminate esplicitamente: nessun overload RPC.
drop function if exists public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz);
drop function if exists public.get_area_activity(uuid,uuid);
drop function if exists public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[]);
drop function if exists public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean);
drop function if exists public.set_area_activity_assignees(uuid,uuid,uuid[]);
drop function if exists public.set_area_activity_status(uuid,uuid,text);
drop function if exists public.delete_area_activity(uuid,uuid);

create function public.get_area_activities(p_area_id uuid,p_status text default null,p_activity_type text default null,p_assigned_to_me boolean default false,p_due_from timestamptz default null,p_due_to timestamptz default null)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;
  return query select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at
  from public.area_activities a
  where a.area_id=p_area_id
    and (p_status is null or a.status=p_status) and (p_activity_type is null or a.activity_type=p_activity_type)
    and (p_due_from is null or a.due_at>=p_due_from) and (p_due_to is null or a.due_at<=p_due_to)
    and (a.visibility='area' or a.created_by_profile_id=v_profile or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile)))
    and (not p_assigned_to_me or exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile) or not exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id))
  order by a.due_at nulls last,a.created_at desc;
end; $$;

create function public.get_area_activity(p_area_id uuid,p_activity_id uuid)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;
  return query select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at
  from public.area_activities a where a.id=p_activity_id and a.area_id=p_area_id
    and (a.visibility='area' or a.created_by_profile_id=v_profile or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile)));
  if not found then raise exception 'Attivita non trovata o non accessibile'; end if;
end; $$;

create function public.create_area_activity(p_area_id uuid,p_title text,p_notes text,p_activity_type text,p_priority text,p_starts_at timestamptz,p_due_at timestamptz,p_is_all_day boolean,p_assignee_profile_ids uuid[],p_visibility text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_id uuid; v_ids uuid[]:=coalesce(p_assignee_profile_ids,'{}');
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title,''))='' or p_activity_type not in ('task','reminder','deadline','appointment') or p_priority not in ('low','normal','high') or p_visibility not in ('private','creator_assignees','area') or (p_starts_at is not null and p_due_at is not null and p_due_at<p_starts_at) then raise exception 'Dati attivita non validi'; end if;
  if (p_visibility='private' and cardinality(v_ids)>0) or (p_visibility='creator_assignees' and cardinality(v_ids)=0) then raise exception 'Visibilita e assegnatari non coerenti'; end if;
  if v_role='member' and exists(select 1 from unnest(v_ids) x where x is distinct from v_profile) then raise exception 'permission denied'; end if;
  if exists(select 1 from unnest(v_ids) x left join public.area_memberships am on am.area_id=p_area_id and am.profile_id=x where am.profile_id is null) then raise exception 'Assegnatario non appartenente all''Area'; end if;
  insert into public.area_activities(area_id,title,notes,activity_type,priority,visibility,starts_at,due_at,is_all_day,created_by_profile_id) values(p_area_id,btrim(p_title),p_notes,p_activity_type,p_priority,p_visibility,p_starts_at,p_due_at,coalesce(p_is_all_day,false),v_profile) returning id into v_id;
  insert into public.activity_assignees(activity_id,area_id,profile_id,assigned_by_profile_id) select v_id,p_area_id,x,v_profile from(select distinct unnest(v_ids) x)s;
  return v_id;
end; $$;

create function public.update_area_activity(p_area_id uuid,p_activity_id uuid,p_title text,p_notes text,p_activity_type text,p_priority text,p_starts_at timestamptz,p_due_at timestamptz,p_is_all_day boolean,p_visibility text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_current_visibility text;
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  select created_by_profile_id,visibility into v_creator,v_current_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id; if not found then raise exception 'Attivita non trovata'; end if;
  if v_creator is distinct from v_profile and not (v_current_visibility='area' and p_visibility='area' and v_role='admin') then raise exception 'permission denied'; end if;
  if btrim(coalesce(p_title,''))='' or p_activity_type not in ('task','reminder','deadline','appointment') or p_priority not in ('low','normal','high') or p_visibility not in ('private','creator_assignees','area') or (p_starts_at is not null and p_due_at is not null and p_due_at<p_starts_at) then raise exception 'Dati attivita non validi'; end if;
  if (p_visibility='private' and exists(select 1 from public.activity_assignees where activity_id=p_activity_id)) or (p_visibility='creator_assignees' and not exists(select 1 from public.activity_assignees where activity_id=p_activity_id)) then raise exception 'Visibilita e assegnatari non coerenti'; end if;
  update public.area_activities set title=btrim(p_title),notes=p_notes,activity_type=p_activity_type,priority=p_priority,visibility=p_visibility,starts_at=p_starts_at,due_at=p_due_at,is_all_day=coalesce(p_is_all_day,false) where id=p_activity_id and area_id=p_area_id;
end; $$;

create function public.set_area_activity_assignees(p_area_id uuid,p_activity_id uuid,p_assignee_profile_ids uuid[],p_visibility text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_current_visibility text; v_ids uuid[]:=coalesce(p_assignee_profile_ids,'{}');
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  select created_by_profile_id,visibility into v_creator,v_current_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id for update; if not found then raise exception 'Attivita non trovata'; end if;
  if v_creator is distinct from v_profile and not (v_current_visibility='area' and p_visibility='area' and v_role='admin') then raise exception 'permission denied'; end if;
  if p_visibility not in ('private','creator_assignees','area') or (p_visibility='private' and cardinality(v_ids)>0) or (p_visibility='creator_assignees' and cardinality(v_ids)=0) then raise exception 'Visibilita e assegnatari non coerenti'; end if;
  if v_role='member' and exists(select 1 from unnest(v_ids) x where x is distinct from v_profile) then raise exception 'permission denied'; end if;
  if exists(select 1 from unnest(v_ids) x left join public.area_memberships am on am.area_id=p_area_id and am.profile_id=x where am.profile_id is null) then raise exception 'Assegnatario non appartenente all''Area'; end if;
  delete from public.activity_assignees where activity_id=p_activity_id and area_id=p_area_id;
  insert into public.activity_assignees(activity_id,area_id,profile_id,assigned_by_profile_id) select p_activity_id,p_area_id,x,v_profile from(select distinct unnest(v_ids)x)s;
  update public.area_activities set visibility=p_visibility where id=p_activity_id and area_id=p_area_id;
end; $$;

create function public.set_area_activity_status(p_area_id uuid,p_activity_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_visibility text;
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null or p_status not in ('open','completed','cancelled') then raise exception 'permission denied'; end if;
  select created_by_profile_id,visibility into v_creator,v_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id; if not found then raise exception 'Attivita non trovata'; end if;
  if v_visibility='private' and v_creator is distinct from v_profile then raise exception 'permission denied'; end if;
  if v_visibility='creator_assignees' and (p_status<>'completed' or (v_creator is distinct from v_profile and not exists(select 1 from public.activity_assignees where activity_id=p_activity_id and profile_id=v_profile))) then raise exception 'permission denied'; end if;
  if v_visibility='area' and v_role<>'admin' and (p_status<>'completed' or (exists(select 1 from public.activity_assignees where activity_id=p_activity_id) and not exists(select 1 from public.activity_assignees where activity_id=p_activity_id and profile_id=v_profile))) then raise exception 'permission denied'; end if;
  update public.area_activities set status=p_status,completed_at=case when p_status='completed' then now() else null end,completed_by_profile_id=case when p_status='completed' then v_profile else null end where id=p_activity_id and area_id=p_area_id;
end; $$;

create function public.delete_area_activity(p_area_id uuid,p_activity_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_creator uuid; v_status text; v_visibility text;
begin
  select profile_id,role into v_profile,v_role from public.current_area_activity_role(p_area_id); if v_profile is null then raise exception 'permission denied'; end if;
  select created_by_profile_id,status,visibility into v_creator,v_status,v_visibility from public.area_activities where id=p_activity_id and area_id=p_area_id; if not found then raise exception 'Attivita non trovata'; end if;
  if (v_visibility<>'area' and v_creator is distinct from v_profile) or (v_visibility='area' and v_role<>'admin' and (v_creator is distinct from v_profile or v_status<>'open')) then raise exception 'permission denied'; end if;
  delete from public.area_activities where id=p_activity_id and area_id=p_area_id;
end; $$;

revoke all on function public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz),public.get_area_activity(uuid,uuid),public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text),public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text),public.set_area_activity_assignees(uuid,uuid,uuid[],text),public.set_area_activity_status(uuid,uuid,text),public.delete_area_activity(uuid,uuid) from public;
grant execute on function public.get_area_activities(uuid,text,text,boolean,timestamptz,timestamptz),public.get_area_activity(uuid,uuid),public.create_area_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,uuid[],text),public.update_area_activity(uuid,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text),public.set_area_activity_assignees(uuid,uuid,uuid[],text),public.set_area_activity_status(uuid,uuid,text),public.delete_area_activity(uuid,uuid) to authenticated;

revoke all on public.area_activities,public.activity_assignees from public,authenticated;

commit;
