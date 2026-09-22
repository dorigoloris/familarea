-- FamilArea — Organizations V1. Deliberately not applied by this file itself.
begin;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) > 0),
  organization_type text not null check (char_length(btrim(organization_type)) > 0),
  description text,
  status text not null default 'draft' check (status in ('draft','active','archived')),
  created_by_profile_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  role text not null check (role in ('owner','admin','collaborator')),
  added_by_profile_id uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  primary key (organization_id, profile_id)
);
create index organization_members_profile_idx on public.organization_members(profile_id, organization_id);
alter table public.areas add column organization_id uuid references public.organizations(id) on delete set null;
create index areas_organization_idx on public.areas(organization_id) where organization_id is not null;

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.organizations no force row level security;
alter table public.organization_members no force row level security;
revoke all on public.organizations, public.organization_members from public, anon, authenticated;

create function public.set_organization_updated_at() returns trigger language plpgsql set search_path=public,pg_temp as $$ begin new.updated_at=now(); return new; end; $$;
create trigger organizations_set_updated_at before update on public.organizations for each row execute function public.set_organization_updated_at();

create function public.current_organization_role(p_organization_id uuid)
returns table(profile_id uuid, role text) language sql security definer stable set search_path=public,pg_temp as $$
  select om.profile_id,om.role from public.organization_members om join public.profiles p on p.id=om.profile_id
  where om.organization_id=p_organization_id and p.user_id=auth.uid();
$$;

create function public.create_organization(p_name text,p_organization_type text,p_description text default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'permission denied'; end if;
  select id into v_profile from public.profiles where user_id=auth.uid();
  if v_profile is null or btrim(coalesce(p_name,''))='' or btrim(coalesce(p_organization_type,''))='' then raise exception 'Dati organizzazione non validi'; end if;
  insert into public.organizations(name,organization_type,description,created_by_profile_id) values(btrim(p_name),btrim(p_organization_type),nullif(btrim(coalesce(p_description,'')),''),v_profile) returning id into v_id;
  insert into public.organization_members(organization_id,profile_id,role,added_by_profile_id) values(v_id,v_profile,'owner',v_profile);
  return v_id;
end; $$;

create function public.get_my_organizations()
returns table(id uuid,name text,organization_type text,description text,status text,my_role text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid;
begin select id into v_profile from public.profiles where user_id=auth.uid(); if v_profile is null then raise exception 'permission denied'; end if;
return query select o.id,o.name,o.organization_type,o.description,o.status,om.role,o.created_at,o.updated_at from public.organization_members om join public.organizations o on o.id=om.organization_id where om.profile_id=v_profile order by o.name,o.id; end; $$;

create function public.get_organization(p_organization_id uuid)
returns table(id uuid,name text,organization_type text,description text,status text,my_role text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
begin if not exists(select 1 from public.current_organization_role(p_organization_id)) then raise exception 'permission denied'; end if; return query select o.id,o.name,o.organization_type,o.description,o.status,r.role,o.created_at,o.updated_at from public.organizations o cross join public.current_organization_role(p_organization_id) r where o.id=p_organization_id; end; $$;

create function public.update_organization(p_organization_id uuid,p_name text,p_organization_type text,p_description text,p_status text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_role text; v_current_status text;
begin select role into v_role from public.current_organization_role(p_organization_id); if v_role not in ('owner','admin') then raise exception 'permission denied'; end if; select status into v_current_status from public.organizations where id=p_organization_id for update; if not found then raise exception 'Organizzazione non trovata'; end if; if btrim(coalesce(p_name,''))='' or btrim(coalesce(p_organization_type,''))='' or p_status not in ('draft','active','archived') then raise exception 'Dati organizzazione non validi'; end if; if v_role='admin' and p_status is distinct from v_current_status then raise exception 'permission denied'; end if; update public.organizations set name=btrim(p_name),organization_type=btrim(p_organization_type),description=nullif(btrim(coalesce(p_description,'')),''),status=p_status where id=p_organization_id; end; $$;

create function public.get_organization_areas(p_organization_id uuid)
returns table(id uuid,name text,area_type text,created_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_role text;
begin select role into v_role from public.current_organization_role(p_organization_id); if v_role not in ('owner','admin') then raise exception 'permission denied'; end if; return query select a.id,a.name,a.area_type,a.created_at from public.areas a where a.organization_id=p_organization_id order by a.name,a.id; end; $$;

create function public.link_area_to_organization(p_organization_id uuid,p_area_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid; v_role text; v_existing_organization_id uuid;
begin select profile_id,role into v_profile,v_role from public.current_organization_role(p_organization_id); if v_role not in ('owner','admin') then raise exception 'permission denied'; end if; if not exists(select 1 from public.area_memberships where area_id=p_area_id and profile_id=v_profile and role='admin') then raise exception 'permission denied'; end if; select organization_id into v_existing_organization_id from public.areas where id=p_area_id for update; if not found then raise exception 'Area non trovata'; end if; if v_existing_organization_id is not null and v_existing_organization_id is distinct from p_organization_id then raise exception 'Area gia collegata a un''altra Organizzazione'; end if; if v_existing_organization_id is null then update public.areas set organization_id=p_organization_id where id=p_area_id; end if; end; $$;

alter function public.set_organization_updated_at() owner to postgres;
alter function public.current_organization_role(uuid) owner to postgres;
alter function public.create_organization(text,text,text) owner to postgres;
alter function public.get_my_organizations() owner to postgres;
alter function public.get_organization(uuid) owner to postgres;
alter function public.update_organization(uuid,text,text,text,text) owner to postgres;
alter function public.get_organization_areas(uuid) owner to postgres;
alter function public.link_area_to_organization(uuid,uuid) owner to postgres;
revoke all on function public.set_organization_updated_at(),public.current_organization_role(uuid),public.create_organization(text,text,text),public.get_my_organizations(),public.get_organization(uuid),public.update_organization(uuid,text,text,text,text),public.get_organization_areas(uuid),public.link_area_to_organization(uuid,uuid) from public;
grant execute on function public.create_organization(text,text,text),public.get_my_organizations(),public.get_organization(uuid),public.update_organization(uuid,text,text,text,text),public.get_organization_areas(uuid),public.link_area_to_organization(uuid,uuid) to authenticated;
commit;
