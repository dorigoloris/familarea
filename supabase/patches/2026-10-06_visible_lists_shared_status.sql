-- FamilArea — expose the accepted-sharing state in the visible-list payload.
-- Personal lists are shared only after at least one participant has accepted.

begin;

create or replace function public.get_visible_lists()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp
as $$
  select to_jsonb(l) || jsonb_build_object(
    'can_edit_items', public.can_edit_list_items(l.id),
    'can_manage_list', public.can_manage_list(l.id),
    'is_shared', case
      when l.area_id is null then exists (
        select 1
        from public.list_participants lp
        where lp.list_id = l.id
      )
      else false
    end
  )
  from public.lists l
  where public.can_read_list(l.id)
  order by l.updated_at desc
$$;

commit;
