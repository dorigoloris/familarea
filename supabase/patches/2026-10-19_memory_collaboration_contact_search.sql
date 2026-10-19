-- FamilArea V2 -- search Album recipients by the private Contact label too.
--
-- The candidate set is unchanged: only the caller's existing Contact links can
-- produce an account. This patch only makes a linked account discoverable when
-- the text entered by the owner matches the name stored in their address book.

begin;

create or replace function public.search_invitable_memory_collaboration_accounts(
  p_memory_id uuid,
  p_query text
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_query text := lower(btrim(coalesce(p_query, '')));
begin
  perform 1
  from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = v_owner_account_id;
  if not found then
    raise exception 'permission denied';
  end if;

  if v_query = '' then
    return;
  end if;

  return query
  with linked_contacts as (
    select
      cal.linked_account_id as account_id,
      lower(btrim(concat_ws(' ', c.first_name, c.last_name))) as contact_name
    from public.contacts c
    join public.contact_account_links cal
      on cal.contact_id = c.id
     and cal.owner_account_id = v_owner_account_id
    where c.owner_account_id = v_owner_account_id

    union

    select
      p.account_id,
      lower(btrim(concat_ws(' ', c.first_name, c.last_name))) as contact_name
    from public.contacts c
    join public.contact_profile_links cpl
      on cpl.contact_id = c.id
     and cpl.owner_account_id = v_owner_account_id
    join public.profiles p on p.id = cpl.profile_id
    where c.owner_account_id = v_owner_account_id
  ),
  linked_accounts as (
    select distinct account_id
    from linked_contacts
  )
  select jsonb_build_object(
    'account_id', identity.account_id,
    'display_name', identity.display_name,
    'avatar_path', identity.avatar_path,
    'account_type', identity.account_type
  )
  from linked_accounts linked
  join lateral public.contact_share_sender_identity(linked.account_id) identity on true
  where linked.account_id <> v_owner_account_id
    and identity.account_type in ('personal', 'organization')
    and (
      lower(identity.display_name) like '%' || v_query || '%'
      or lower(identity.email) like '%' || v_query || '%'
      or exists (
        select 1
        from linked_contacts contact_match
        where contact_match.account_id = linked.account_id
          and contact_match.contact_name like '%' || v_query || '%'
      )
    )
    and not exists (
      select 1
      from public.memory_collaborations mc
      where mc.memory_id = p_memory_id
        and mc.recipient_account_id = linked.account_id
        and mc.status in ('pending', 'accepted')
    )
  order by identity.display_name, identity.account_id
  limit 5;
end;
$$;

alter function public.search_invitable_memory_collaboration_accounts(uuid, text) owner to postgres;
revoke all on function public.search_invitable_memory_collaboration_accounts(uuid, text) from public, anon;
grant execute on function public.search_invitable_memory_collaboration_accounts(uuid, text) to authenticated;

commit;
