-- FamilArea — deadline management items, V1: vehicles only.
-- Items organize ordinary deadlines but do not yet link to them in this patch.

begin;

create table public.deadline_items (
  id uuid primary key default gen_random_uuid(),
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  category text not null check (category = btrim(category) and char_length(category) > 0),
  item_type text not null check (item_type = btrim(item_type) and char_length(item_type) > 0),
  name text not null check (name = btrim(name) and char_length(name) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index deadline_items_owner_category_name_idx
  on public.deadline_items (owner_account_id, category, name, id);

alter table public.deadline_items enable row level security;
revoke all on public.deadline_items from public, anon, authenticated;

create or replace function public.assert_my_deadline_item(
  p_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_item_id is null or not exists (
    select 1
    from public.deadline_items di
    where di.id = p_item_id
      and di.owner_account_id = public.require_current_account()
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
  v_account_id uuid := public.require_current_account();
begin
  if p_category is distinct from 'vehicle' then
    raise exception 'deadline item category unavailable';
  end if;

  return query
  select to_jsonb(di)
  from public.deadline_items di
  where di.owner_account_id = v_account_id
    and (p_category is null or di.category = p_category)
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
  v_item jsonb;
begin
  perform public.assert_my_deadline_item(p_item_id);

  select to_jsonb(di)
  into v_item
  from public.deadline_items di
  where di.id = p_item_id
    and di.owner_account_id = public.require_current_account();

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
  values (public.require_current_account(), p_category, p_item_type, btrim(p_name))
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
    and di.owner_account_id = public.require_current_account()
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
begin
  perform public.assert_my_deadline_item(p_item_id);

  delete from public.deadline_items di
  where di.id = p_item_id
    and di.owner_account_id = public.require_current_account();
end;
$$;

alter table public.deadline_items owner to postgres;
alter function public.assert_my_deadline_item(uuid) owner to postgres;
alter function public.get_my_deadline_items(text) owner to postgres;
alter function public.get_my_deadline_item(uuid) owner to postgres;
alter function public.create_my_deadline_item(text, text, text) owner to postgres;
alter function public.update_my_deadline_item(uuid, text, text) owner to postgres;
alter function public.delete_my_deadline_item(uuid) owner to postgres;

revoke all on function public.assert_my_deadline_item(uuid) from public, anon, authenticated;
revoke all on function public.get_my_deadline_items(text) from public, anon;
revoke all on function public.get_my_deadline_item(uuid) from public, anon;
revoke all on function public.create_my_deadline_item(text, text, text) from public, anon;
revoke all on function public.update_my_deadline_item(uuid, text, text) from public, anon;
revoke all on function public.delete_my_deadline_item(uuid) from public, anon;

grant execute on function public.get_my_deadline_items(text) to authenticated;
grant execute on function public.get_my_deadline_item(uuid) to authenticated;
grant execute on function public.create_my_deadline_item(text, text, text) to authenticated;
grant execute on function public.update_my_deadline_item(uuid, text, text) to authenticated;
grant execute on function public.delete_my_deadline_item(uuid) to authenticated;

commit;
