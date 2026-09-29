-- FamilArea — optional vehicle registration plate on deadline-management items.

begin;

alter table public.deadline_items
  add column if not exists plate text null;

drop function if exists public.create_my_deadline_item(text, text, text);
create function public.create_my_deadline_item(
  p_category text,
  p_item_type text,
  p_name text,
  p_plate text default null
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

  insert into public.deadline_items(owner_account_id, category, item_type, name, plate)
  values (
    v_account_id,
    p_category,
    p_item_type,
    btrim(p_name),
    nullif(upper(btrim(p_plate)), '')
  )
  returning * into v_item;

  return to_jsonb(v_item);
end;
$$;

drop function if exists public.update_my_deadline_item(uuid, text, text);
create function public.update_my_deadline_item(
  p_item_id uuid,
  p_item_type text,
  p_name text,
  p_plate text default null
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
      plate = nullif(upper(btrim(p_plate)), ''),
      updated_at = now()
  where di.id = p_item_id
    and di.owner_account_id = v_account_id
  returning di.* into v_item;

  return to_jsonb(v_item);
end;
$$;

alter function public.create_my_deadline_item(text, text, text, text) owner to postgres;
alter function public.update_my_deadline_item(uuid, text, text, text) owner to postgres;

revoke all on function public.create_my_deadline_item(text, text, text, text) from public, anon;
revoke all on function public.update_my_deadline_item(uuid, text, text, text) from public, anon;
grant execute on function public.create_my_deadline_item(text, text, text, text) to authenticated;
grant execute on function public.update_my_deadline_item(uuid, text, text, text) to authenticated;

commit;
