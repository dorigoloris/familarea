-- FamilArea — attività visibili dell'utente su tutte le Aree.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create function public.get_my_visible_activities()
returns table(
  activity_id uuid,
  area_id uuid,
  area_name text,
  area_type text,
  title text,
  notes text,
  activity_type text,
  status text,
  priority text,
  starts_at timestamptz,
  due_at timestamptz,
  is_all_day boolean,
  visibility text,
  created_by_profile_id uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile_id is null then
    raise exception 'permission denied';
  end if;

  return query
  select
    a.id,
    ar.id,
    ar.name,
    ar.area_type,
    a.title,
    a.notes,
    a.activity_type,
    a.status,
    a.priority,
    a.starts_at,
    a.due_at,
    a.is_all_day,
    a.visibility,
    a.created_by_profile_id,
    a.created_at,
    a.updated_at
  from public.area_memberships am
  join public.areas ar on ar.id = am.area_id
  join public.area_activities a on a.area_id = am.area_id
  where am.profile_id = v_profile_id
    and am.role in ('admin', 'member')
    and (
      a.visibility = 'area'
      or a.created_by_profile_id = v_profile_id
      or (
        a.visibility = 'creator_assignees'
        and exists (
          select 1
          from public.activity_assignees aa
          where aa.activity_id = a.id
            and aa.profile_id = v_profile_id
        )
      )
    )
  order by coalesce(a.due_at, a.starts_at) asc nulls last, a.created_at asc, a.id asc;
end;
$$;

revoke all on function public.get_my_visible_activities() from public;
grant execute on function public.get_my_visible_activities() to authenticated;

commit;
