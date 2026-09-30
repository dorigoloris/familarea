-- FamilArea — one account-owned deadline-management flow for personal and organization accounts.
-- Authorization intentionally remains owner_account_id = require_current_account().

begin;

create or replace function public.assert_my_deadline_item(p_item_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account();
begin
  if p_item_id is null or not exists (
    select 1 from public.deadline_items di
    where di.id=p_item_id and di.owner_account_id=v_account_id
  ) then raise exception 'deadline item unavailable'; end if;
end $$;

create or replace function public.get_my_deadline_items(p_category text default null)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account();
begin
  if p_category is distinct from 'vehicle' then raise exception 'deadline item category unavailable'; end if;
  return query select to_jsonb(di) from public.deadline_items di
    where di.owner_account_id=v_account_id and di.category=p_category
    order by di.name,di.created_at,di.id;
end $$;

create or replace function public.get_my_deadline_item(p_item_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_item jsonb;
begin
  perform public.assert_my_deadline_item(p_item_id);
  select to_jsonb(di) into v_item from public.deadline_items di
    where di.id=p_item_id and di.owner_account_id=v_account_id;
  return v_item;
end $$;

create or replace function public.create_my_deadline_item(p_category text,p_item_type text,p_name text,p_plate text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_item public.deadline_items%rowtype;
begin
  if p_category is distinct from 'vehicle' then raise exception 'deadline item category unavailable'; end if;
  if p_item_type is null or p_item_type not in ('car','motorcycle','other') then raise exception 'deadline item type unavailable'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'deadline item name required'; end if;
  insert into public.deadline_items(owner_account_id,category,item_type,name,plate)
    values(v_account_id,p_category,p_item_type,btrim(p_name),nullif(upper(btrim(p_plate)),'')) returning * into v_item;
  return to_jsonb(v_item);
end $$;

create or replace function public.update_my_deadline_item(p_item_id uuid,p_item_type text,p_name text,p_plate text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_item public.deadline_items%rowtype;
begin
  perform public.assert_my_deadline_item(p_item_id);
  if p_item_type is null or p_item_type not in ('car','motorcycle','other') then raise exception 'deadline item type unavailable'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'deadline item name required'; end if;
  update public.deadline_items di set item_type=p_item_type,name=btrim(p_name),plate=nullif(upper(btrim(p_plate)),''),updated_at=now()
    where di.id=p_item_id and di.owner_account_id=v_account_id returning di.* into v_item;
  return to_jsonb(v_item);
end $$;

create or replace function public.delete_my_deadline_item(p_item_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account();
begin
  perform public.assert_my_deadline_item(p_item_id);
  delete from public.deadline_items di where di.id=p_item_id and di.owner_account_id=v_account_id;
end $$;

create or replace function public.get_my_deadlines_for_item(p_item_id uuid)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account();
begin
  perform public.assert_my_deadline_item(p_item_id);
  return query select to_jsonb(d) from public.deadlines d
    where d.owner_account_id=v_account_id and d.deadline_item_id=p_item_id
    order by d.first_due_on,d.created_at,d.id;
end $$;

create or replace function public.create_deadline_for_item(p_item_id uuid,p_title text,p_category text,p_first_due_on date,p_recurrence_months smallint default null,p_reminder_days smallint default 30,p_notes text default null,p_deadline_kind text default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_deadline_id uuid;
begin
  perform public.assert_my_deadline_item(p_item_id);
  if p_deadline_kind is not null and p_deadline_kind not in ('vehicle_insurance','vehicle_tax','vehicle_inspection','vehicle_service') then raise exception 'deadline kind unavailable'; end if;
  if p_deadline_kind is not null and not exists (select 1 from public.deadline_items di where di.id=p_item_id and di.owner_account_id=v_account_id and di.category='vehicle') then raise exception 'vehicle deadline kind requires an owned vehicle item'; end if;
  insert into public.deadlines(owner_account_id,deadline_item_id,deadline_kind,title,category,first_due_on,recurrence_months,reminder_days,notes)
    values(v_account_id,p_item_id,p_deadline_kind,nullif(btrim(p_title),''),nullif(btrim(p_category),''),p_first_due_on,p_recurrence_months,coalesce(p_reminder_days,30),nullif(btrim(p_notes),'')) returning id into v_deadline_id;
  return v_deadline_id;
end $$;

create or replace function public.set_my_deadline_item(p_deadline_id uuid,p_item_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_deadline public.deadlines%rowtype;
begin
  if not exists (select 1 from public.deadlines d where d.id=p_deadline_id and d.owner_account_id=v_account_id) then raise exception 'deadline unavailable'; end if;
  if p_item_id is not null then perform public.assert_my_deadline_item(p_item_id); end if;
  update public.deadlines d set deadline_item_id=p_item_id,deadline_kind=case when p_item_id is null then null else d.deadline_kind end
    where d.id=p_deadline_id and d.owner_account_id=v_account_id returning d.* into v_deadline;
  return to_jsonb(v_deadline);
end $$;

create or replace function public.update_my_deadline_with_item(p_deadline_id uuid,p_title text,p_category text,p_first_due_on date,p_recurrence_months smallint default null,p_reminder_days smallint default 30,p_notes text default null,p_deadline_item_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_deadline public.deadlines%rowtype;
begin
  select d.* into v_deadline from public.deadlines d where d.id=p_deadline_id and d.owner_account_id=v_account_id;
  if not found then raise exception 'deadline unavailable'; end if;
  perform public.update_deadline(p_deadline_id,p_title,p_category,p_first_due_on,p_recurrence_months,p_reminder_days,p_notes,v_deadline.family_member_id,v_deadline.status);
  return public.set_my_deadline_item(p_deadline_id,p_deadline_item_id);
end $$;

create or replace function public.can_read_my_deadline_item_image_path(p_path text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select p_path is not null and exists (
    select 1 from public.deadline_items di join public.accounts owner_account on owner_account.id=di.owner_account_id
    where di.category='vehicle' and p_path=owner_account.id::text||'/'||di.id::text||'/image'
      and (owner_account.auth_user_id=auth.uid() or exists (
        select 1 from public.accounts viewer_account join public.person_calendar_links link on link.viewer_account_id=viewer_account.id and link.owner_account_id=di.owner_account_id
        where viewer_account.auth_user_id=auth.uid() and viewer_account.account_type='personal' and link.visible and public.can_view_person_calendar(di.owner_account_id,viewer_account.id)
      ))
  )
$$;

create or replace function public.can_manage_my_deadline_item_image_path(p_path text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select p_path is not null and exists (
    select 1 from public.deadline_items di join public.accounts owner_account on owner_account.id=di.owner_account_id
    where di.category='vehicle' and owner_account.auth_user_id=auth.uid()
      and p_path=owner_account.id::text||'/'||di.id::text||'/image'
  )
$$;

create or replace function public.set_my_deadline_item_image(p_item_id uuid,p_image_path text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_expected_path text:=v_account_id::text||'/'||p_item_id::text||'/image'; v_item public.deadline_items%rowtype;
begin
  perform public.assert_my_deadline_item(p_item_id);
  if p_image_path is not null and p_image_path<>v_expected_path then raise exception 'invalid deadline item image path'; end if;
  update public.deadline_items di set image_path=p_image_path,updated_at=now() where di.id=p_item_id and di.owner_account_id=v_account_id returning di.* into v_item;
  if not found then raise exception 'deadline item unavailable'; end if;
  return to_jsonb(v_item);
end $$;

create or replace function public.get_my_vehicle_service_records(p_deadline_item_id uuid)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account();
begin
  perform public.assert_my_deadline_item(p_deadline_item_id);
  if not exists (select 1 from public.deadline_items di where di.id=p_deadline_item_id and di.owner_account_id=v_account_id and di.category='vehicle') then raise exception 'vehicle unavailable'; end if;
  return query select jsonb_build_object('id',r.id,'deadline_item_id',r.deadline_item_id,'performed_at',r.performed_at,'mileage',r.mileage,'performed_by',r.performed_by,'notes',r.notes,'created_at',r.created_at,'updated_at',r.updated_at,'tasks',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'task_key',t.task_key,'label',t.label) order by t.created_at,t.id) from public.vehicle_service_record_tasks t where t.service_record_id=r.id),'[]'::jsonb)) from public.vehicle_service_records r where r.deadline_item_id=p_deadline_item_id order by r.performed_at desc,r.created_at desc,r.id;
end $$;

alter function public.assert_my_deadline_item(uuid) owner to postgres;
alter function public.get_my_deadline_items(text) owner to postgres;
alter function public.get_my_deadline_item(uuid) owner to postgres;
alter function public.create_my_deadline_item(text,text,text,text) owner to postgres;
alter function public.update_my_deadline_item(uuid,text,text,text) owner to postgres;
alter function public.delete_my_deadline_item(uuid) owner to postgres;
alter function public.get_my_deadlines_for_item(uuid) owner to postgres;
alter function public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text) owner to postgres;
alter function public.set_my_deadline_item(uuid,uuid) owner to postgres;
alter function public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid) owner to postgres;
alter function public.can_read_my_deadline_item_image_path(text) owner to postgres;
alter function public.can_manage_my_deadline_item_image_path(text) owner to postgres;
alter function public.set_my_deadline_item_image(uuid,text) owner to postgres;
alter function public.get_my_vehicle_service_records(uuid) owner to postgres;

revoke all on function public.assert_my_deadline_item(uuid),public.can_read_my_deadline_item_image_path(text),public.can_manage_my_deadline_item_image_path(text) from public,anon;
grant execute on function public.get_my_deadline_items(text),public.get_my_deadline_item(uuid),public.create_my_deadline_item(text,text,text,text),public.update_my_deadline_item(uuid,text,text,text),public.delete_my_deadline_item(uuid),public.get_my_deadlines_for_item(uuid),public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text),public.set_my_deadline_item(uuid,uuid),public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid),public.set_my_deadline_item_image(uuid,text),public.get_my_vehicle_service_records(uuid),public.can_read_my_deadline_item_image_path(text),public.can_manage_my_deadline_item_image_path(text) to authenticated;

commit;
