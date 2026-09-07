-- FamilArea — Liste visibili dell'utente su tutte le Aree.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create function public.get_my_visible_lists()
returns table(
  list_id uuid,
  area_id uuid,
  area_name text,
  title text,
  description text,
  visibility text,
  created_by_profile_id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  total_item_count bigint,
  completed_item_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'permission denied';
  end if;

  return query
  select
    l.id,
    ar.id,
    ar.name,
    l.title,
    l.description,
    l.visibility,
    l.created_by_profile_id,
    l.created_at,
    l.updated_at,
    (select count(*) from public.area_list_items i where i.list_id = l.id),
    (select count(*) from public.area_list_items i where i.list_id = l.id and i.status = 'completed')
  from public.area_memberships am
  join public.areas ar on ar.id = am.area_id
  join public.area_lists l on l.area_id = am.area_id
  where am.profile_id = v_profile_id
    and am.role in ('admin', 'member')
    and (
      l.visibility = 'area'
      or l.created_by_profile_id = v_profile_id
      or (
        l.visibility = 'creator_participants'
        and exists (
          select 1
          from public.area_list_participants alp
          where alp.list_id = l.id
            and alp.profile_id = v_profile_id
        )
      )
    )
  order by l.updated_at desc, l.created_at desc, l.id;
end;
$$;

revoke all on function public.get_my_visible_lists() from public;
grant execute on function public.get_my_visible_lists() to authenticated;

commit;
