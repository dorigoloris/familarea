-- FamilArea — Family Calendar V3: include the complete Family in the controls UI.
-- Informational FamilyMember rows never receive calendar permissions or preferences.

begin;

drop function public.get_my_family_calendar_controls();

create function public.get_my_family_calendar_controls()
returns table(
  family_id uuid,
  family_name text,
  member_account_id uuid,
  display_name text,
  avatar_path text,
  relationship text,
  is_self boolean,
  can_view_source boolean,
  view_enabled boolean,
  share_enabled boolean,
  calendar_capable boolean,
  member_type text
)
language sql stable security definer set search_path=public,pg_temp as $$
  with caller as (select public.require_personal_account() as account_id),
  accessible_families as (
    select f.id, f.name
    from public.families f cross join caller c
    where public.is_confirmed_family_account_member(f.id, c.account_id)
  ), confirmed_accounts as (
    select af.id as family_id, af.name as family_name, f.owner_account_id as account_id
    from accessible_families af join public.families f on f.id = af.id
    union
    select af.id, af.name, p.account_id
    from accessible_families af
    join public.family_access fa on fa.family_id = af.id
    join public.profiles p on p.id = fa.profile_id
    join public.accounts a on a.id = p.account_id and a.account_type = 'personal'
  ), account_rows as (
    select ca.family_id, ca.family_name, ca.account_id, p.id as profile_id,
      nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '') as display_name,
      p.avatar_path, fm.relationship, (ca.account_id = c.account_id) as is_self,
      true as calendar_capable, 'person'::text as member_type,
      case when ca.account_id = c.account_id then 0 else 1 end as sort_group,
      coalesce(fm.first_name, p.first_name, '') as sort_first,
      coalesce(fm.last_name, p.last_name, '') as sort_last,
      fm.id as sort_member_id
    from confirmed_accounts ca
    cross join caller c
    join public.profiles p on p.account_id = ca.account_id
    left join lateral (
      select fm.* from public.family_members fm
      where fm.family_id = ca.family_id and fm.linked_profile_id = p.id
      limit 1
    ) fm on true
  ), informational_rows as (
    select af.id as family_id, af.name as family_name, null::uuid as account_id, null::uuid as profile_id,
      nullif(btrim(concat_ws(' ', fm.first_name, fm.last_name)), '') as display_name,
      null::text as avatar_path, fm.relationship, false as is_self,
      false as calendar_capable, fm.member_type::text as member_type,
      1 as sort_group, coalesce(fm.first_name, '') as sort_first, coalesce(fm.last_name, '') as sort_last, fm.id as sort_member_id
    from accessible_families af
    join public.family_members fm on fm.family_id = af.id
    where not exists (
      select 1 from public.family_access fa
      where fa.family_id = fm.family_id and fa.profile_id = fm.linked_profile_id
    )
  ), rows as (
    select * from account_rows union all select * from informational_rows
  )
  select r.family_id, r.family_name, r.account_id, r.display_name, r.avatar_path, r.relationship,
    r.is_self,
    case when r.calendar_capable and r.is_self then true
         when r.calendar_capable then public.has_family_calendar_share_permission(r.account_id, c.account_id, r.family_id)
         else false end,
    case when r.calendar_capable and r.is_self then coalesce((
      select vp.visible from public.calendar_view_preferences vp
      where vp.viewer_account_id = c.account_id and vp.source_account_id = c.account_id and vp.family_id is null
    ), true) when r.calendar_capable and public.has_family_calendar_share_permission(r.account_id, c.account_id, r.family_id) then coalesce((
      select vp.visible from public.calendar_view_preferences vp
      where vp.viewer_account_id = c.account_id and vp.source_account_id = r.account_id and vp.family_id = r.family_id
    ), true) else false end,
    case when r.calendar_capable and not r.is_self then public.has_family_calendar_share_permission(c.account_id, r.account_id, r.family_id) else false end,
    r.calendar_capable, r.member_type
  from rows r cross join caller c
  order by r.family_name, r.sort_group, lower(r.sort_first), lower(r.sort_last), r.sort_member_id nulls first, r.account_id nulls last
$$;

alter function public.get_my_family_calendar_controls() owner to postgres;
revoke all on function public.get_my_family_calendar_controls() from public, anon;
grant execute on function public.get_my_family_calendar_controls() to authenticated;

commit;
