-- FamilArea — deadline-item images for every owned item category.
begin;
create or replace function public.can_read_my_deadline_item_image_path(p_path text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select p_path is not null and exists (select 1 from public.deadline_items di where di.owner_account_id=public.require_current_account() and p_path=di.owner_account_id::text||'/'||di.id::text||'/image')
$$;
create or replace function public.can_manage_my_deadline_item_image_path(p_path text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select p_path is not null and exists (select 1 from public.deadline_items di where di.owner_account_id=public.require_current_account() and p_path=di.owner_account_id::text||'/'||di.id::text||'/image')
$$;
create or replace function public.get_my_deadlines()
returns setof jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select to_jsonb(d) || jsonb_build_object('deadline_item_id',di.id,'deadline_item_name',di.name,'deadline_item_category',di.category,'deadline_item_image_path',di.image_path)
  from public.deadlines d left join public.deadline_items di on di.id=d.deadline_item_id and di.owner_account_id=d.owner_account_id
  where d.owner_account_id=public.require_current_account() order by d.first_due_on,d.created_at,d.id
$$;
alter function public.can_read_my_deadline_item_image_path(text) owner to postgres;
alter function public.can_manage_my_deadline_item_image_path(text) owner to postgres;
alter function public.get_my_deadlines() owner to postgres;
revoke all on function public.can_read_my_deadline_item_image_path(text),public.can_manage_my_deadline_item_image_path(text) from public,anon;
revoke all on function public.get_my_deadlines() from public,anon;
grant execute on function public.can_read_my_deadline_item_image_path(text),public.can_manage_my_deadline_item_image_path(text),public.get_my_deadlines() to authenticated;
commit;
