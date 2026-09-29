-- FamilArea — Gestione Scadenze V1 disponibile esclusivamente agli account personali.

begin;

create or replace function public.assert_my_deadline_item(
  p_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
begin
  if p_item_id is null or not exists (
    select 1
    from public.deadline_items di
    where di.id = p_item_id
      and di.owner_account_id = v_account_id
  ) then
    raise exception 'deadline item unavailable';
  end if;
end;
$$;

create or replace function public.get_my_deadline_items(
  p_category text default null
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
begin
  if p_category is distinct from 'vehicle' then
    raise exception 'deadline item category unavailable';
  end if;

  return query
  select to_jsonb(di)
  from public.deadline_items di
  where di.owner_account_id = v_account_id
    and di.category = p_category
  order by di.name, di.created_at, di.id;
end;
$$;

create or replace function public.get_my_deadline_item(
  p_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_item jsonb;
begin
  perform public.assert_my_deadline_item(p_item_id);

  select to_jsonb(di)
  into v_item
  from public.deadline_items di
  where di.id = p_item_id
    and di.owner_account_id = v_account_id;

  return v_item;
end;
$$;

create or replace function public.create_my_deadline_item(
  p_category text,
  p_item_type text,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_item public.deadline_items%rowtype;
begin
  if p_category is distinct from 'vehicle' then
    raise exception 'deadline item category unavailable';
  end if;
  if p_item_type is null or p_item_type not in ('car', 'motorcycle', 'other') then
    raise exception 'deadline item type unavailable';
  end if;
  if nullif(btrim(p_name), '') is null then
    raise exception 'deadline item name required';
  end if;

  insert into public.deadline_items(owner_account_id, category, item_type, name)
  values (v_account_id, p_category, p_item_type, btrim(p_name))
  returning * into v_item;

  return to_jsonb(v_item);
end;
$$;

create or replace function public.update_my_deadline_item(
  p_item_id uuid,
  p_item_type text,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_item public.deadline_items%rowtype;
begin
  perform public.assert_my_deadline_item(p_item_id);

  if p_item_type is null or p_item_type not in ('car', 'motorcycle', 'other') then
    raise exception 'deadline item type unavailable';
  end if;
  if nullif(btrim(p_name), '') is null then
    raise exception 'deadline item name required';
  end if;

  update public.deadline_items di
  set item_type = p_item_type,
      name = btrim(p_name),
      updated_at = now()
  where di.id = p_item_id
    and di.owner_account_id = v_account_id
  returning di.* into v_item;

  return to_jsonb(v_item);
end;
$$;

create or replace function public.delete_my_deadline_item(
  p_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
begin
  perform public.assert_my_deadline_item(p_item_id);

  delete from public.deadline_items di
  where di.id = p_item_id
    and di.owner_account_id = v_account_id;
end;
$$;

alter function public.assert_my_deadline_item(uuid) owner to postgres;
alter function public.get_my_deadline_items(text) owner to postgres;
alter function public.get_my_deadline_item(uuid) owner to postgres;
alter function public.create_my_deadline_item(text, text, text) owner to postgres;
alter function public.update_my_deadline_item(uuid, text, text) owner to postgres;
alter function public.delete_my_deadline_item(uuid) owner to postgres;

commit;
