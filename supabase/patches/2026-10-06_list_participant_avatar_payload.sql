-- FamilArea — presentation data for the shared-list header.
-- Authorization and collaboration capabilities remain unchanged.

begin;

create or replace function public.get_list(p_list_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if not public.can_read_list(p_list_id) then raise exception 'permission denied'; end if;
  return (
    select jsonb_build_object(
      'list', to_jsonb(l),
      'viewer_account_id', public.current_account_id(),
      'owner', case when l.owner_account_id is null then null else jsonb_build_object(
        'account_id', l.owner_account_id,
        'profile_id', owner_profile.id,
        'first_name', owner_profile.first_name,
        'last_name', owner_profile.last_name,
        'display_name', btrim(concat_ws(' ', owner_profile.first_name, owner_profile.last_name)),
        'avatar_path', owner_profile.avatar_path
      ) end,
      'participants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'account_id', lp.account_id,
          'invited_by_account_id', lp.invited_by_account_id,
          'accepted_at', lp.accepted_at,
          'profile_id', participant_profile.id,
          'first_name', participant_profile.first_name,
          'last_name', participant_profile.last_name,
          'display_name', btrim(concat_ws(' ', participant_profile.first_name, participant_profile.last_name)),
          'avatar_path', participant_profile.avatar_path
        ) order by lp.accepted_at, lp.account_id)
        from public.list_participants lp
        left join public.profiles participant_profile on participant_profile.account_id = lp.account_id
        where lp.list_id = l.id
      ), '[]'::jsonb),
      'items', coalesce((
        select jsonb_agg(to_jsonb(i) order by i.position, i.created_at, i.id)
        from public.list_items i
        where i.list_id = l.id
      ), '[]'::jsonb),
      'can_edit_items', public.can_edit_list_items(l.id),
      'can_manage_list', public.can_manage_list(l.id)
    )
    from public.lists l
    left join public.profiles owner_profile on owner_profile.account_id = l.owner_account_id
    where l.id = p_list_id
  );
end
$$;

commit;
