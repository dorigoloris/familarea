-- FamilArea — eventi visibili dell'utente su tutte le Aree.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create function public.get_my_visible_events()
returns table(
  event_id uuid,
  area_id uuid,
  area_name text,
  area_type text,
  title text,
  notes text,
  location text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_all_day boolean,
  status text,
  visibility text,
  created_by_profile_id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  own_participation_status text
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
    e.id,
    ar.id,
    ar.name,
    ar.area_type,
    e.title,
    e.notes,
    e.location,
    e.starts_at,
    e.ends_at,
    e.is_all_day,
    e.status,
    e.visibility,
    e.created_by_profile_id,
    e.created_at,
    e.updated_at,
    mine.participation_status
  from public.area_memberships am
  join public.areas ar on ar.id = am.area_id
  join public.area_events e on e.area_id = am.area_id
  left join public.event_participants mine
    on mine.event_id = e.id
    and mine.area_id = e.area_id
    and mine.profile_id = v_profile_id
  where am.profile_id = v_profile_id
    and am.role in ('admin', 'member')
    and (
      e.visibility = 'area'
      or e.created_by_profile_id = v_profile_id
      or (
        e.visibility = 'creator_participants'
        and mine.profile_id is not null
      )
    )
  order by e.starts_at asc, e.created_at asc, e.id asc;
end;
$$;

revoke all on function public.get_my_visible_events() from public;
grant execute on function public.get_my_visible_events() to authenticated;

commit;
