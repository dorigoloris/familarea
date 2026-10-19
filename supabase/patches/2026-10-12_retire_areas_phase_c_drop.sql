-- FamilArea — Area retirement, phase C: physical removal.
--
-- Run only after phase A, the reviewed account-owned RPC replacements and the
-- phase B gate. This is intentionally restrictive: it refuses to drop schema
-- objects while a non-Area RPC still mentions Area tables, area_id or the Area
-- authorization helpers. Never add CASCADE to this script.

begin;

do $$
declare
  v_remaining bigint;
  v_unarchived_exceptions bigint;
  v_dependencies text;
begin
  select count(*) into v_remaining
  from public.events where area_id is not null;
  v_remaining := v_remaining + (select count(*) from public.activities where area_id is not null);
  v_remaining := v_remaining + (select count(*) from public.lists where area_id is not null);
  v_remaining := v_remaining + (select count(*) from public.attachments where area_id is not null);

  if v_remaining <> 0 then
    raise exception 'Area retirement phase C blocked: % Area-owned rows remain', v_remaining;
  end if;

  select count(*) into v_unarchived_exceptions
  from public.area_retirement_migration_results r
  where r.disposition = 'exception'
    and not exists (
      select 1 from public.area_retirement_archive_rows a
      where a.source_table = r.source_table and a.source_id = r.source_id
    );
  if v_unarchived_exceptions <> 0 then
    raise exception 'Area retirement phase C blocked: % exceptions are not archived', v_unarchived_exceptions;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
  into v_dependencies
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and p.proname not in (
      'accept_area_invite', 'accept_my_area_invite', 'add_area_member',
      'area_scope', 'can_manage_area', 'can_manage_area_image_storage_path',
      'can_read_area_image_storage_path', 'create_area', 'create_area_invite',
      'decline_area_invite', 'decline_my_area_invite', 'delete_area', 'get_area',
      'get_area_invites', 'get_area_members', 'get_area_program',
      'get_my_area_invites', 'get_my_areas', 'is_area_member', 'is_area_owner',
      'remove_area_member', 'require_area_manage', 'require_area_read',
      'revoke_area_invite', 'update_area', 'update_area_image'
    )
    and (
      p.prosrc ilike '%public.areas%'
      or p.prosrc ilike '%public.area_memberships%'
      or p.prosrc ilike '%public.area_invites%'
      or p.prosrc ilike '%area_id%'
      or p.prosrc ilike '%is_area_%'
      or p.prosrc ilike '%can_manage_area%'
    );

  if v_dependencies is not null then
    raise exception 'Area retirement phase C blocked: replace remaining account RPCs first: %', v_dependencies;
  end if;
end;
$$;

-- Area-only RPCs: signatures are verified against the remote schema. These
-- drops are restrictive; if an unexpected dependency remains PostgreSQL aborts
-- the transaction instead of deleting it implicitly.
drop function if exists public.accept_area_invite(text);
drop function if exists public.accept_my_area_invite(uuid);
drop function if exists public.add_area_member(uuid, uuid, public.area_role);
drop function if exists public.area_scope(uuid);
drop function if exists public.can_manage_area(uuid);
drop function if exists public.can_manage_area_image_storage_path(text);
drop function if exists public.can_read_area_image_storage_path(text);
drop function if exists public.create_area(text, text, text);
drop function if exists public.create_area_invite(uuid, text, timestamptz);
drop function if exists public.decline_area_invite(text);
drop function if exists public.decline_my_area_invite(uuid);
drop function if exists public.delete_area(uuid);
drop function if exists public.get_area(uuid);
drop function if exists public.get_area_invites(uuid);
drop function if exists public.get_area_members(uuid);
drop function if exists public.get_area_program(uuid);
drop function if exists public.get_my_area_invites();
drop function if exists public.get_my_areas();
drop function if exists public.is_area_member(uuid);
drop function if exists public.is_area_owner(uuid);
drop function if exists public.remove_area_member(uuid, uuid);
drop function if exists public.require_area_manage(uuid);
drop function if exists public.require_area_read(uuid);
drop function if exists public.revoke_area_invite(uuid);
drop function if exists public.update_area(uuid, text, text, text);
drop function if exists public.update_area_image(uuid, text);

-- Drop foreign keys explicitly before the tables. No account-owned row is
-- deleted: phase A has already migrated compatible records and archived the
-- original Area records.
alter table public.activities drop constraint if exists activities_area_id_fkey;
alter table public.attachments drop constraint if exists attachments_area_id_fkey;
alter table public.events drop constraint if exists events_area_id_fkey;
alter table public.lists drop constraint if exists lists_area_id_fkey;
alter table public.area_invites drop constraint if exists area_invites_area_id_fkey;
alter table public.area_memberships drop constraint if exists area_memberships_area_id_fkey;

alter table public.activities drop column if exists area_id;
alter table public.attachments drop column if exists area_id;
alter table public.events drop column if exists area_id;
alter table public.lists drop column if exists area_id;

drop table public.area_invites;
drop table public.area_memberships;
drop table public.areas;
drop type if exists public.area_role;

-- Keep both archive tables. Storage objects under area-images are handled by
-- the Storage API only after the exported archive has been verified.
commit;
