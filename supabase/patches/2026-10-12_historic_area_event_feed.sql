-- FamilArea — expose authorized historic Area Events in the unified event feed.
--
-- This is a read-path correction only: it neither migrates nor changes Events,
-- Areas, participants, invites, attachments or Storage objects.

begin;

-- The previous personal-only feed called event_personal_source directly, which
-- excluded valid Area-owner and Area-member access. event_visibility_source is
-- the existing authorization source used by Calendar and preserves all of its
-- owner, participant and Area checks.
create or replace function public.get_visible_events()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.event_view_payload(e, visibility.visibility_source)
  from public.events e
  cross join lateral (
    select public.event_visibility_source(e.id) as visibility_source
  ) visibility
  where visibility.visibility_source is not null
    and e.status <> 'cancelled'
  order by e.starts_at, e.created_at, e.id;
$$;

alter function public.get_visible_events() owner to postgres;
revoke all on function public.get_visible_events() from public, anon;
grant execute on function public.get_visible_events() to authenticated;

commit;
