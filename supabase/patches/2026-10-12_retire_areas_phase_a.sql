-- FamilArea — Area retirement, phase A: archive and account ownership migration.
--
-- LOCAL PREPARATION ONLY. Do not run this file before a backup and explicit
-- authorization. It never deletes Area records or Storage objects.
--
-- Event attribution rule: a valid Organization Area owner is authoritative,
-- including when the historic creator is a different Persona. Other creator /
-- Area-owner conflicts are not guessed: they remain archived exceptions.

begin;

create table if not exists public.area_retirement_archive_rows (
  source_table text not null,
  source_id uuid not null,
  payload jsonb not null,
  archived_at timestamptz not null default now(),
  primary key (source_table, source_id)
);

create table if not exists public.area_retirement_migration_results (
  source_table text not null,
  source_id uuid not null,
  source_area_id uuid,
  target_account_id uuid,
  disposition text not null check (disposition in ('migrated', 'preserved', 'exception')),
  reason text not null,
  recorded_at timestamptz not null default now(),
  primary key (source_table, source_id)
);

-- Snapshot every Area-owned record before changing ownership. The five
-- area-images objects remain in Storage and must be exported/removed later via
-- the Storage API, never by direct SQL against storage.objects.
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'areas', a.id, to_jsonb(a) from public.areas a
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
-- area_memberships has a composite key (area_id, profile_id), not an id. Keep
-- every source column in the snapshot and derive a stable UUID only for the
-- generic archive table key consumed later by phases B/C.
select 'area_memberships',
       md5(m.area_id::text || ':' || m.profile_id::text)::uuid,
       to_jsonb(m) || jsonb_build_object('_archive_source_key', m.area_id::text || ':' || m.profile_id::text)
from public.area_memberships m
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'area_invites', i.id, to_jsonb(i) from public.area_invites i
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'events', e.id, to_jsonb(e) from public.events e where e.area_id is not null
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'event_participants', p.id, to_jsonb(p)
from public.event_participants p join public.events e on e.id = p.event_id
where e.area_id is not null
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'event_invites', i.id, to_jsonb(i)
from public.event_invites i join public.events e on e.id = i.event_id
where e.area_id is not null
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'activities', a.id, to_jsonb(a) from public.activities a where a.area_id is not null
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'lists', l.id, to_jsonb(l) from public.lists l where l.area_id is not null
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();
insert into public.area_retirement_archive_rows (source_table, source_id, payload)
select 'attachments', a.id, to_jsonb(a) from public.attachments a where a.area_id is not null
on conflict (source_table, source_id) do update set payload = excluded.payload, archived_at = now();

-- Identify and migrate Area Events with a demonstrable account owner. A valid
-- Organization owning the Area wins over a different historic creator; all
-- other valid-but-conflicting identities are retained as explicit exceptions.
with sources as (
  select e.id, e.area_id,
         creator.id as creator_account_id,
         area_owner.id as area_owner_account_id,
         area_owner.account_type::text as area_owner_type
  from public.events e
  join public.areas ar on ar.id = e.area_id
  left join public.accounts creator on creator.id = e.created_by_account_id
  left join public.accounts area_owner on area_owner.id = ar.owner_account_id
  where e.area_id is not null
), candidates as (
  select id, area_id,
         case
           when area_owner_type = 'organization' then area_owner_account_id
           when creator_account_id is null then area_owner_account_id
           when area_owner_account_id is null then creator_account_id
           when creator_account_id = area_owner_account_id then creator_account_id
           else null
         end as target_account_id,
         case
           when area_owner_type = 'organization' and creator_account_id is distinct from area_owner_account_id
             then 'valid Organization Area owner takes precedence over historic creator'
           when area_owner_type = 'organization'
             then 'valid Organization Area owner'
           when creator_account_id is null and area_owner_account_id is not null
             then 'areas.owner_account_id'
           when creator_account_id is not null and area_owner_account_id is null
             then 'created_by_account_id'
           when creator_account_id = area_owner_account_id
             then 'creator and Area owner agree'
           when creator_account_id is not null and area_owner_account_id is not null
             then 'conflicting non-Organization creator and Area owner; manual attribution required'
           else 'no valid creator or Area owner account'
         end as reason
  from sources
)
insert into public.area_retirement_migration_results (source_table, source_id, source_area_id, target_account_id, disposition, reason)
select 'events', id, area_id, target_account_id,
       case when target_account_id is null then 'exception' else 'migrated' end,
       reason
from candidates
on conflict (source_table, source_id) do update
set source_area_id = excluded.source_area_id, target_account_id = excluded.target_account_id,
    disposition = excluded.disposition, reason = excluded.reason, recorded_at = now();

update public.events e
set owner_account_id = r.target_account_id,
    area_id = null
from public.area_retirement_migration_results r
where r.source_table = 'events'
  and r.source_id = e.id
  and r.disposition = 'migrated'
  and e.area_id is not null;

-- Activities and lists use the same conservative attribution rule. Current
-- remote counts are zero, but this preserves the migration contract.
with candidates as (
  select a.id, a.area_id, coalesce(creator.id, area_owner.id) as target_account_id,
         case when creator.id is not null then 'created_by_account_id'
              when area_owner.id is not null then 'areas.owner_account_id' end as reason
  from public.activities a
  join public.areas ar on ar.id = a.area_id
  left join public.accounts creator on creator.id = a.created_by_account_id
  left join public.accounts area_owner on area_owner.id = ar.owner_account_id
  where a.area_id is not null
)
insert into public.area_retirement_migration_results (source_table, source_id, source_area_id, target_account_id, disposition, reason)
select 'activities', id, area_id, target_account_id,
       case when target_account_id is null then 'exception' else 'migrated' end,
       coalesce(reason, 'no valid creator or Area owner account')
from candidates
on conflict (source_table, source_id) do update
set source_area_id = excluded.source_area_id, target_account_id = excluded.target_account_id,
    disposition = excluded.disposition, reason = excluded.reason, recorded_at = now();

update public.activities a
set owner_account_id = r.target_account_id,
    area_id = null
from public.area_retirement_migration_results r
where r.source_table = 'activities' and r.source_id = a.id
  and r.disposition = 'migrated' and a.area_id is not null;

with candidates as (
  select l.id, l.area_id, coalesce(creator.id, area_owner.id) as target_account_id,
         case when creator.id is not null then 'created_by_account_id'
              when area_owner.id is not null then 'areas.owner_account_id' end as reason
  from public.lists l
  join public.areas ar on ar.id = l.area_id
  left join public.accounts creator on creator.id = l.created_by_account_id
  left join public.accounts area_owner on area_owner.id = ar.owner_account_id
  where l.area_id is not null
)
insert into public.area_retirement_migration_results (source_table, source_id, source_area_id, target_account_id, disposition, reason)
select 'lists', id, area_id, target_account_id,
       case when target_account_id is null then 'exception' else 'migrated' end,
       coalesce(reason, 'no valid creator or Area owner account')
from candidates
on conflict (source_table, source_id) do update
set source_area_id = excluded.source_area_id, target_account_id = excluded.target_account_id,
    disposition = excluded.disposition, reason = excluded.reason, recorded_at = now();

update public.lists l
set owner_account_id = r.target_account_id,
    area_id = null
from public.area_retirement_migration_results r
where r.source_table = 'lists' and r.source_id = l.id
  and r.disposition = 'migrated' and l.area_id is not null;

-- Event attachments follow the resolved owner of their migrated Event, not a
-- potentially different uploader. target_id, storage_path and Storage objects
-- are never changed. Other attachment targets retain the uploader rule.
with candidates as (
  select a.id, a.area_id,
         case
           when a.target_type = 'event' and event_result.disposition = 'migrated'
             then event_result.target_account_id
           when a.target_type = 'event' then null
           else uploader.id
         end as target_account_id,
         case
           when a.target_type = 'event' and event_result.disposition = 'migrated'
             then 'resolved migrated Event owner'
           when a.target_type = 'event' and event_result.source_id is not null
             then 'Event owner is unresolved; attachment retained in Area scope'
           when a.target_type = 'event'
             then 'event attachment does not reference an archived Area Event'
           when uploader.id is not null then 'uploaded_by_account_id'
           else 'no valid uploader account'
         end as reason
  from public.attachments a
  left join public.accounts uploader on uploader.id = a.uploaded_by_account_id
  left join public.area_retirement_migration_results event_result
    on event_result.source_table = 'events'
   and event_result.source_id = a.target_id
  where a.area_id is not null
)
insert into public.area_retirement_migration_results (source_table, source_id, source_area_id, target_account_id, disposition, reason)
select 'attachments', id, area_id, target_account_id,
       case when target_account_id is null then 'exception' else 'migrated' end,
       reason
from candidates
on conflict (source_table, source_id) do update
set source_area_id = excluded.source_area_id, target_account_id = excluded.target_account_id,
    disposition = excluded.disposition, reason = excluded.reason, recorded_at = now();

update public.attachments a
set owner_account_id = r.target_account_id,
    area_id = null
from public.area_retirement_migration_results r
where r.source_table = 'attachments' and r.source_id = a.id
  and r.disposition = 'migrated' and a.area_id is not null;

-- Event participation/invitation rows remain attached to their migrated Event.
-- They are preserved only when their existing identity is valid; no Contact or
-- account is invented for historic Area membership.
insert into public.area_retirement_migration_results (source_table, source_id, source_area_id, disposition, reason)
select 'event_participants', p.id, r.source_area_id,
       case when p.status = 'active' and p.profile_id is null and p.contact_id is null then 'exception' else 'preserved' end,
       case when p.status = 'active' and p.profile_id is null and p.contact_id is null
            then 'active participant has no account, profile or contact identity'
            else 'participant history retained on migrated event' end
from public.event_participants p
join public.area_retirement_migration_results r on r.source_table = 'events' and r.source_id = p.event_id
on conflict (source_table, source_id) do update
set source_area_id = excluded.source_area_id, disposition = excluded.disposition,
    reason = excluded.reason, recorded_at = now();

-- Invite ownership is historical data: a mismatch is documented, never
-- overwritten. The invite itself stays attached to the same Event.
insert into public.area_retirement_migration_results (source_table, source_id, source_area_id, disposition, reason)
select 'event_invites', i.id, r.source_area_id,
       case
         when r.disposition = 'migrated' and i.owner_account_id is distinct from r.target_account_id then 'exception'
         else 'preserved'
       end,
       case
         when r.disposition = 'migrated' and i.owner_account_id is distinct from r.target_account_id
           then 'invite owner_account_id differs from migrated Event owner; retained without overwrite'
         when r.disposition = 'exception'
           then 'event remains an attribution exception; invite history retained'
         else 'event invite history retained on migrated event'
       end
from public.event_invites i
join public.area_retirement_migration_results r on r.source_table = 'events' and r.source_id = i.event_id
on conflict (source_table, source_id) do update
set source_area_id = excluded.source_area_id, disposition = excluded.disposition,
    reason = excluded.reason, recorded_at = now();

insert into public.area_retirement_migration_results (source_table, source_id, source_area_id, disposition, reason)
select 'area_invites', i.id, i.area_id, 'preserved', 'historic Area invite: no account-owned equivalent is inferred'
from public.area_invites i
on conflict (source_table, source_id) do update
set source_area_id = excluded.source_area_id, disposition = excluded.disposition,
    reason = excluded.reason, recorded_at = now();

-- Any assertion failure aborts this transaction, including its archive writes.
-- Attribution exceptions above are intentionally reported rather than guessed.
do $$
begin
  if exists (
    select 1
    from public.events e
    join public.area_retirement_migration_results r
      on r.source_table = 'events' and r.source_id = e.id
    where r.disposition = 'migrated'
      and (e.area_id is not null or e.owner_account_id is distinct from r.target_account_id)
  ) then
    raise exception 'Area retirement verification failed: migrated Event ownership is inconsistent';
  end if;

  if exists (
    select 1
    from public.attachments a
    join public.area_retirement_migration_results event_result
      on event_result.source_table = 'events' and event_result.source_id = a.target_id
    where a.target_type = 'event'
      and event_result.disposition = 'migrated'
      and (a.area_id is not null or a.owner_account_id is distinct from event_result.target_account_id)
  ) then
    raise exception 'Area retirement verification failed: migrated Event attachment ownership is inconsistent';
  end if;

  if exists (
    select 1
    from public.attachments a
    join public.area_retirement_archive_rows archived
      on archived.source_table = 'attachments' and archived.source_id = a.id
    where a.target_type = 'event'
      and (a.target_id::text is distinct from archived.payload ->> 'target_id'
        or a.storage_path is distinct from archived.payload ->> 'storage_path')
  ) then
    raise exception 'Area retirement verification failed: an Event attachment target or storage path changed';
  end if;

  if exists (
    select 1
    from public.event_invites i
    join public.area_retirement_migration_results event_result
      on event_result.source_table = 'events' and event_result.source_id = i.event_id
    where event_result.disposition = 'migrated'
      and i.owner_account_id is distinct from event_result.target_account_id
      and not exists (
        select 1
        from public.area_retirement_migration_results invite_result
        where invite_result.source_table = 'event_invites'
          and invite_result.source_id = i.id
          and invite_result.disposition = 'exception'
      )
  ) then
    raise exception 'Area retirement verification failed: mismatched Event invite ownership was not recorded';
  end if;
end $$;

-- Required post-transaction report. It is intentionally returned before phase B.
select source_table, disposition, reason, count(*) as records
from public.area_retirement_migration_results
group by source_table, disposition, reason
order by source_table, disposition, reason;

commit;
