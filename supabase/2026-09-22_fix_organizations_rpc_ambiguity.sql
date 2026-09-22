-- FamilArea — correct ambiguous PL/pgSQL identifier in Organizations V1 RPC.
begin;

create or replace function public.get_my_organizations()
returns table(id uuid,name text,organization_type text,description text,status text,my_role text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin
  select p.id into v_profile
  from public.profiles p
  where p.user_id = auth.uid();

  if v_profile is null then
    raise exception 'permission denied';
  end if;

  return query
  select o.id,o.name,o.organization_type,o.description,o.status,om.role,o.created_at,o.updated_at
  from public.organization_members om
  join public.organizations o on o.id=om.organization_id
  where om.profile_id=v_profile
  order by o.name,o.id;
end;
$$;

alter function public.get_my_organizations() owner to postgres;
revoke all on function public.get_my_organizations() from public;
grant execute on function public.get_my_organizations() to authenticated;

commit;
