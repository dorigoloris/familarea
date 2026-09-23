-- FamilArea: ricostruzione completa delle sole strutture applicative public.
-- NON elimina o ricrea auth.users né altre strutture interne Supabase.

begin;

-- Le policy RLS dipendono dalle funzioni helper. Le rimuoviamo per prime,
-- limitatamente alle quattro tabelle applicative, indipendentemente dal nome
-- usato in una versione precedente dello schema.
do $$
declare
  v_policy record;
begin
  for v_policy in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles', 'areas', 'area_memberships', 'profile_contacts')
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      v_policy.policyname,
      v_policy.schemaname,
      v_policy.tablename
    );
  end loop;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.delete_area_member_contact(uuid, uuid, uuid);
drop function if exists public.set_area_member_contact_primary(uuid, uuid, uuid);
drop function if exists public.update_area_member_contact(uuid, uuid, uuid, text);
drop function if exists public.add_area_member_contact(uuid, uuid, text, text, boolean);
drop function if exists public.get_area_member_contacts(uuid, uuid);
drop function if exists public.require_area_contact_admin(uuid, uuid);
drop function if exists public.update_area_member(uuid, uuid, text, text, date);
drop function if exists public.add_area_member(uuid, text, text, date, text);
drop function if exists public.create_area(text, text);
drop function if exists public.handle_new_user();
drop function if exists public.can_view_profile(uuid);
drop function if exists public.is_area_member(uuid);
drop table if exists public.profile_contacts;
drop table if exists public.area_memberships;
drop table if exists public.areas;
drop table if exists public.profiles;

create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key default gen_random_uuid(), user_id uuid unique references auth.users(id) on delete cascade,
  first_name text not null, last_name text, birth_date date, created_at timestamptz not null default now()
);
create table public.areas (
  id uuid primary key default gen_random_uuid(), name text not null check (char_length(btrim(name)) > 0),
  area_type text not null check (area_type in ('family','school','sport','friends','course','travel','other')),
  created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now()
);
create table public.area_memberships (
  id uuid primary key default gen_random_uuid(), area_id uuid not null references public.areas(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('admin','member','managed')), created_at timestamptz not null default now(), unique(area_id, profile_id)
);
create table public.profile_contacts (
  id uuid primary key default gen_random_uuid(), area_id uuid not null references public.areas(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  contact_type text not null check (contact_type in ('email','phone')),
  contact_value text not null check (char_length(btrim(contact_value)) > 0), is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  constraint profile_contacts_area_profile_membership_fkey foreign key(area_id, profile_id)
    references public.area_memberships(area_id, profile_id) on delete cascade,
  constraint profile_contacts_email_normalized_check check(contact_type <> 'email' or contact_value = lower(btrim(contact_value))),
  constraint profile_contacts_phone_e164_check check(contact_type <> 'phone' or contact_value ~ '^\+[1-9][0-9]{1,14}$'),
  unique(area_id, profile_id, contact_type, contact_value)
);
create unique index profile_contacts_one_primary_per_type on public.profile_contacts(area_id, profile_id, contact_type) where is_primary = true;

alter table public.profiles enable row level security;
alter table public.areas enable row level security;
alter table public.area_memberships enable row level security;
alter table public.profile_contacts enable row level security;
alter table public.profiles no force row level security;
alter table public.areas no force row level security;
alter table public.area_memberships no force row level security;
alter table public.profile_contacts no force row level security;

create function public.is_area_member(p_area_id uuid) returns boolean language sql security definer stable set search_path = public, pg_temp as $$
  select exists(select 1 from public.area_memberships am join public.profiles p on p.id=am.profile_id where am.area_id=p_area_id and p.user_id=auth.uid());
$$;
create function public.can_view_profile(p_profile_id uuid) returns boolean language sql security definer stable set search_path = public, pg_temp as $$
  select exists(select 1 from public.profiles me where me.id=p_profile_id and me.user_id=auth.uid()) or exists(
    select 1 from public.area_memberships t join public.area_memberships me_am on me_am.area_id=t.area_id join public.profiles me on me.id=me_am.profile_id where t.profile_id=p_profile_id and me.user_id=auth.uid());
$$;
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin insert into public.profiles(user_id,first_name,last_name) values(new.id,coalesce(new.raw_user_meta_data->>'first_name',''),new.raw_user_meta_data->>'last_name'); return new; end;
$$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create function public.create_area(p_name text,p_area_type text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile uuid; v_area uuid;
begin
 select id into v_profile from public.profiles where user_id=auth.uid(); if v_profile is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
 insert into public.areas(name,area_type,created_by) values(btrim(p_name),p_area_type,v_profile) returning id into v_area;
 insert into public.area_memberships(area_id,profile_id,role) values(v_area,v_profile,'admin'); return v_area;
end; $$;
create function public.add_area_member(p_area_id uuid,p_first_name text,p_last_name text,p_birth_date date,p_role text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller uuid; v_profile uuid;
begin
 if p_role not in ('admin','member','managed') then raise exception 'Ruolo non valido: %',p_role; end if;
 select id into v_caller from public.profiles where user_id=auth.uid(); if v_caller is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
 if not exists(select 1 from public.area_memberships where area_id=p_area_id and profile_id=v_caller and role='admin') then raise exception 'permission denied: solo un admin dell''Area puÃ² aggiungere membri'; end if;
 insert into public.profiles(first_name,last_name,birth_date) values(btrim(p_first_name),nullif(btrim(coalesce(p_last_name,'')),''),p_birth_date) returning id into v_profile;
 insert into public.area_memberships(area_id,profile_id,role) values(p_area_id,v_profile,p_role); return v_profile;
end; $$;
create function public.update_area_member(p_area_id uuid,p_profile_id uuid,p_first_name text,p_last_name text,p_birth_date date) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller uuid;
begin
 select id into v_caller from public.profiles where user_id=auth.uid(); if v_caller is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
 if not exists(select 1 from public.area_memberships where area_id=p_area_id and profile_id=v_caller and role='admin') then raise exception 'permission denied: solo un admin dell''Area puÃ² modificare i membri'; end if;
 if not exists(select 1 from public.area_memberships where area_id=p_area_id and profile_id=p_profile_id) then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;
 if btrim(coalesce(p_first_name,''))='' then raise exception 'Il nome Ã¨ obbligatorio'; end if;
 update public.profiles set first_name=btrim(p_first_name),last_name=nullif(btrim(coalesce(p_last_name,'')),''),birth_date=p_birth_date where id=p_profile_id;
end; $$;

create function public.require_area_contact_admin(p_area_id uuid,p_profile_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller uuid;
begin
 select id into v_caller from public.profiles where user_id=auth.uid(); if v_caller is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
 if not exists(select 1 from public.area_memberships where area_id=p_area_id and profile_id=v_caller and role='admin') then raise exception 'permission denied: solo un admin dell''Area puÃ² gestire i contatti'; end if;
 if not exists(select 1 from public.area_memberships where area_id=p_area_id and profile_id=p_profile_id) then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;
end; $$;
create function public.get_area_member_contacts(p_area_id uuid,p_profile_id uuid) returns table(id uuid,contact_type text,contact_value text,is_primary boolean,created_at timestamptz) language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.require_area_contact_admin(p_area_id,p_profile_id); return query select pc.id,pc.contact_type,pc.contact_value,pc.is_primary,pc.created_at from public.profile_contacts pc where pc.area_id=p_area_id and pc.profile_id=p_profile_id order by pc.contact_type,pc.is_primary desc,pc.created_at,pc.id; end; $$;
create function public.add_area_member_contact(p_area_id uuid,p_profile_id uuid,p_contact_type text,p_contact_value text,p_is_primary boolean default false) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text:=lower(btrim(p_contact_type)); v_value text; v_primary boolean; v_id uuid;
begin
 perform public.require_area_contact_admin(p_area_id,p_profile_id); if v_type is null or v_type not in('email','phone') then raise exception 'Tipo di contatto non valido'; end if;
 v_value:=case when v_type='email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end; if coalesce(v_value,'')='' then raise exception 'Il valore del contatto Ã¨ obbligatorio'; end if;
 if v_type='phone' and v_value !~ '^\+[1-9][0-9]{1,14}$' then raise exception 'Il telefono deve essere nel formato internazionale E.164'; end if;
 perform 1 from public.profiles where id=p_profile_id for update; v_primary:=coalesce(p_is_primary,false) or not exists(select 1 from public.profile_contacts where area_id=p_area_id and profile_id=p_profile_id and contact_type=v_type);
 if v_primary then update public.profile_contacts set is_primary=false where area_id=p_area_id and profile_id=p_profile_id and contact_type=v_type; end if;
 insert into public.profile_contacts(area_id,profile_id,contact_type,contact_value,is_primary) values(p_area_id,p_profile_id,v_type,v_value,v_primary) returning id into v_id; return v_id;
end; $$;
create function public.update_area_member_contact(p_area_id uuid,p_profile_id uuid,p_contact_id uuid,p_contact_value text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text; v_value text;
begin
 perform public.require_area_contact_admin(p_area_id,p_profile_id); perform 1 from public.profiles where id=p_profile_id for update;
 select contact_type into v_type from public.profile_contacts where id=p_contact_id and area_id=p_area_id and profile_id=p_profile_id; if v_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
 v_value:=case when v_type='email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end; if coalesce(v_value,'')='' then raise exception 'Il valore del contatto Ã¨ obbligatorio'; end if;
 if v_type='phone' and v_value !~ '^\+[1-9][0-9]{1,14}$' then raise exception 'Il telefono deve essere nel formato internazionale E.164'; end if; update public.profile_contacts set contact_value=v_value where id=p_contact_id;
end; $$;
create function public.set_area_member_contact_primary(p_area_id uuid,p_profile_id uuid,p_contact_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text;
begin perform public.require_area_contact_admin(p_area_id,p_profile_id); perform 1 from public.profiles where id=p_profile_id for update; select contact_type into v_type from public.profile_contacts where id=p_contact_id and area_id=p_area_id and profile_id=p_profile_id; if v_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if; update public.profile_contacts set is_primary=false where area_id=p_area_id and profile_id=p_profile_id and contact_type=v_type; update public.profile_contacts set is_primary=true where id=p_contact_id; end; $$;
create function public.delete_area_member_contact(p_area_id uuid,p_profile_id uuid,p_contact_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_type text; v_primary boolean; v_next uuid;
begin
 perform public.require_area_contact_admin(p_area_id,p_profile_id); perform 1 from public.profiles where id=p_profile_id for update; select contact_type,is_primary into v_type,v_primary from public.profile_contacts where id=p_contact_id and area_id=p_area_id and profile_id=p_profile_id; if v_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if; delete from public.profile_contacts where id=p_contact_id;
 if v_primary then select id into v_next from public.profile_contacts where area_id=p_area_id and profile_id=p_profile_id and contact_type=v_type order by created_at,id limit 1; if v_next is not null then update public.profile_contacts set is_primary=true where id=v_next; end if; end if;
end; $$;

revoke all on public.profiles, public.areas, public.area_memberships, public.profile_contacts from public, authenticated;
grant select on public.profiles, public.areas, public.area_memberships to authenticated;
grant update(first_name,last_name,birth_date) on public.profiles to authenticated;
revoke all on function public.is_area_member(uuid), public.can_view_profile(uuid), public.handle_new_user(), public.require_area_contact_admin(uuid,uuid), public.create_area(text,text), public.add_area_member(uuid,text,text,date,text), public.update_area_member(uuid,uuid,text,text,date), public.get_area_member_contacts(uuid,uuid), public.add_area_member_contact(uuid,uuid,text,text,boolean), public.update_area_member_contact(uuid,uuid,uuid,text), public.set_area_member_contact_primary(uuid,uuid,uuid), public.delete_area_member_contact(uuid,uuid,uuid) from public;
grant execute on function public.is_area_member(uuid), public.can_view_profile(uuid), public.create_area(text,text), public.add_area_member(uuid,text,text,date,text), public.update_area_member(uuid,uuid,text,text,date), public.get_area_member_contacts(uuid,uuid), public.add_area_member_contact(uuid,uuid,text,text,boolean), public.update_area_member_contact(uuid,uuid,uuid,text), public.set_area_member_contact_primary(uuid,uuid,uuid), public.delete_area_member_contact(uuid,uuid,uuid) to authenticated;

create policy profiles_select_own on public.profiles for select to authenticated using(user_id=auth.uid());
create policy profiles_select_shared_area on public.profiles for select to authenticated using(public.can_view_profile(id));
create policy profiles_update_own on public.profiles for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy areas_select_member on public.areas for select to authenticated using(public.is_area_member(id));
create policy area_memberships_select_own_area on public.area_memberships for select to authenticated using(public.is_area_member(area_id));

commit;
