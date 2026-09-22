-- FamilArea next baseline. LOCAL DESIGN ONLY: do not apply to the current project.
begin;
create extension if not exists pgcrypto;

create type public.account_type as enum ('personal','organization');
create type public.organization_role as enum ('owner','admin','collaborator');
create type public.area_role as enum ('admin','member');
create type public.organization_status as enum ('draft','active','archived');
create type public.activity_status as enum ('open','completed','cancelled');
create type public.priority_level as enum ('low','normal','high');
create type public.invite_status as enum ('pending','accepted','declined','revoked','expired');

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  account_type public.account_type not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  account_id uuid unique references public.accounts(id) on delete cascade,
  first_name text not null check (btrim(first_name)<>''), last_name text,
  birth_date date, avatar_path text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null unique references public.accounts(id) on delete cascade,
  name text not null check (btrim(name)<>''), organization_type text not null check (btrim(organization_type)<>''),
  description text, status public.organization_status not null default 'active',
  contact_name text, contact_email text, contact_phone text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role public.organization_role not null, added_by_account_id uuid references public.accounts(id) on delete set null,
  joined_at timestamptz not null default now(), primary key(organization_id,profile_id)
);

create table public.areas (
  id uuid primary key default gen_random_uuid(),
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  created_by_account_id uuid references public.accounts(id) on delete set null,
  name text not null check (btrim(name)<>''), area_type text not null check (btrim(area_type)<>''), description text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.area_memberships (
  area_id uuid not null references public.areas(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role public.area_role not null default 'member', added_by_account_id uuid references public.accounts(id) on delete set null,
  created_at timestamptz not null default now(), primary key(area_id,profile_id)
);

create table public.activities (
  id uuid primary key default gen_random_uuid(), owner_account_id uuid references public.accounts(id) on delete cascade,
  area_id uuid references public.areas(id) on delete cascade,
  title text not null check(btrim(title)<>''), description text, activity_type text not null default 'task',
  status public.activity_status not null default 'open', priority public.priority_level not null default 'normal',
  starts_at timestamptz, due_at timestamptz, is_all_day boolean not null default false,
  recurrence_frequency text, recurrence_interval smallint, recurrence_weekdays smallint[], recurrence_until date, recurrence_timezone text,
  created_by_account_id uuid references public.accounts(id) on delete set null,
  completed_by_account_id uuid references public.accounts(id) on delete set null, completed_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check ((owner_account_id is not null and area_id is null) or (owner_account_id is null and area_id is not null)),
  check (due_at is null or starts_at is null or due_at>=starts_at)
);
create table public.activity_assignees (
  activity_id uuid not null references public.activities(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by_account_id uuid references public.accounts(id) on delete set null,
  primary key(activity_id,profile_id)
);
create table public.events (
  id uuid primary key default gen_random_uuid(), owner_account_id uuid references public.accounts(id) on delete cascade,
  area_id uuid references public.areas(id) on delete cascade,
  title text not null check(btrim(title)<>''), description text, starts_at timestamptz not null, ends_at timestamptz,
  is_all_day boolean not null default false, location text, status text not null default 'active',
  recurrence_frequency text, recurrence_until date, created_by_account_id uuid references public.accounts(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check ((owner_account_id is not null and area_id is null) or (owner_account_id is null and area_id is not null)), check(ends_at is null or ends_at>=starts_at)
);
create table public.event_participants (event_id uuid not null references public.events(id) on delete cascade, profile_id uuid not null references public.profiles(id) on delete cascade, status text not null default 'pending', primary key(event_id,profile_id));
create table public.lists (
  id uuid primary key default gen_random_uuid(), owner_account_id uuid references public.accounts(id) on delete cascade,
  area_id uuid references public.areas(id) on delete cascade, title text not null check(btrim(title)<>''), description text,
  created_by_account_id uuid references public.accounts(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check ((owner_account_id is not null and area_id is null) or (owner_account_id is null and area_id is not null))
);
create table public.list_items (id uuid primary key default gen_random_uuid(), list_id uuid not null references public.lists(id) on delete cascade, text text not null check(btrim(text)<>''), position integer not null default 0, status text not null default 'open', created_at timestamptz not null default now(), updated_at timestamptz not null default now());

create table public.contacts (id uuid primary key default gen_random_uuid(), owner_account_id uuid not null references public.accounts(id) on delete cascade, first_name text not null check(btrim(first_name)<>''), last_name text, birth_date date, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.contact_methods (id uuid primary key default gen_random_uuid(), contact_id uuid not null references public.contacts(id) on delete cascade, method_type text not null check(method_type in ('email','phone')), value text not null check(btrim(value)<>''), is_primary boolean not null default false, unique(contact_id,method_type,value));
create table public.families (id uuid primary key default gen_random_uuid(), owner_account_id uuid not null unique references public.accounts(id) on delete cascade, name text not null check(btrim(name)<>''), created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.family_members (id uuid primary key default gen_random_uuid(), family_id uuid not null references public.families(id) on delete cascade, member_type text not null check(member_type in ('person','pet')), first_name text not null check(btrim(first_name)<>''), last_name text, relationship text not null check(btrim(relationship)<>''), birth_date date, pet_species text, linked_profile_id uuid references public.profiles(id) on delete set null, contact_id uuid references public.contacts(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.family_access (family_id uuid not null references public.families(id) on delete cascade, profile_id uuid not null references public.profiles(id) on delete cascade, role text not null check(role in ('owner','adult')), primary key(family_id,profile_id));

create table public.deadlines (id uuid primary key default gen_random_uuid(), owner_account_id uuid not null references public.accounts(id) on delete cascade, title text not null check(btrim(title)<>''), category text not null, first_due_on date not null, recurrence_months smallint, terminated_on date, reminder_days smallint not null default 30 check(reminder_days>=0), notes text, family_member_id uuid references public.family_members(id) on delete set null, status text not null default 'active', created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.deadline_occurrence_completions (deadline_id uuid not null references public.deadlines(id) on delete cascade, occurrence_on date not null, completed_at timestamptz not null default now(), completed_by_account_id uuid references public.accounts(id) on delete set null, primary key(deadline_id,occurrence_on));

create table public.interest_categories (id uuid primary key default gen_random_uuid(), name text not null, normalized_name text not null unique, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.interests (id uuid primary key default gen_random_uuid(), category_id uuid not null references public.interest_categories(id) on delete restrict, display_name text not null, normalized_name text not null unique, origin text not null check(origin in ('catalog','personal')), publication_status text not null check(publication_status in ('published','private')), status text not null default 'active', created_by_profile_id uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.profile_interests (profile_id uuid not null references public.profiles(id) on delete cascade, interest_id uuid not null references public.interests(id) on delete restrict, created_at timestamptz not null default now(), primary key(profile_id,interest_id));
create table public.interest_category_proposals (id uuid primary key default gen_random_uuid(), profile_id uuid not null references public.profiles(id) on delete cascade, proposed_name text not null, normalized_name text not null, note text, status text not null default 'pending', created_at timestamptz not null default now(), unique(profile_id,normalized_name));

create table public.area_invites (id uuid primary key default gen_random_uuid(), area_id uuid not null references public.areas(id) on delete cascade, invitee_email text not null, status public.invite_status not null default 'pending', token_hash text not null unique, invited_by_account_id uuid references public.accounts(id) on delete set null, expires_at timestamptz, accepted_by_profile_id uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(), responded_at timestamptz);
create table public.attachments (id uuid primary key default gen_random_uuid(), owner_account_id uuid references public.accounts(id) on delete cascade, area_id uuid references public.areas(id) on delete cascade, target_type text not null check(target_type in ('activity','event','deadline')), target_id uuid not null, storage_path text not null unique, original_filename text not null, mime_type text not null, byte_size bigint not null check(byte_size>=0), uploaded_by_account_id uuid not null references public.accounts(id) on delete restrict, created_at timestamptz not null default now(), check ((owner_account_id is not null and area_id is null) or (owner_account_id is null and area_id is not null)));

create function public.set_updated_at() returns trigger language plpgsql set search_path=public,pg_temp as $$ begin new.updated_at=now(); return new; end $$;
create function public.current_account_id() returns uuid language sql security definer stable set search_path=public,pg_temp as $$ select a.id from public.accounts a where a.auth_user_id=auth.uid() $$;
create function public.current_account_type() returns public.account_type language sql security definer stable set search_path=public,pg_temp as $$ select a.account_type from public.accounts a where a.auth_user_id=auth.uid() $$;
create function public.require_current_account() returns uuid language plpgsql security definer set search_path=public,pg_temp as $$ declare v uuid; begin select public.current_account_id() into v; if v is null then raise exception 'permission denied'; end if; return v; end $$;
create function public.require_personal_account() returns uuid language plpgsql security definer set search_path=public,pg_temp as $$ declare v uuid; begin select a.id into v from public.accounts a where a.auth_user_id=auth.uid() and a.account_type='personal'; if v is null then raise exception 'permission denied'; end if; return v; end $$;
create function public.require_personal_profile() returns uuid language plpgsql security definer set search_path=public,pg_temp as $$ declare v uuid; begin select p.id into v from public.profiles p where p.account_id=public.require_personal_account(); if v is null then raise exception 'permission denied'; end if; return v; end $$;
create function public.require_organization_account() returns uuid language plpgsql security definer set search_path=public,pg_temp as $$ declare v uuid; begin select a.id into v from public.accounts a where a.auth_user_id=auth.uid() and a.account_type='organization'; if v is null then raise exception 'permission denied'; end if; return v; end $$;
create function public.current_organization() returns uuid language plpgsql security definer set search_path=public,pg_temp as $$ declare v uuid; begin select o.id into v from public.organizations o where o.account_id=public.require_organization_account(); if v is null then raise exception 'permission denied'; end if; return v; end $$;
create function public.is_area_owner(p_area_id uuid) returns boolean language sql security definer stable set search_path=public,pg_temp as $$ select exists(select 1 from public.areas a where a.id=p_area_id and a.owner_account_id=public.current_account_id()) $$;
create function public.is_area_member(p_area_id uuid) returns boolean language sql security definer stable set search_path=public,pg_temp as $$ select exists(select 1 from public.area_memberships am where am.area_id=p_area_id and am.profile_id=(select p.id from public.profiles p where p.account_id=public.current_account_id())) $$;
create function public.can_manage_area(p_area_id uuid) returns boolean language sql security definer stable set search_path=public,pg_temp as $$ select public.is_area_owner(p_area_id) or exists(select 1 from public.area_memberships am where am.area_id=p_area_id and am.role='admin' and am.profile_id=(select p.id from public.profiles p where p.account_id=public.current_account_id())) $$;

-- This deferred constraint is the authoritative Account/subtype invariant. It is
-- checked at COMMIT, so the auth trigger can create account and subtype atomically.
create function public.assert_account_subtype_integrity() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account uuid; v_type public.account_type; v_profiles integer; v_organizations integer;
begin
  if tg_table_name='accounts' then
    if tg_op='DELETE' then v_account:=old.id; else v_account:=new.id; end if;
  else
    if tg_op='DELETE' then v_account:=old.account_id; else v_account:=new.account_id; end if;
  end if;
  select a.account_type into v_type from public.accounts a where a.id=v_account;
  if v_type is null then return null; end if; -- parent was deleted in the same transaction
  select count(*) into v_profiles from public.profiles p where p.account_id=v_account;
  select count(*) into v_organizations from public.organizations o where o.account_id=v_account;
  if (v_type='personal' and (v_profiles<>1 or v_organizations<>0)) or (v_type='organization' and (v_profiles<>0 or v_organizations<>1)) then
    raise exception 'invalid account subtype integrity';
  end if;
  return null;
end $$;
create constraint trigger accounts_subtype_integrity after insert or update or delete on public.accounts deferrable initially deferred for each row execute function public.assert_account_subtype_integrity();
create constraint trigger profiles_subtype_integrity after insert or update or delete on public.profiles deferrable initially deferred for each row execute function public.assert_account_subtype_integrity();
create constraint trigger organizations_subtype_integrity after insert or update or delete on public.organizations deferrable initially deferred for each row execute function public.assert_account_subtype_integrity();
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account uuid; v_type text; v_first_name text;
begin
  -- Google is always personal; no client metadata can turn an OAuth identity into an organization.
  if coalesce(new.raw_app_meta_data->>'provider','')='google' then v_type:='personal'; else v_type:=new.raw_user_meta_data->>'account_type'; end if;
  if v_type not in ('personal','organization') then raise exception 'invalid account type'; end if;
  insert into public.accounts(auth_user_id,account_type) values(new.id,v_type::public.account_type) returning id into v_account;
  if v_type='personal' then
    v_first_name:=coalesce(nullif(btrim(new.raw_user_meta_data->>'first_name'),''),nullif(btrim(new.raw_user_meta_data->>'given_name'),''),nullif(split_part(btrim(coalesce(new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'name','')),' ',1),''), 'Utente');
    insert into public.profiles(account_id,first_name,last_name) values(v_account,v_first_name,nullif(btrim(coalesce(new.raw_user_meta_data->>'last_name',new.raw_user_meta_data->>'family_name','')),''));
  else
    if btrim(coalesce(new.raw_user_meta_data->>'organization_name',''))='' or btrim(coalesce(new.raw_user_meta_data->>'organization_type',''))='' then raise exception 'invalid organization metadata'; end if;
    insert into public.organizations(account_id,name,organization_type,contact_name,contact_email,contact_phone) values(v_account,btrim(new.raw_user_meta_data->>'organization_name'),btrim(new.raw_user_meta_data->>'organization_type'),nullif(btrim(new.raw_user_meta_data->>'contact_name'),''),nullif(lower(btrim(new.raw_user_meta_data->>'contact_email')),''),nullif(btrim(new.raw_user_meta_data->>'contact_phone'),''));
  end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create trigger accounts_updated_at before update on public.accounts for each row execute function public.set_updated_at();
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger organizations_updated_at before update on public.organizations for each row execute function public.set_updated_at();
create trigger areas_updated_at before update on public.areas for each row execute function public.set_updated_at();
create trigger activities_updated_at before update on public.activities for each row execute function public.set_updated_at();
create trigger events_updated_at before update on public.events for each row execute function public.set_updated_at();
create trigger lists_updated_at before update on public.lists for each row execute function public.set_updated_at();
create trigger list_items_updated_at before update on public.list_items for each row execute function public.set_updated_at();
create trigger contacts_updated_at before update on public.contacts for each row execute function public.set_updated_at();
create trigger families_updated_at before update on public.families for each row execute function public.set_updated_at();
create trigger family_members_updated_at before update on public.family_members for each row execute function public.set_updated_at();
create trigger deadlines_updated_at before update on public.deadlines for each row execute function public.set_updated_at();
create trigger interest_categories_updated_at before update on public.interest_categories for each row execute function public.set_updated_at();
create trigger interests_updated_at before update on public.interests for each row execute function public.set_updated_at();

alter table public.accounts enable row level security; alter table public.profiles enable row level security; alter table public.organizations enable row level security; alter table public.organization_members enable row level security; alter table public.areas enable row level security; alter table public.area_memberships enable row level security; alter table public.activities enable row level security; alter table public.events enable row level security; alter table public.lists enable row level security; alter table public.list_items enable row level security; alter table public.contacts enable row level security; alter table public.contact_methods enable row level security; alter table public.families enable row level security; alter table public.family_members enable row level security; alter table public.family_access enable row level security; alter table public.deadlines enable row level security; alter table public.deadline_occurrence_completions enable row level security; alter table public.interest_categories enable row level security; alter table public.interests enable row level security; alter table public.profile_interests enable row level security; alter table public.interest_category_proposals enable row level security; alter table public.area_invites enable row level security; alter table public.attachments enable row level security;
revoke all on all tables in schema public from anon,authenticated;
revoke all on all functions in schema public from public;
alter function public.set_updated_at() owner to postgres; alter function public.current_account_id() owner to postgres; alter function public.current_account_type() owner to postgres; alter function public.require_current_account() owner to postgres; alter function public.require_personal_account() owner to postgres; alter function public.require_personal_profile() owner to postgres; alter function public.require_organization_account() owner to postgres; alter function public.current_organization() owner to postgres; alter function public.is_area_owner(uuid) owner to postgres; alter function public.is_area_member(uuid) owner to postgres; alter function public.can_manage_area(uuid) owner to postgres; alter function public.assert_account_subtype_integrity() owner to postgres; alter function public.handle_new_user() owner to postgres;
commit;
