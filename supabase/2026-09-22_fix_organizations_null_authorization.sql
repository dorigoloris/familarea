-- FamilArea — fail closed when Organization membership is absent.
begin;

create or replace function public.update_organization(p_organization_id uuid,p_name text,p_organization_type text,p_description text,p_status text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_role text; v_current_status text;
begin
  select cor.role into v_role
  from public.current_organization_role(p_organization_id) cor;

  if v_role is null or v_role not in ('owner','admin') then
    raise exception 'permission denied';
  end if;

  select o.status into v_current_status
  from public.organizations o
  where o.id=p_organization_id
  for update;

  if not found then
    raise exception 'Organizzazione non trovata';
  end if;

  if btrim(coalesce(p_name,''))='' or btrim(coalesce(p_organization_type,''))='' or p_status not in ('draft','active','archived') then
    raise exception 'Dati organizzazione non validi';
  end if;

  if v_role='admin' and p_status is distinct from v_current_status then
    raise exception 'permission denied';
  end if;

  update public.organizations
  set name=btrim(p_name), organization_type=btrim(p_organization_type), description=nullif(btrim(coalesce(p_description,'')),''), status=p_status
  where id=p_organization_id;
end;
$$;

create or replace function public.get_organization_areas(p_organization_id uuid)
returns table(id uuid,name text,area_type text,created_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_role text;
begin
  select cor.role into v_role
  from public.current_organization_role(p_organization_id) cor;

  if v_role is null or v_role not in ('owner','admin') then
    raise exception 'permission denied';
  end if;

  return query
  select a.id,a.name,a.area_type,a.created_at
  from public.areas a
  where a.organization_id=p_organization_id
  order by a.name,a.id;
end;
$$;

create or replace function public.link_area_to_organization(p_organization_id uuid,p_area_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_existing_organization_id uuid;
begin
  select cor.profile_id,cor.role into v_profile,v_role
  from public.current_organization_role(p_organization_id) cor;

  if v_role is null or v_role not in ('owner','admin') then
    raise exception 'permission denied';
  end if;

  if not exists(
    select 1
    from public.area_memberships am
    where am.area_id=p_area_id and am.profile_id=v_profile and am.role='admin'
  ) then
    raise exception 'permission denied';
  end if;

  select a.organization_id into v_existing_organization_id
  from public.areas a
  where a.id=p_area_id
  for update;

  if not found then
    raise exception 'Area non trovata';
  end if;

  if v_existing_organization_id is not null and v_existing_organization_id is distinct from p_organization_id then
    raise exception 'Area gia collegata a un''altra Organizzazione';
  end if;

  if v_existing_organization_id is null then
    update public.areas set organization_id=p_organization_id where id=p_area_id;
  end if;
end;
$$;

alter function public.update_organization(uuid,text,text,text,text) owner to postgres;
alter function public.get_organization_areas(uuid) owner to postgres;
alter function public.link_area_to_organization(uuid,uuid) owner to postgres;
revoke all on function public.update_organization(uuid,text,text,text,text),public.get_organization_areas(uuid),public.link_area_to_organization(uuid,uuid) from public;
grant execute on function public.update_organization(uuid,text,text,text,text),public.get_organization_areas(uuid),public.link_area_to_organization(uuid,uuid) to authenticated;

commit;
