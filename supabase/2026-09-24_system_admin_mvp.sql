-- FamilArea — System Administration MVP (read-only).
-- Apply only after a remote catalog check confirms the account model:
-- accounts → profile OR organization, with contacts private by account.

begin;

create table public.system_admins (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by_account_id uuid references public.accounts(id) on delete set null
);

alter table public.system_admins enable row level security;
alter table public.system_admins no force row level security;
revoke all on table public.system_admins from public, anon, authenticated;

create or replace function public.require_system_admin()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_account_id uuid := public.require_current_account();
begin
  if not exists (
    select 1 from public.system_admins sa where sa.account_id = v_account_id
  ) then
    raise exception 'permission denied';
  end if;
  return v_account_id;
end;
$$;

-- Questa RPC non espone dati amministrativi: serve esclusivamente a mostrare
-- il link di navigazione. Tutte le RPC che restituiscono dati usano invece
-- require_system_admin() e restano protette anche conoscendo admin.html.
create or replace function public.get_my_system_admin_access()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'is_system_admin', exists (
      select 1
      from public.system_admins sa
      where sa.account_id = public.current_account_id()
    )
  );
$$;

create or replace function public.admin_get_dashboard()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  perform public.require_system_admin();
  return jsonb_build_object(
    'accounts', (select count(*) from public.accounts),
    'profiles', (select count(*) from public.profiles),
    'organizations', (select count(*) from public.organizations),
    'areas', (select count(*) from public.areas),
    'activities', (select count(*) from public.activities),
    'events', (select count(*) from public.events),
    'contacts', (select count(*) from public.contacts),
    'area_memberships', (select count(*) from public.area_memberships),
    'event_participants', (select count(*) from public.event_participants),
    'area_invites', (select count(*) from public.area_invites)
  );
end;
$$;

create or replace function public.admin_list_accounts(
  p_limit integer default 50,
  p_offset integer default 0,
  p_query text default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_query text := nullif(lower(btrim(coalesce(p_query, ''))), '');
begin
  perform public.require_system_admin();
  return (
    with account_rows as (
      select
        a.id as account_id,
        a.account_type::text as account_type,
        a.created_at,
        u.email,
        p.id as profile_id,
        p.first_name as profile_first_name,
        p.last_name as profile_last_name,
        o.id as organization_id,
        o.name as organization_name,
        o.organization_type,
        (select count(*) from public.areas ar where ar.owner_account_id = a.id) as owned_areas_count,
        (select count(*) from public.contacts c where c.owner_account_id = a.id) as contacts_count,
        (select count(*) from public.activities ac where ac.owner_account_id = a.id or exists (select 1 from public.areas ar where ar.id = ac.area_id and ar.owner_account_id = a.id)) as activities_count,
        (select count(*) from public.events ev where ev.owner_account_id = a.id or exists (select 1 from public.areas ar where ar.id = ev.area_id and ar.owner_account_id = a.id)) as events_count,
        (select count(*) from public.area_invites ai where ai.invited_by_account_id = a.id) as sent_area_invites_count,
        (select count(*) from public.attachments at where at.owner_account_id = a.id or exists (select 1 from public.areas ar where ar.id = at.area_id and ar.owner_account_id = a.id)) as attachments_count,
        (select count(*) from public.area_memberships am where am.profile_id = p.id) as area_memberships_count,
        (select count(*) from public.event_participants ep where ep.profile_id = p.id) as event_participations_count
      from public.accounts a
      left join auth.users u on u.id = a.auth_user_id
      left join public.profiles p on p.account_id = a.id
      left join public.organizations o on o.account_id = a.id
      where v_query is null
         or lower(coalesce(u.email, '')) like '%' || v_query || '%'
         or lower(concat_ws(' ', p.first_name, p.last_name)) like '%' || v_query || '%'
         or lower(coalesce(o.name, '')) like '%' || v_query || '%'
    ),
    paged_rows as (
      select *
      from account_rows
      order by created_at desc, account_id
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'total', (select count(*) from account_rows),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'account_id', account_id,
          'account_type', account_type,
          'name', coalesce(nullif(concat_ws(' ', profile_first_name, profile_last_name), ''), organization_name, 'Account'),
          'email', email,
          'organization_name', organization_name,
          'organization_type', organization_type,
          'created_at', created_at,
          'counts', jsonb_build_object(
            'owned_areas', owned_areas_count,
            'area_memberships', area_memberships_count,
            'activities', activities_count,
            'events', events_count,
            'event_participations', event_participations_count,
            'contacts', contacts_count,
            'area_invites_sent', sent_area_invites_count,
            'attachments', attachments_count
          )
        ) order by created_at desc, account_id)
        from paged_rows
      ), '[]'::jsonb)
    )
  );
end;
$$;

create or replace function public.admin_get_account_summary(p_account_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.require_system_admin();
  select jsonb_build_object(
    'account', jsonb_build_object(
      'id', a.id,
      'account_type', a.account_type,
      'email', u.email,
      'email_confirmed', u.email_confirmed_at is not null,
      'created_at', a.created_at
    ),
    'profile', case when p.id is null then null else jsonb_build_object(
      'id', p.id,
      'first_name', p.first_name,
      'last_name', p.last_name,
      'created_at', p.created_at
    ) end,
    'organization', case when o.id is null then null else jsonb_build_object(
      'id', o.id,
      'name', o.name,
      'organization_type', o.organization_type,
      'status', o.status,
      'created_at', o.created_at
    ) end,
    'counts', jsonb_build_object(
      'owned_areas', (select count(*) from public.areas ar where ar.owner_account_id = a.id),
      'area_memberships', (select count(*) from public.area_memberships am where am.profile_id = p.id),
      'activities', (select count(*) from public.activities ac where ac.owner_account_id = a.id or exists (select 1 from public.areas ar where ar.id = ac.area_id and ar.owner_account_id = a.id)),
      'events', (select count(*) from public.events ev where ev.owner_account_id = a.id or exists (select 1 from public.areas ar where ar.id = ev.area_id and ar.owner_account_id = a.id)),
      'event_participations', (select count(*) from public.event_participants ep where ep.profile_id = p.id),
      'contacts', (select count(*) from public.contacts c where c.owner_account_id = a.id),
      'area_invites_sent', (select count(*) from public.area_invites ai where ai.invited_by_account_id = a.id),
      'area_invites_accepted', (select count(*) from public.area_invites ai where ai.accepted_by_profile_id = p.id),
      'attachments', (select count(*) from public.attachments at where at.owner_account_id = a.id or exists (select 1 from public.areas ar where ar.id = at.area_id and ar.owner_account_id = a.id)),
      'families', (select count(*) from public.families f where f.owner_account_id = a.id),
      'deadlines', (select count(*) from public.deadlines d where d.owner_account_id = a.id),
      'lists', (select count(*) from public.lists l where l.owner_account_id = a.id)
    )
  ) into v_result
  from public.accounts a
  left join auth.users u on u.id = a.auth_user_id
  left join public.profiles p on p.account_id = a.id
  left join public.organizations o on o.account_id = a.id
  where a.id = p_account_id;

  if v_result is null then raise exception 'account not found'; end if;
  return v_result;
end;
$$;

create or replace function public.admin_get_account_dependencies(p_account_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_result jsonb;
begin
  perform public.require_system_admin();
  select p.id into v_profile_id from public.profiles p where p.account_id = p_account_id;
  if not exists (select 1 from public.accounts a where a.id = p_account_id) then
    raise exception 'account not found';
  end if;

  select jsonb_build_object(
    'owned_areas', coalesce((
      select jsonb_agg(jsonb_build_object('id', ar.id, 'name', ar.name, 'area_type', ar.area_type, 'created_at', ar.created_at) order by ar.name, ar.id)
      from public.areas ar where ar.owner_account_id = p_account_id
    ), '[]'::jsonb),
    'area_memberships', coalesce((
      select jsonb_agg(jsonb_build_object('area_id', am.area_id, 'area_name', ar.name, 'role', am.role, 'created_at', am.created_at) order by ar.name, am.area_id)
      from public.area_memberships am join public.areas ar on ar.id = am.area_id
      where am.profile_id = v_profile_id
    ), '[]'::jsonb),
    'activities', coalesce((
      select jsonb_agg(jsonb_build_object('id', ac.id, 'title', ac.title, 'status', ac.status, 'area_id', ac.area_id, 'created_at', ac.created_at) order by ac.created_at desc, ac.id)
      from public.activities ac
      where ac.owner_account_id = p_account_id
         or exists (select 1 from public.areas ar where ar.id = ac.area_id and ar.owner_account_id = p_account_id)
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('id', ev.id, 'title', ev.title, 'status', ev.status, 'area_id', ev.area_id, 'created_at', ev.created_at) order by ev.created_at desc, ev.id)
      from public.events ev
      where ev.owner_account_id = p_account_id
         or exists (select 1 from public.areas ar where ar.id = ev.area_id and ar.owner_account_id = p_account_id)
    ), '[]'::jsonb),
    'event_participations', coalesce((
      select jsonb_agg(jsonb_build_object('event_id', ep.event_id, 'event_title', ev.title, 'status', ep.status) order by ev.created_at desc, ep.event_id)
      from public.event_participants ep join public.events ev on ev.id = ep.event_id
      where ep.profile_id = v_profile_id
    ), '[]'::jsonb),
    'area_invites', jsonb_build_object(
      'sent', coalesce((
        select jsonb_agg(jsonb_build_object('id', ai.id, 'area_id', ai.area_id, 'status', ai.status, 'created_at', ai.created_at, 'responded_at', ai.responded_at) order by ai.created_at desc, ai.id)
        from public.area_invites ai where ai.invited_by_account_id = p_account_id
      ), '[]'::jsonb),
      'accepted', coalesce((
        select jsonb_agg(jsonb_build_object('id', ai.id, 'area_id', ai.area_id, 'status', ai.status, 'created_at', ai.created_at, 'responded_at', ai.responded_at) order by ai.created_at desc, ai.id)
        from public.area_invites ai where ai.accepted_by_profile_id = v_profile_id
      ), '[]'::jsonb)
    ),
    'contacts', jsonb_build_object(
      'count', (select count(*) from public.contacts c where c.owner_account_id = p_account_id),
      'contact_methods_count', (
        select count(*) from public.contact_methods cm
        join public.contacts c on c.id = cm.contact_id
        where c.owner_account_id = p_account_id
      )
    ),
    'other_dependencies', jsonb_build_object(
      'lists', (select count(*) from public.lists l where l.owner_account_id = p_account_id or exists (select 1 from public.areas ar where ar.id = l.area_id and ar.owner_account_id = p_account_id)),
      'list_items', (
        select count(*) from public.list_items li
        join public.lists l on l.id = li.list_id
        where l.owner_account_id = p_account_id
           or exists (select 1 from public.areas ar where ar.id = l.area_id and ar.owner_account_id = p_account_id)
      ),
      'families', (select count(*) from public.families f where f.owner_account_id = p_account_id),
      'family_members', (
        select count(*) from public.family_members fm
        join public.families f on f.id = fm.family_id
        where f.owner_account_id = p_account_id
      ),
      'family_access', (select count(*) from public.family_access fa where fa.profile_id = v_profile_id),
      'deadlines', (select count(*) from public.deadlines d where d.owner_account_id = p_account_id),
      'attachments_owned', (select count(*) from public.attachments at where at.owner_account_id = p_account_id or exists (select 1 from public.areas ar where ar.id = at.area_id and ar.owner_account_id = p_account_id)),
      'areas_created', (select count(*) from public.areas ar where ar.created_by_account_id = p_account_id),
      'activities_created', (select count(*) from public.activities ac where ac.created_by_account_id = p_account_id),
      'events_created', (select count(*) from public.events ev where ev.created_by_account_id = p_account_id)
    )
  ) into v_result;
  return v_result;
end;
$$;

alter function public.require_system_admin() owner to postgres;
alter function public.get_my_system_admin_access() owner to postgres;
alter function public.admin_get_dashboard() owner to postgres;
alter function public.admin_list_accounts(integer, integer, text) owner to postgres;
alter function public.admin_get_account_summary(uuid) owner to postgres;
alter function public.admin_get_account_dependencies(uuid) owner to postgres;

revoke all on function public.require_system_admin() from public, anon, authenticated;
revoke all on function public.get_my_system_admin_access() from public, anon;
revoke all on function public.admin_get_dashboard(), public.admin_list_accounts(integer, integer, text),
  public.admin_get_account_summary(uuid), public.admin_get_account_dependencies(uuid)
  from public, anon;

grant execute on function public.get_my_system_admin_access() to authenticated;
grant execute on function public.admin_get_dashboard(), public.admin_list_accounts(integer, integer, text),
  public.admin_get_account_summary(uuid), public.admin_get_account_dependencies(uuid)
  to authenticated;

commit;
