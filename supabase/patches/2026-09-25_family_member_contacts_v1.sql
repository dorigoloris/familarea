-- FamilArea — V1 selezione Contact esistente per membro Famiglia.
begin;

create unique index family_members_unique_contact_per_family
  on public.family_members(family_id,contact_id)
  where contact_id is not null;

create or replace function public.create_family_member(
  p_first_name text,p_relationship text,p_member_type text default 'person',p_last_name text default null,
  p_birth_date date default null,p_pet_species text default null,p_contact_id uuid default null
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_family uuid; v uuid;
begin
  select id into v_family from public.families where owner_account_id=public.require_personal_account();
  if v_family is null then raise exception 'family not found'; end if;
  if p_contact_id is not null and not exists(select 1 from public.contacts c where c.id=p_contact_id and c.owner_account_id=public.require_personal_account()) then raise exception 'invalid contact'; end if;
  if p_contact_id is not null and exists(select 1 from public.family_members fm where fm.family_id=v_family and fm.contact_id=p_contact_id) then raise exception 'Questo contatto fa gia parte della Famiglia.'; end if;
  insert into public.family_members(family_id,first_name,last_name,relationship,member_type,birth_date,pet_species,contact_id)
  values(v_family,nullif(btrim(p_first_name),''),nullif(btrim(p_last_name),''),nullif(btrim(p_relationship),''),p_member_type,p_birth_date,nullif(btrim(p_pet_species),''),p_contact_id)
  returning id into v;
  return v;
exception when unique_violation then raise exception 'Questo contatto fa gia parte della Famiglia.';
end $$;

create or replace function public.update_family_member(
  p_member_id uuid,p_first_name text,p_relationship text,p_member_type text,p_last_name text default null,
  p_birth_date date default null,p_pet_species text default null,p_contact_id uuid default null
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.family_members%rowtype; v_family uuid;
begin
  select id into v_family from public.families where owner_account_id=public.require_personal_account();
  if v_family is null then raise exception 'family not found'; end if;
  if p_contact_id is not null and not exists(select 1 from public.contacts c where c.id=p_contact_id and c.owner_account_id=public.require_personal_account()) then raise exception 'invalid contact'; end if;
  if p_contact_id is not null and exists(select 1 from public.family_members fm where fm.family_id=v_family and fm.contact_id=p_contact_id and fm.id<>p_member_id) then raise exception 'Questo contatto fa gia parte della Famiglia.'; end if;
  update public.family_members fm set first_name=nullif(btrim(p_first_name),''),last_name=nullif(btrim(p_last_name),''),relationship=nullif(btrim(p_relationship),''),member_type=p_member_type,birth_date=p_birth_date,pet_species=nullif(btrim(p_pet_species),''),contact_id=p_contact_id
  where fm.id=p_member_id and fm.family_id=v_family returning fm.* into v;
  if not found then raise exception 'permission denied'; end if;
  return to_jsonb(v);
exception when unique_violation then raise exception 'Questo contatto fa gia parte della Famiglia.';
end $$;

alter function public.create_family_member(text,text,text,text,date,text,uuid) owner to postgres;
alter function public.update_family_member(uuid,text,text,text,text,date,text,uuid) owner to postgres;
revoke all on function public.create_family_member(text,text,text,text,date,text,uuid),public.update_family_member(uuid,text,text,text,text,date,text,uuid) from public,anon;
grant execute on function public.create_family_member(text,text,text,text,date,text,uuid),public.update_family_member(uuid,text,text,text,text,date,text,uuid) to authenticated;

commit;
