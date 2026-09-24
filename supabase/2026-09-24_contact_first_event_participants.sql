-- FamilArea — Contact-first Event Participants and Event Invites.
-- The legacy event_participants rows are test data and are deliberately removed.

begin;

alter table public.contacts add constraint contacts_id_owner_account_id_key unique (id, owner_account_id);

create table public.contact_email_identities (
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  normalized_email text not null check (normalized_email = lower(btrim(normalized_email)) and normalized_email <> ''),
  contact_id uuid not null,
  primary key (owner_account_id, normalized_email),
  foreign key (contact_id, owner_account_id) references public.contacts(id, owner_account_id) on delete cascade
);

create table public.contact_profile_links (
  contact_id uuid primary key,
  owner_account_id uuid not null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  linked_at timestamptz not null default now(),
  linked_via text not null check (linked_via in ('event_invite', 'verified')),
  unique (owner_account_id, profile_id),
  foreign key (contact_id, owner_account_id) references public.contacts(id, owner_account_id) on delete cascade
);

create table public.event_invites (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete restrict,
  recipient_email text not null check (recipient_email = lower(btrim(recipient_email)) and recipient_email <> ''),
  token_hash text not null unique,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'revoked', 'expired')),
  expires_at timestamptz not null,
  invited_by_account_id uuid references public.accounts(id) on delete set null,
  accepted_by_profile_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (expires_at > created_at),
  check ((status = 'accepted') = (accepted_by_profile_id is not null)),
  check ((status in ('accepted', 'declined', 'revoked')) = (responded_at is not null))
);
create unique index event_invites_pending_email_idx on public.event_invites(event_id, recipient_email) where status = 'pending';
create index event_invites_recipient_idx on public.event_invites(recipient_email, status, expires_at);

do $$ begin
  if to_regprocedure('extensions.digest(bytea,text)') is null or to_regprocedure('extensions.gen_random_bytes(integer)') is null then
    raise exception 'pgcrypto must be available in schema extensions';
  end if;
end $$;

-- Deliberate reset: the remote contains only legacy test participants.
delete from public.event_participants;
alter table public.event_participants drop constraint event_participants_pkey;
alter table public.event_participants add column contact_id uuid not null references public.contacts(id) on delete restrict;
alter table public.event_participants add column accepted_at timestamptz;
alter table public.event_participants add column added_via text not null default 'direct' check (added_via in ('direct', 'event_invite'));
alter table public.event_participants add column added_by_account_id uuid references public.accounts(id) on delete set null;
alter table public.event_participants add column created_at timestamptz not null default now();
alter table public.event_participants add column updated_at timestamptz not null default now();
alter table public.event_participants alter column profile_id drop not null;
alter table public.event_participants drop constraint if exists event_participants_profile_id_fkey;
alter table public.event_participants add constraint event_participants_profile_id_fkey foreign key (profile_id) references public.profiles(id) on delete set null;
alter table public.event_participants drop constraint if exists event_participants_status_check;
alter table public.event_participants alter column status set default 'active';
alter table public.event_participants add constraint event_participants_status_check check (status in ('active', 'removed'));
alter table public.event_participants add primary key (event_id, contact_id);
create unique index event_participants_event_profile_idx on public.event_participants(event_id, profile_id) where profile_id is not null;

create or replace function public.set_event_participant_updated_at() returns trigger language plpgsql set search_path=public,pg_temp as $$ begin new.updated_at=now(); return new; end $$;
create trigger event_participants_updated_at before update on public.event_participants for each row execute function public.set_event_participant_updated_at();

create or replace function public.normalize_contact_email(p_email text) returns text language plpgsql immutable set search_path=public,pg_temp as $$
declare v_email text := lower(btrim(coalesce(p_email, ''))); begin
  if v_email = '' or position('@' in v_email) < 2 or position('.' in split_part(v_email, '@', 2)) = 0 then raise exception 'invalid email'; end if;
  return v_email;
end $$;

create or replace function public.hash_event_invite_token(p_token text) returns text language sql immutable set search_path=public,extensions,pg_temp as $$
  select encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
$$;

create or replace function public.require_event_manage_scope(p_event_id uuid) returns table(owner_account_id uuid) language plpgsql security definer set search_path=public,pg_temp as $$
declare v_area_id uuid; begin
  select e.area_id, a.owner_account_id into v_area_id, owner_account_id from public.events e join public.areas a on a.id=e.area_id where e.id=p_event_id;
  if v_area_id is null or not public.can_manage_area(v_area_id) then raise exception 'permission denied'; end if;
  return next;
end $$;

create or replace function public.assert_event_participant_contact_scope() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_owner uuid; begin
  select a.owner_account_id into v_owner from public.events e join public.areas a on a.id=e.area_id where e.id=new.event_id;
  if v_owner is null or not exists (select 1 from public.contacts c where c.id=new.contact_id and c.owner_account_id=v_owner) then raise exception 'event participant contact is outside event owner address book'; end if;
  if new.profile_id is not null and not exists (select 1 from public.contact_profile_links l where l.contact_id=new.contact_id and l.profile_id=new.profile_id) then raise exception 'participant profile is not linked to contact'; end if;
  return new;
end $$;
create trigger event_participants_contact_scope before insert or update of event_id,contact_id,profile_id on public.event_participants for each row execute function public.assert_event_participant_contact_scope();

create or replace function public.clear_participant_profile_on_contact_link_delete() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$ begin
  update public.event_participants set profile_id=null,updated_at=now() where contact_id=old.contact_id and profile_id=old.profile_id;
  return old;
end $$;
create trigger contact_profile_links_clear_participant before delete on public.contact_profile_links for each row execute function public.clear_participant_profile_on_contact_link_delete();

create or replace function public.get_event_participants(p_event_id uuid) returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_scope record; begin select * into v_scope from public.require_event_manage_scope(p_event_id); return query
select jsonb_build_object('contact_id',c.id,'profile_id',ep.profile_id,'first_name',c.first_name,'last_name',c.last_name,'status',ep.status,'added_via',ep.added_via)
from public.event_participants ep join public.contacts c on c.id=ep.contact_id where ep.event_id=p_event_id and ep.status='active' order by lower(c.first_name),lower(coalesce(c.last_name,'')); end $$;

create or replace function public.get_my_contacts_for_event(p_event_id uuid) returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_scope record; begin select * into v_scope from public.require_event_manage_scope(p_event_id); return query
select jsonb_build_object('contact_id',c.id,'profile_id',l.profile_id,'first_name',c.first_name,'last_name',c.last_name,'is_active_participant',exists(select 1 from public.event_participants ep where ep.event_id=p_event_id and ep.contact_id=c.id and ep.status='active'))
from public.contacts c left join public.contact_profile_links l on l.contact_id=c.id where c.owner_account_id=v_scope.owner_account_id order by lower(c.first_name),lower(coalesce(c.last_name,'')); end $$;

create or replace function public.add_event_participant(p_event_id uuid,p_contact_id uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_scope record; v_profile uuid; begin select * into v_scope from public.require_event_manage_scope(p_event_id); select l.profile_id into v_profile from public.contact_profile_links l where l.contact_id=p_contact_id;
  insert into public.event_participants(event_id,contact_id,profile_id,status,added_via,added_by_account_id) values(p_event_id,p_contact_id,v_profile,'active','direct',public.require_current_account()) on conflict(event_id,contact_id) do update set status='active',profile_id=coalesce(event_participants.profile_id,excluded.profile_id),updated_at=now();
  return jsonb_build_object('event_id',p_event_id,'contact_id',p_contact_id,'profile_id',v_profile);
end $$;

create or replace function public.remove_event_participant(p_event_id uuid,p_contact_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$ begin
  perform 1 from public.require_event_manage_scope(p_event_id); update public.event_participants set status='removed',updated_at=now() where event_id=p_event_id and contact_id=p_contact_id and status='active'; if not found then raise exception 'active participant not found'; end if; end $$;

create or replace function public.create_event_invite(p_event_id uuid,p_recipient_email text,p_first_name text,p_last_name text default null) returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare v_scope record; v_email text; v_contact uuid; v_token text:=encode(extensions.gen_random_bytes(32),'hex'); begin
  select * into v_scope from public.require_event_manage_scope(p_event_id); v_email:=public.normalize_contact_email(p_recipient_email);
  update public.event_invites set status='expired' where event_id=p_event_id and recipient_email=v_email and status='pending' and expires_at<=now();
  select contact_id into v_contact from public.contact_email_identities where owner_account_id=v_scope.owner_account_id and normalized_email=v_email;
  if v_contact is null then if nullif(btrim(coalesce(p_first_name,'')),'') is null then raise exception 'first name is required'; end if; insert into public.contacts(owner_account_id,first_name,last_name) values(v_scope.owner_account_id,btrim(p_first_name),nullif(btrim(coalesce(p_last_name,'')),'')) returning id into v_contact; insert into public.contact_email_identities values(v_scope.owner_account_id,v_email,v_contact); end if;
  if exists(select 1 from public.event_participants where event_id=p_event_id and contact_id=v_contact and status='active') then raise exception 'contact already participates in this event'; end if;
  if exists(select 1 from public.event_invites where event_id=p_event_id and recipient_email=v_email and status='pending') then raise exception 'pending event invite already exists'; end if;
  insert into public.event_invites(event_id,owner_account_id,contact_id,recipient_email,token_hash,expires_at,invited_by_account_id) values(p_event_id,v_scope.owner_account_id,v_contact,v_email,public.hash_event_invite_token(v_token),now()+interval '14 days',public.require_current_account());
  return jsonb_build_object('token',v_token,'contact_id',v_contact);
end $$;

create or replace function public.accept_event_invite(p_token text) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_invite public.event_invites%rowtype; v_email text; v_profile uuid; begin
  select public.normalize_contact_email(u.email),p.id into v_email,v_profile from auth.users u join public.profiles p on p.account_id=public.require_current_account() where u.id=auth.uid() and u.email_confirmed_at is not null; if v_profile is null then raise exception 'verified personal profile required'; end if;
  select * into v_invite from public.event_invites where token_hash=public.hash_event_invite_token(p_token) for update; if not found or v_invite.status<>'pending' or v_invite.expires_at<=now() or v_invite.recipient_email<>v_email then raise exception 'event invite cannot be accepted'; end if;
  if exists(select 1 from public.contact_profile_links where contact_id=v_invite.contact_id and profile_id<>v_profile) or exists(select 1 from public.contact_profile_links where owner_account_id=v_invite.owner_account_id and profile_id=v_profile and contact_id<>v_invite.contact_id) then raise exception 'contact/profile link conflict'; end if;
  insert into public.contact_profile_links(contact_id,owner_account_id,profile_id,linked_via) values(v_invite.contact_id,v_invite.owner_account_id,v_profile,'event_invite') on conflict(contact_id) do nothing;
  insert into public.event_participants(event_id,contact_id,profile_id,status,accepted_at,added_via,added_by_account_id) values(v_invite.event_id,v_invite.contact_id,v_profile,'active',now(),'event_invite',v_invite.invited_by_account_id) on conflict(event_id,contact_id) do update set profile_id=excluded.profile_id,status='active',accepted_at=excluded.accepted_at,added_via='event_invite',updated_at=now();
  update public.event_invites set status='accepted',accepted_by_profile_id=v_profile,responded_at=now() where id=v_invite.id;
end $$;

create or replace function public.decline_event_invite(p_token text) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_invite public.event_invites%rowtype; v_email text; begin select public.normalize_contact_email(u.email) into v_email from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null; select * into v_invite from public.event_invites where token_hash=public.hash_event_invite_token(p_token) for update; if not found or v_invite.status<>'pending' or v_invite.expires_at<=now() or v_invite.recipient_email<>v_email then raise exception 'event invite cannot be declined'; end if; update public.event_invites set status='declined',responded_at=now() where id=v_invite.id; end $$;

alter table public.contact_email_identities enable row level security; alter table public.contact_profile_links enable row level security; alter table public.event_invites enable row level security;
revoke all on table public.contact_email_identities,public.contact_profile_links,public.event_invites from public,anon,authenticated;
revoke all on table public.event_participants from public,anon,authenticated;
revoke all on function public.set_event_participant_updated_at(),public.normalize_contact_email(text),public.hash_event_invite_token(text),public.require_event_manage_scope(uuid),public.assert_event_participant_contact_scope(),public.clear_participant_profile_on_contact_link_delete() from public,anon,authenticated;
revoke all on function public.get_event_participants(uuid),public.get_my_contacts_for_event(uuid),public.add_event_participant(uuid,uuid),public.remove_event_participant(uuid,uuid),public.create_event_invite(uuid,text,text,text),public.accept_event_invite(text),public.decline_event_invite(text) from public,anon;
grant execute on function public.get_event_participants(uuid),public.get_my_contacts_for_event(uuid),public.add_event_participant(uuid,uuid),public.remove_event_participant(uuid,uuid),public.create_event_invite(uuid,text,text,text),public.accept_event_invite(text),public.decline_event_invite(text) to authenticated;

alter function public.set_event_participant_updated_at() owner to postgres;
alter function public.normalize_contact_email(text) owner to postgres;
alter function public.hash_event_invite_token(text) owner to postgres;
alter function public.require_event_manage_scope(uuid) owner to postgres;
alter function public.assert_event_participant_contact_scope() owner to postgres;
alter function public.clear_participant_profile_on_contact_link_delete() owner to postgres;
alter function public.get_event_participants(uuid) owner to postgres;
alter function public.get_my_contacts_for_event(uuid) owner to postgres;
alter function public.add_event_participant(uuid,uuid) owner to postgres;
alter function public.remove_event_participant(uuid,uuid) owner to postgres;
alter function public.create_event_invite(uuid,text,text,text) owner to postgres;
alter function public.accept_event_invite(text) owner to postgres;
alter function public.decline_event_invite(text) owner to postgres;

commit;
