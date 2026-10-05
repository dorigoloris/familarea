-- FamilArea — direct shared lists: owner search and management payload.
-- Applies only to personal lists. It deliberately has no Area dependency.

begin;

create or replace function public.search_invitable_list_accounts(
  p_list_id uuid,
  p_query text
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  v_owner uuid := public.require_current_account();
  v_query text := lower(btrim(coalesce(p_query, '')));
begin
  perform 1
  from public.lists l
  where l.id = p_list_id
    and l.owner_account_id = v_owner
    and l.area_id is null;
  if not found then raise exception 'permission denied'; end if;

  -- A short value must not be usable to enumerate the account base.
  if char_length(v_query) < 3 then return; end if;

  return query
  select jsonb_build_object(
    'account_id', a.id,
    'display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
    'avatar_path', p.avatar_path
  )
  from public.accounts a
  join public.profiles p on p.account_id = a.id
  where a.account_type = 'personal'
    and a.id <> v_owner
    and (p.first_name ilike v_query || '%' or coalesce(p.last_name, '') ilike v_query || '%')
    and not exists (
      select 1 from public.list_participants lp
      where lp.list_id = p_list_id and lp.account_id = a.id
    )
    and not exists (
      select 1 from public.list_invites li
      where li.list_id = p_list_id
        and li.recipient_account_id = a.id
        and li.status = 'pending'
    )
  order by p.first_name, p.last_name nulls first, a.id
  limit 5;
end
$$;

create or replace function public.get_list_share_management(p_list_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare v_owner uuid := public.require_current_account();
begin
  if not exists (
    select 1
    from public.lists l
    where l.id = p_list_id
      and l.owner_account_id = v_owner
      and l.area_id is null
  ) then
    raise exception 'permission denied';
  end if;

  return (
    select jsonb_build_object(
      'list', jsonb_build_object(
        'id', l.id,
        'sharing_status', case when exists (
          select 1 from public.list_participants lp where lp.list_id = l.id
        ) then 'shared' else 'private' end
      ),
      'pending_invites', coalesce((
        select jsonb_agg(jsonb_build_object(
          'invite_id', li.id,
          'recipient_account_id', li.recipient_account_id,
          'display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
          'avatar_path', p.avatar_path,
          'created_at', li.created_at,
          'status', li.status
        ) order by li.created_at desc, li.id)
        from public.list_invites li
        join public.profiles p on p.account_id = li.recipient_account_id
        where li.list_id = l.id and li.status = 'pending'
      ), '[]'::jsonb),
      'participants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'account_id', lp.account_id,
          'display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
          'avatar_path', p.avatar_path,
          'accepted_at', lp.accepted_at
        ) order by lp.accepted_at, lp.account_id)
        from public.list_participants lp
        join public.profiles p on p.account_id = lp.account_id
        where lp.list_id = l.id
      ), '[]'::jsonb)
    )
    from public.lists l
    where l.id = p_list_id
  );
end
$$;

revoke all on function public.search_invitable_list_accounts(uuid,text), public.get_list_share_management(uuid) from public, anon;
grant execute on function public.search_invitable_list_accounts(uuid,text), public.get_list_share_management(uuid) to authenticated;

commit;
