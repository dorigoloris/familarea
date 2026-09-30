-- FamilArea — Casa V1 within the account-owned deadline-management flow.

begin;

alter table public.deadlines
  drop constraint if exists deadlines_deadline_kind_check;

alter table public.deadlines
  add constraint deadlines_deadline_kind_check
  check (
    deadline_kind is null
    or deadline_kind in (
      'vehicle_insurance', 'vehicle_tax', 'vehicle_inspection', 'vehicle_service',
      'home_heating', 'home_insurance', 'home_taxes', 'home_waste'
    )
  );

create or replace function public.assert_deadline_item_owner()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.deadline_item_id is not null and not exists (
    select 1 from public.deadline_items di
    where di.id=new.deadline_item_id and di.owner_account_id=new.owner_account_id
  ) then raise exception 'deadline item unavailable'; end if;

  if new.deadline_kind is not null and not exists (
    select 1 from public.deadline_items di
    where di.id=new.deadline_item_id and di.owner_account_id=new.owner_account_id
      and (
        (new.deadline_kind in ('vehicle_insurance','vehicle_tax','vehicle_inspection','vehicle_service') and di.category='vehicle')
        or (new.deadline_kind in ('home_heating','home_insurance','home_taxes','home_waste') and di.category='home')
      )
  ) then raise exception 'deadline kind requires an owned item of the matching category'; end if;
  return new;
end $$;

create or replace function public.get_my_deadline_items(p_category text default null)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account();
begin
  if p_category is null or p_category not in ('vehicle','home') then raise exception 'deadline item category unavailable'; end if;
  return query select to_jsonb(di) from public.deadline_items di
    where di.owner_account_id=v_account_id and di.category=p_category
    order by di.name,di.created_at,di.id;
end $$;

create or replace function public.create_my_deadline_item(p_category text,p_item_type text,p_name text,p_plate text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_item public.deadline_items%rowtype;
begin
  if p_category is null or p_item_type is null
    or (p_category='vehicle' and p_item_type not in ('car','motorcycle','other'))
    or (p_category='home' and p_item_type<>'residence')
    or p_category not in ('vehicle','home') then raise exception 'deadline item type unavailable'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'deadline item name required'; end if;
  insert into public.deadline_items(owner_account_id,category,item_type,name,plate)
    values(v_account_id,p_category,p_item_type,btrim(p_name),case when p_category='vehicle' then nullif(upper(btrim(p_plate)), '') else null end)
    returning * into v_item;
  return to_jsonb(v_item);
end $$;

create or replace function public.update_my_deadline_item(p_item_id uuid,p_item_type text,p_name text,p_plate text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_item public.deadline_items%rowtype;
begin
  perform public.assert_my_deadline_item(p_item_id);
  select * into v_item from public.deadline_items where id=p_item_id and owner_account_id=v_account_id;
  if p_item_type is null or (v_item.category='vehicle' and p_item_type not in ('car','motorcycle','other'))
    or (v_item.category='home' and p_item_type<>'residence') then raise exception 'deadline item type unavailable'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'deadline item name required'; end if;
  update public.deadline_items di set item_type=p_item_type,name=btrim(p_name),
    plate=case when di.category='vehicle' then nullif(upper(btrim(p_plate)), '') else null end,updated_at=now()
    where di.id=p_item_id and di.owner_account_id=v_account_id returning di.* into v_item;
  return to_jsonb(v_item);
end $$;

create or replace function public.create_deadline_for_item(p_item_id uuid,p_title text,p_category text,p_first_due_on date,p_recurrence_months smallint default null,p_reminder_days smallint default 30,p_notes text default null,p_deadline_kind text default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_deadline_id uuid;
begin
  perform public.assert_my_deadline_item(p_item_id);
  if p_deadline_kind is not null and p_deadline_kind not in ('vehicle_insurance','vehicle_tax','vehicle_inspection','vehicle_service','home_heating','home_insurance','home_taxes','home_waste') then raise exception 'deadline kind unavailable'; end if;
  if p_deadline_kind is not null and not exists (
    select 1 from public.deadline_items di where di.id=p_item_id and di.owner_account_id=v_account_id
      and ((p_deadline_kind like 'vehicle_%' and di.category='vehicle') or (p_deadline_kind like 'home_%' and di.category='home'))
  ) then raise exception 'deadline kind requires an owned item of the matching category'; end if;
  insert into public.deadlines(owner_account_id,deadline_item_id,deadline_kind,title,category,first_due_on,recurrence_months,reminder_days,notes)
    values(v_account_id,p_item_id,p_deadline_kind,nullif(btrim(p_title),''),nullif(btrim(p_category),''),p_first_due_on,p_recurrence_months,coalesce(p_reminder_days,30),nullif(btrim(p_notes),'')) returning id into v_deadline_id;
  return v_deadline_id;
end $$;

create or replace function public.ensure_my_home_item()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account_id uuid := public.require_current_account(); v_item public.deadline_items%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended(v_account_id::text || ':home:residence:Casa', 0));
  select * into v_item from public.deadline_items di
    where di.owner_account_id=v_account_id and di.category='home' and di.item_type='residence' and di.name='Casa'
    order by di.created_at,di.id limit 1;
  if not found then
    insert into public.deadline_items(owner_account_id,category,item_type,name,plate,image_path)
      values(v_account_id,'home','residence','Casa',null,null) returning * into v_item;
  end if;
  return to_jsonb(v_item);
end $$;

alter function public.assert_deadline_item_owner() owner to postgres;
alter function public.get_my_deadline_items(text) owner to postgres;
alter function public.create_my_deadline_item(text,text,text,text) owner to postgres;
alter function public.update_my_deadline_item(uuid,text,text,text) owner to postgres;
alter function public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text) owner to postgres;
alter function public.ensure_my_home_item() owner to postgres;

revoke all on function public.ensure_my_home_item() from public,anon;
grant execute on function public.get_my_deadline_items(text),public.create_my_deadline_item(text,text,text,text),public.update_my_deadline_item(uuid,text,text,text),public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text),public.ensure_my_home_item() to authenticated;

commit;
