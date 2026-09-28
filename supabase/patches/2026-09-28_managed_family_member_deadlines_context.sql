-- FamilArea — managed Family member context, first step: read-only deadlines.
-- A managed member is not an authenticated account and never receives a Profile.

begin;

create or replace function public.assert_manage_owned_family_member(
  p_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
begin
  if p_member_id is null then
    raise exception 'family member unavailable';
  end if;

  if not exists (
    select 1
    from public.family_members fm
    join public.families f on f.id = fm.family_id
    where fm.id = p_member_id
      and f.owner_account_id = v_owner_account_id
  ) then
    raise exception 'family member unavailable';
  end if;
end;
$$;

create or replace function public.get_my_managed_family_member(
  p_member_id uuid
)
returns table(
  id uuid,
  first_name text,
  last_name text,
  member_type text,
  pet_species text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
begin
  perform public.assert_manage_owned_family_member(p_member_id);

  return query
  select fm.id, fm.first_name, fm.last_name, fm.member_type, fm.pet_species
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_member_id
    and f.owner_account_id = v_owner_account_id;
end;
$$;

create or replace function public.get_my_deadlines_for_managed_member(
  p_member_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
begin
  perform public.assert_manage_owned_family_member(p_member_id);

  return query
  select to_jsonb(d)
  from public.deadlines d
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
  order by d.first_due_on, d.created_at, d.id;
end;
$$;

revoke all on function public.assert_manage_owned_family_member(uuid) from public, anon, authenticated;
revoke all on function public.get_my_managed_family_member(uuid) from public, anon;
revoke all on function public.get_my_deadlines_for_managed_member(uuid) from public, anon;

grant execute on function public.get_my_managed_family_member(uuid) to authenticated;
grant execute on function public.get_my_deadlines_for_managed_member(uuid) to authenticated;

alter function public.assert_manage_owned_family_member(uuid) owner to postgres;
alter function public.get_my_managed_family_member(uuid) owner to postgres;
alter function public.get_my_deadlines_for_managed_member(uuid) owner to postgres;

commit;
