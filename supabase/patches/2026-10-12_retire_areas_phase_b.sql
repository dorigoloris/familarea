-- FamilArea — Area retirement, phase B: destructive readiness gate.
--
-- LOCAL PREPARATION ONLY. This file is deliberately a gate, not an automatic
-- destructive migration: every RPC referencing areas/area_id must first be
-- replaced from its current remote definition with its account-owned variant.
-- Do not use DROP ... CASCADE: it can silently remove shared RPCs.

begin;

do $$
declare
  v_remaining bigint;
  v_unarchived_exceptions bigint;
begin
  select count(*) into v_remaining from public.events where area_id is not null;
  v_remaining := v_remaining + (select count(*) from public.activities where area_id is not null);
  v_remaining := v_remaining + (select count(*) from public.lists where area_id is not null);
  v_remaining := v_remaining + (select count(*) from public.attachments where area_id is not null);
  select count(*) into v_unarchived_exceptions
  from public.area_retirement_migration_results r
  where r.disposition = 'exception'
    and not exists (
      select 1
      from public.area_retirement_archive_rows a
      where a.source_table = r.source_table
        and a.source_id = r.source_id
    );

  if v_remaining <> 0 then
    raise exception 'Area retirement phase B blocked: % Area-owned rows remain', v_remaining;
  end if;
  if v_unarchived_exceptions <> 0 then
    raise exception 'Area retirement phase B blocked: % exceptions are not archived', v_unarchived_exceptions;
  end if;
end;
$$;

-- Before enabling the statements below, prepare and review replacements for
-- every current SECURITY DEFINER RPC/helper that mentions areas or area_id,
-- including calendar feeds, Event/Activity/List CRUD, invite counting and
-- visibility helpers. Verify owners, grants, search_path and dependencies with
-- pg_get_functiondef on the remote project. The local frontend changes are not
-- a substitute for those server-side replacements.
--
-- Once those reviewed replacements have been applied in this same transaction:
--   1. revoke execute from Area-only RPCs;
--   2. remove Area-only triggers/policies;
--   3. drop FK constraints to areas (never CASCADE);
--   4. drop area_id columns and their exactly-one-owner check constraints;
--   5. export/delete the five area-images files through the Storage API;
--   6. drop area_invites, area_memberships and areas;
--   7. retain area_retirement_archive_rows/results as the historical archive.
--
-- This transaction intentionally rolls back after proving its preconditions.
rollback;
