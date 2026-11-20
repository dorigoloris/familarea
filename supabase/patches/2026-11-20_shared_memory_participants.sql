-- FamilArea V2 -- read-only participant names for accepted Album recipients.
-- This does not expose the owner's contacts, contact methods or photo tags.

begin;

create function public.get_shared_memory_participants(
  p_memory_id uuid
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_owner_account_id uuid;
begin
  if p_memory_id is null then
    raise exception 'shared memory unavailable';
  end if;

  select mc.owner_account_id
  into v_owner_account_id
  from public.memory_collaborations mc
    where mc.memory_id = p_memory_id
      and mc.recipient_account_id = v_recipient_account_id
      and mc.status = 'accepted'
    limit 1;

  if v_owner_account_id is null then
    raise exception 'shared memory unavailable';
  end if;

  return query
  select jsonb_build_object(
    'first_name', c.first_name,
    'last_name', c.last_name
  )
  from public.memory_participants mp
  join public.contacts c
    on c.id = mp.contact_id
   and c.owner_account_id = mp.owner_account_id
  where mp.memory_id = p_memory_id
    and mp.owner_account_id = v_owner_account_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), mp.created_at, mp.id;
end;
$$;

alter function public.get_shared_memory_participants(uuid) owner to postgres;

revoke all on function public.get_shared_memory_participants(uuid) from public, anon;
grant execute on function public.get_shared_memory_participants(uuid) to authenticated;

commit;
