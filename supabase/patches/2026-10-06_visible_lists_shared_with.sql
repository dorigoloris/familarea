-- FamilArea — compact, viewer-relative people payload for visible shared lists.
-- Only accepted participants are considered; pending invites are intentionally excluded.

begin;

create or replace function public.get_visible_lists()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp
as $$
  select to_jsonb(l) || jsonb_build_object(
    'can_edit_items', public.can_edit_list_items(l.id),
    'can_manage_list', public.can_manage_list(l.id),
    'is_shared', case
      when l.area_id is null then exists (
        select 1
        from public.list_participants lp
        where lp.list_id = l.id
      )
      else false
    end,
    'shared_with', case
      when l.area_id is null then coalesce((
        select jsonb_agg(jsonb_build_object(
          'account_id', person.account_id,
          'display_name', person.display_name,
          'avatar_path', person.avatar_path
        ) order by person.sort_order, person.accepted_at nulls first, person.account_id)
        from (
          select
            owner.account_id,
            btrim(concat_ws(' ', owner_profile.first_name, owner_profile.last_name)) as display_name,
            owner_profile.avatar_path,
            0 as sort_order,
            null::timestamptz as accepted_at
          from (select l.owner_account_id as account_id) owner
          left join public.profiles owner_profile on owner_profile.account_id = owner.account_id

          union all

          select
            lp.account_id,
            btrim(concat_ws(' ', participant_profile.first_name, participant_profile.last_name)) as display_name,
            participant_profile.avatar_path,
            1 as sort_order,
            lp.accepted_at
          from public.list_participants lp
          left join public.profiles participant_profile on participant_profile.account_id = lp.account_id
          where lp.list_id = l.id
        ) person
        where person.account_id is not null
          and person.account_id <> public.current_account_id()
      ), '[]'::jsonb)
      else '[]'::jsonb
    end
  )
  from public.lists l
  where public.can_read_list(l.id)
  order by l.updated_at desc
$$;

commit;
