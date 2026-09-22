-- =============================================================================
-- Oggetti personali oppure Area: attivita, eventi e liste
-- =============================================================================

begin;

alter table public.area_activities alter column area_id drop not null;
alter table public.area_events alter column area_id drop not null;
alter table public.area_lists alter column area_id drop not null;

alter table public.area_activities
  add constraint area_activities_personal_owner_check
    check (area_id is not null or created_by_profile_id is not null),
  add constraint area_activities_personal_visibility_check
    check (area_id is not null or visibility = 'private');

alter table public.area_events
  add constraint area_events_personal_visibility_check
    check (area_id is not null or visibility = 'private');

alter table public.area_lists
  add constraint area_lists_personal_visibility_check
    check (area_id is not null or visibility = 'private');

create index area_activities_personal_owner_schedule_idx
  on public.area_activities (created_by_profile_id, (coalesce(due_at, starts_at)), created_at, id)
  where area_id is null;
create index area_events_personal_owner_starts_idx
  on public.area_events (created_by_profile_id, starts_at, created_at, id)
  where area_id is null;
create index area_lists_personal_owner_created_idx
  on public.area_lists (created_by_profile_id, created_at desc, id)
  where area_id is null;

create function public.current_my_profile_id()
returns uuid
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'permission denied'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'permission denied'; end if;
  return v_profile_id;
end;
$$;

-- Attivita personali ---------------------------------------------------------
create function public.create_my_activity(
  p_title text, p_notes text, p_activity_type text, p_priority text,
  p_starts_at timestamptz, p_due_at timestamptz, p_is_all_day boolean,
  p_recurrence_frequency text default null, p_recurrence_interval smallint default null,
  p_recurrence_weekdays smallint[] default null, p_recurrence_until date default null,
  p_recurrence_timezone text default null
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile_id uuid := public.current_my_profile_id(); v_id uuid;
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence_frequency, ''))), '');
  v_interval smallint := p_recurrence_interval; v_weekdays smallint[];
  v_until date := p_recurrence_until; v_timezone text := nullif(btrim(coalesce(p_recurrence_timezone, '')), '');
begin
  if p_recurrence_weekdays is not null then
    select array_agg(distinct weekday order by weekday) into v_weekdays from unnest(p_recurrence_weekdays) as days(weekday);
  end if;
  if btrim(coalesce(p_title, '')) = ''
     or p_activity_type not in ('task','reminder','deadline','appointment')
     or p_priority not in ('low','normal','high')
     or (p_starts_at is not null and p_due_at is not null and p_due_at < p_starts_at) then
    raise exception 'Dati attivita non validi';
  end if;
  if v_frequency is null then
    if v_interval is not null or v_weekdays is not null or v_until is not null or v_timezone is not null then raise exception 'Configurazione ricorrenza non valida'; end if;
  elsif v_frequency <> 'weekly' or p_starts_at is null or v_interval is null or v_interval <= 0
     or v_weekdays is null or cardinality(v_weekdays) = 0 or array_position(v_weekdays, null) is not null
     or not (v_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) or v_until is null or v_timezone is null then
    raise exception 'Configurazione ricorrenza non valida';
  else
    perform 1 from pg_timezone_names where name = v_timezone;
    if not found then raise exception 'Timezone ricorrenza non valida'; end if;
    if v_until < (p_starts_at at time zone v_timezone)::date then raise exception 'La fine della ricorrenza non puo precedere la prima occorrenza'; end if;
    if extract(isodow from (p_starts_at at time zone v_timezone))::smallint <> all(v_weekdays) then raise exception 'Il giorno della prima occorrenza deve appartenere alla ricorrenza'; end if;
  end if;
  insert into public.area_activities(area_id,title,notes,activity_type,priority,visibility,starts_at,due_at,is_all_day,created_by_profile_id,recurrence_frequency,recurrence_interval,recurrence_weekdays,recurrence_until,recurrence_timezone)
  values(null,btrim(p_title),p_notes,p_activity_type,p_priority,'private',p_starts_at,p_due_at,coalesce(p_is_all_day,false),v_profile_id,v_frequency,v_interval,v_weekdays,v_until,v_timezone)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.get_my_activity(p_activity_id uuid)
returns table(id uuid,title text,notes text,activity_type text,status text,priority text,visibility text,assignee_profile_ids uuid[],starts_at timestamptz,due_at timestamptz,is_all_day boolean,created_by_profile_id uuid,completed_by_profile_id uuid,completed_at timestamptz,created_at timestamptz,updated_at timestamptz,recurrence_frequency text,recurrence_interval smallint,recurrence_weekdays smallint[],recurrence_until date,recurrence_timezone text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  return query select a.id,a.title,a.notes,a.activity_type,a.status,a.priority,a.visibility,array[]::uuid[],a.starts_at,a.due_at,a.is_all_day,a.created_by_profile_id,a.completed_by_profile_id,a.completed_at,a.created_at,a.updated_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone
  from public.area_activities a where a.id=p_activity_id and a.area_id is null and a.created_by_profile_id=v_profile_id;
  if not found then raise exception 'Attivita non trovata o non accessibile'; end if;
end;
$$;

create function public.update_my_activity(
  p_activity_id uuid, p_title text, p_notes text, p_activity_type text, p_priority text,
  p_starts_at timestamptz, p_due_at timestamptz, p_is_all_day boolean,
  p_recurrence_frequency text default null, p_recurrence_interval smallint default null,
  p_recurrence_weekdays smallint[] default null, p_recurrence_until date default null,
  p_recurrence_timezone text default null, p_update_recurrence boolean default false
)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile_id uuid := public.current_my_profile_id();
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence_frequency, ''))), '');
  v_interval smallint := p_recurrence_interval; v_weekdays smallint[];
  v_until date := p_recurrence_until; v_timezone text := nullif(btrim(coalesce(p_recurrence_timezone, '')), '');
begin
  perform 1 from public.area_activities a where a.id=p_activity_id and a.area_id is null and a.created_by_profile_id=v_profile_id for update;
  if not found then raise exception 'Attivita non trovata o non modificabile'; end if;
  if btrim(coalesce(p_title, '')) = '' or p_activity_type not in ('task','reminder','deadline','appointment') or p_priority not in ('low','normal','high') or (p_starts_at is not null and p_due_at is not null and p_due_at < p_starts_at) then raise exception 'Dati attivita non validi'; end if;
  if p_update_recurrence then
    if p_recurrence_weekdays is not null then select array_agg(distinct weekday order by weekday) into v_weekdays from unnest(p_recurrence_weekdays) as days(weekday); end if;
    if v_frequency is null then v_interval:=null; v_weekdays:=null; v_until:=null; v_timezone:=null;
    elsif v_frequency <> 'weekly' or p_starts_at is null or v_interval is null or v_interval <= 0 or v_weekdays is null or cardinality(v_weekdays)=0 or array_position(v_weekdays,null) is not null or not(v_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) or v_until is null or v_timezone is null then raise exception 'Configurazione ricorrenza non valida';
    else
      perform 1 from pg_timezone_names where name=v_timezone; if not found then raise exception 'Timezone ricorrenza non valida'; end if;
      if v_until < (p_starts_at at time zone v_timezone)::date then raise exception 'La fine della ricorrenza non puo precedere la prima occorrenza'; end if;
      if extract(isodow from (p_starts_at at time zone v_timezone))::smallint <> all(v_weekdays) then raise exception 'Il giorno della prima occorrenza deve appartenere alla ricorrenza'; end if;
    end if;
  end if;
  update public.area_activities set title=btrim(p_title),notes=p_notes,activity_type=p_activity_type,priority=p_priority,starts_at=p_starts_at,due_at=p_due_at,is_all_day=coalesce(p_is_all_day,false),recurrence_frequency=case when p_update_recurrence then v_frequency else recurrence_frequency end,recurrence_interval=case when p_update_recurrence then v_interval else recurrence_interval end,recurrence_weekdays=case when p_update_recurrence then v_weekdays else recurrence_weekdays end,recurrence_until=case when p_update_recurrence then v_until else recurrence_until end,recurrence_timezone=case when p_update_recurrence then v_timezone else recurrence_timezone end where id=p_activity_id and area_id is null and created_by_profile_id=v_profile_id;
end;
$$;

create function public.set_my_activity_status(p_activity_id uuid,p_status text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  if p_status not in ('open','completed','cancelled') then raise exception 'Stato attivita non valido'; end if;
  update public.area_activities set status=p_status,completed_at=case when p_status='completed' then now() else null end,completed_by_profile_id=case when p_status='completed' then v_profile_id else null end where id=p_activity_id and area_id is null and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Attivita non trovata o non modificabile'; end if;
end;
$$;

create function public.delete_my_activity(p_activity_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  delete from public.area_activities where id=p_activity_id and area_id is null and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Attivita non trovata o non eliminabile'; end if;
end;
$$;

-- Eventi personali -----------------------------------------------------------
create function public.create_my_event(p_title text,p_notes text,p_starts_at timestamptz,p_ends_at timestamptz,p_is_all_day boolean,p_location text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id(); v_event_id uuid;
begin
  if btrim(coalesce(p_title,''))='' or p_starts_at is null or (p_ends_at is not null and p_ends_at<p_starts_at) then raise exception 'Dati evento non validi'; end if;
  insert into public.area_events(area_id,title,notes,starts_at,ends_at,is_all_day,location,visibility,created_by_profile_id)
  values(null,btrim(p_title),p_notes,p_starts_at,p_ends_at,coalesce(p_is_all_day,false),nullif(btrim(coalesce(p_location,'')),''),'private',v_profile_id) returning id into v_event_id;
  return v_event_id;
end;
$$;

create function public.get_my_event(p_event_id uuid)
returns table(id uuid,title text,notes text,starts_at timestamptz,ends_at timestamptz,is_all_day boolean,location text,status text,visibility text,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  return query select e.id,e.title,e.notes,e.starts_at,e.ends_at,e.is_all_day,e.location,e.status,e.visibility,e.created_by_profile_id,e.created_at,e.updated_at from public.area_events e where e.id=p_event_id and e.area_id is null and e.created_by_profile_id=v_profile_id;
  if not found then raise exception 'Evento non trovato o non accessibile'; end if;
end;
$$;

create function public.update_my_event(p_event_id uuid,p_title text,p_notes text,p_starts_at timestamptz,p_ends_at timestamptz,p_is_all_day boolean,p_location text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  if btrim(coalesce(p_title,''))='' or p_starts_at is null or (p_ends_at is not null and p_ends_at<p_starts_at) then raise exception 'Dati evento non validi'; end if;
  update public.area_events set title=btrim(p_title),notes=p_notes,starts_at=p_starts_at,ends_at=p_ends_at,is_all_day=coalesce(p_is_all_day,false),location=nullif(btrim(coalesce(p_location,'')),'') where id=p_event_id and area_id is null and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Evento non trovato o non modificabile'; end if;
end;
$$;

create function public.cancel_my_event(p_event_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  update public.area_events set status='cancelled' where id=p_event_id and area_id is null and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Evento non trovato o non modificabile'; end if;
end;
$$;

create function public.delete_my_event(p_event_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  delete from public.area_events where id=p_event_id and area_id is null and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Evento non trovato o non eliminabile'; end if;
end;
$$;

-- Liste personali ------------------------------------------------------------
create function public.create_my_list(p_title text,p_description text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id(); v_list_id uuid;
begin
  if btrim(coalesce(p_title,''))='' then raise exception 'Dati Lista non validi'; end if;
  insert into public.area_lists(area_id,title,description,visibility,created_by_profile_id) values(null,btrim(p_title),nullif(btrim(coalesce(p_description,'')),''),'private',v_profile_id) returning id into v_list_id;
  return v_list_id;
end;
$$;

create function public.get_my_list(p_list_id uuid)
returns table(id uuid,title text,description text,visibility text,created_by_profile_id uuid,created_at timestamptz,updated_at timestamptz,items jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  return query select l.id,l.title,l.description,l.visibility,l.created_by_profile_id,l.created_at,l.updated_at,coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'text',i.text,'status',i.status,'position',i.position,'created_by_profile_id',i.created_by_profile_id,'completed_by_profile_id',i.completed_by_profile_id,'created_at',i.created_at,'completed_at',i.completed_at,'updated_at',i.updated_at) order by i.position,i.created_at,i.id) from public.area_list_items i where i.list_id=l.id),'[]'::jsonb) from public.area_lists l where l.id=p_list_id and l.area_id is null and l.created_by_profile_id=v_profile_id;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
end;
$$;

create function public.update_my_list(p_list_id uuid,p_title text,p_description text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  if btrim(coalesce(p_title,''))='' then raise exception 'Dati Lista non validi'; end if;
  update public.area_lists set title=btrim(p_title),description=nullif(btrim(coalesce(p_description,'')),'') where id=p_list_id and area_id is null and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Lista non trovata o non modificabile'; end if;
end;
$$;

create function public.delete_my_list(p_list_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  delete from public.area_lists where id=p_list_id and area_id is null and created_by_profile_id=v_profile_id;
  if not found then raise exception 'Lista non trovata o non eliminabile'; end if;
end;
$$;

create function public.add_my_list_item(p_list_id uuid,p_text text,p_position integer default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id(); v_item_id uuid; v_position integer;
begin
  if btrim(coalesce(p_text,''))='' or (p_position is not null and p_position<0) then raise exception 'Dati elemento Lista non validi'; end if;
  perform 1 from public.area_lists l where l.id=p_list_id and l.area_id is null and l.created_by_profile_id=v_profile_id for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  if p_position is null then select coalesce(max(i.position)+1,0) into v_position from public.area_list_items i where i.list_id=p_list_id; else v_position:=p_position; end if;
  insert into public.area_list_items(list_id,text,position,created_by_profile_id) values(p_list_id,btrim(p_text),v_position,v_profile_id) returning id into v_item_id;
  return v_item_id;
end;
$$;

create function public.update_my_list_item(p_list_id uuid,p_item_id uuid,p_text text,p_position integer default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  if btrim(coalesce(p_text,''))='' or (p_position is not null and p_position<0) then raise exception 'Dati elemento Lista non validi'; end if;
  perform 1 from public.area_lists l where l.id=p_list_id and l.area_id is null and l.created_by_profile_id=v_profile_id for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  update public.area_list_items set text=btrim(p_text),position=coalesce(p_position,position) where id=p_item_id and list_id=p_list_id;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
end;
$$;

create function public.set_my_list_item_status(p_list_id uuid,p_item_id uuid,p_status text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  if p_status not in ('open','completed') then raise exception 'Stato elemento Lista non valido'; end if;
  perform 1 from public.area_lists l where l.id=p_list_id and l.area_id is null and l.created_by_profile_id=v_profile_id for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  update public.area_list_items set status=p_status,completed_at=case when p_status='completed' then now() else null end,completed_by_profile_id=case when p_status='completed' then v_profile_id else null end where id=p_item_id and list_id=p_list_id;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
end;
$$;

create function public.delete_my_list_item(p_list_id uuid,p_item_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid := public.current_my_profile_id();
begin
  perform 1 from public.area_lists l where l.id=p_list_id and l.area_id is null and l.created_by_profile_id=v_profile_id for update;
  if not found then raise exception 'Lista non trovata o non accessibile'; end if;
  delete from public.area_list_items where id=p_item_id and list_id=p_list_id;
  if not found then raise exception 'Elemento Lista non trovato'; end if;
end;
$$;

-- Viste globali: Area visibile piu oggetti personali del proprietario --------
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

-- Allegati: il proprietario puo gestire e vedere anche i propri oggetti personali.
create or replace function public.can_manage_attachment_target(p_target_type text,p_target_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null or p_target_id is null then return false; end if;
  select id into v_profile_id from public.profiles where user_id=auth.uid(); if v_profile_id is null then return false; end if;
  if p_target_type='deadline' then return exists(select 1 from public.deadlines d where d.id=p_target_id and d.owner_profile_id=v_profile_id); end if;
  if p_target_type='event' then return exists(select 1 from public.area_events e where e.id=p_target_id and e.created_by_profile_id=v_profile_id and (e.area_id is null or exists(select 1 from public.area_memberships am where am.area_id=e.area_id and am.profile_id=v_profile_id and am.role in ('admin','member')))); end if;
  if p_target_type='activity' then
    return exists(
      select 1 from public.area_activities a
      where a.id=p_target_id and (
        (a.area_id is null and a.created_by_profile_id=v_profile_id)
        or (a.area_id is not null and exists(
          select 1 from public.area_memberships am
          where am.area_id=a.area_id and am.profile_id=v_profile_id and am.role in ('admin','member')
            and (a.created_by_profile_id=v_profile_id or (a.visibility='area' and am.role='admin'))
        ))
      )
    );
  end if;
  return false;
end;
$$;

create or replace function public.can_view_attachment(p_attachment_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then return false; end if;
  select id into v_profile_id from public.profiles where user_id=auth.uid(); if v_profile_id is null then return false; end if;
  return exists(
    select 1 from public.attachments x
    left join public.deadlines d on d.id=x.deadline_id
    left join public.area_events e on e.id=x.event_id
    left join public.area_activities a on a.id=x.activity_id
    where x.id=p_attachment_id and (
      (x.target_type='deadline' and d.owner_profile_id=v_profile_id)
      or (x.target_type='event' and (
        (e.area_id is null and e.created_by_profile_id=v_profile_id)
        or (e.area_id is not null and exists(
          select 1 from public.area_memberships am
          left join public.event_participants ep on ep.event_id=e.id and ep.profile_id=v_profile_id
          where am.area_id=e.area_id and am.profile_id=v_profile_id and am.role in ('admin','member')
            and (e.visibility='area' or e.created_by_profile_id=v_profile_id or (e.visibility='creator_participants' and ep.profile_id is not null))
        ))
      ))
      or (x.target_type='activity' and (
        (a.area_id is null and a.created_by_profile_id=v_profile_id)
        or (a.area_id is not null and exists(
          select 1 from public.area_memberships am
          where am.area_id=a.area_id and am.profile_id=v_profile_id and am.role in ('admin','member')
            and (a.visibility='area' or a.created_by_profile_id=v_profile_id or (a.visibility='creator_assignees' and exists(select 1 from public.activity_assignees aa where aa.activity_id=a.id and aa.profile_id=v_profile_id)))
        ))
      ))
    )
  );
end;
$$;

alter function public.current_my_profile_id() owner to postgres;
alter function public.create_my_activity(text,text,text,text,timestamptz,timestamptz,boolean,text,smallint,smallint[],date,text) owner to postgres;
alter function public.get_my_activity(uuid) owner to postgres;
alter function public.update_my_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,smallint,smallint[],date,text,boolean) owner to postgres;
alter function public.set_my_activity_status(uuid,text) owner to postgres;
alter function public.delete_my_activity(uuid) owner to postgres;
alter function public.create_my_event(text,text,timestamptz,timestamptz,boolean,text) owner to postgres;
alter function public.get_my_event(uuid) owner to postgres;
alter function public.update_my_event(uuid,text,text,timestamptz,timestamptz,boolean,text) owner to postgres;
alter function public.cancel_my_event(uuid) owner to postgres;
alter function public.delete_my_event(uuid) owner to postgres;
alter function public.create_my_list(text,text) owner to postgres;
alter function public.get_my_list(uuid) owner to postgres;
alter function public.update_my_list(uuid,text,text) owner to postgres;
alter function public.delete_my_list(uuid) owner to postgres;
alter function public.add_my_list_item(uuid,text,integer) owner to postgres;
alter function public.update_my_list_item(uuid,uuid,text,integer) owner to postgres;
alter function public.set_my_list_item_status(uuid,uuid,text) owner to postgres;
alter function public.delete_my_list_item(uuid,uuid) owner to postgres;
alter function public.get_my_visible_activities() owner to postgres;
alter function public.get_my_visible_activity_occurrences(timestamptz,timestamptz) owner to postgres;
alter function public.get_my_visible_events() owner to postgres;
alter function public.get_my_visible_lists() owner to postgres;
alter function public.can_manage_attachment_target(text,uuid) owner to postgres;
alter function public.can_view_attachment(uuid) owner to postgres;

revoke all on function public.current_my_profile_id() from public;
revoke all on function public.create_my_activity(text,text,text,text,timestamptz,timestamptz,boolean,text,smallint,smallint[],date,text),public.get_my_activity(uuid),public.update_my_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,smallint,smallint[],date,text,boolean),public.set_my_activity_status(uuid,text),public.delete_my_activity(uuid),public.create_my_event(text,text,timestamptz,timestamptz,boolean,text),public.get_my_event(uuid),public.update_my_event(uuid,text,text,timestamptz,timestamptz,boolean,text),public.cancel_my_event(uuid),public.delete_my_event(uuid),public.create_my_list(text,text),public.get_my_list(uuid),public.update_my_list(uuid,text,text),public.delete_my_list(uuid),public.add_my_list_item(uuid,text,integer),public.update_my_list_item(uuid,uuid,text,integer),public.set_my_list_item_status(uuid,uuid,text),public.delete_my_list_item(uuid,uuid) from public;
grant execute on function public.create_my_activity(text,text,text,text,timestamptz,timestamptz,boolean,text,smallint,smallint[],date,text),public.get_my_activity(uuid),public.update_my_activity(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,smallint,smallint[],date,text,boolean),public.set_my_activity_status(uuid,text),public.delete_my_activity(uuid),public.create_my_event(text,text,timestamptz,timestamptz,boolean,text),public.get_my_event(uuid),public.update_my_event(uuid,text,text,timestamptz,timestamptz,boolean,text),public.cancel_my_event(uuid),public.delete_my_event(uuid),public.create_my_list(text,text),public.get_my_list(uuid),public.update_my_list(uuid,text,text),public.delete_my_list(uuid),public.add_my_list_item(uuid,text,integer),public.update_my_list_item(uuid,uuid,text,integer),public.set_my_list_item_status(uuid,uuid,text),public.delete_my_list_item(uuid,uuid) to authenticated;

commit;
