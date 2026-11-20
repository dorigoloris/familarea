-- FamilArea V2 -- read-only Album and photo-share summary for one Contact.
-- Associations use the stored Contact ID or an existing account Contact link;
-- names and current email addresses are never used as matching keys.

begin;

create function public.get_my_contact_memory_share_summary(
  p_contact_id uuid
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  if p_contact_id is null or not exists (
    select 1
    from public.contacts c
    where c.id = p_contact_id
      and c.owner_account_id = v_owner_account_id
  ) then
    raise exception 'contact unavailable';
  end if;

  return query
  with album_invitation_rows as (
    select
      'album'::text as share_kind,
      'email'::text as source_kind,
      i.id as share_id,
      m.id as memory_id,
      m.timeline_id,
      m.title as memory_title,
      case
        when i.status = 'pending' and i.expires_at <= now() then 'expired'
        when i.status = 'accepted'
          and mc.status = 'revoked'
          and mc.revoked_by_account_id = mc.recipient_account_id then 'abandoned'
        when i.status = 'accepted' and mc.status = 'revoked' then 'revoked'
        when i.status = 'accepted' and mc.status = 'accepted' then 'accepted'
        when i.status = 'accepted' then 'unavailable'
        else i.status
      end as share_status,
      i.created_at,
      i.accepted_at,
      i.revoked_at,
      i.expires_at,
      null::integer as photo_count
    from public.memory_share_invitations i
    join public.memories m
      on m.id = i.memory_id
     and m.owner_account_id = i.owner_account_id
    left join public.memory_collaborations mc
      on mc.id = i.accepted_collaboration_id
     and mc.memory_id = i.memory_id
     and mc.owner_account_id = i.owner_account_id
    where i.owner_account_id = v_owner_account_id
      and i.recipient_contact_id = p_contact_id
  ),
  direct_collaboration_rows as (
    select
      'album'::text as share_kind,
      'collaboration'::text as source_kind,
      mc.id as share_id,
      m.id as memory_id,
      m.timeline_id,
      m.title as memory_title,
      mc.status as share_status,
      mc.created_at,
      mc.accepted_at,
      mc.revoked_at,
      null::timestamptz as expires_at,
      null::integer as photo_count
    from public.memory_collaborations mc
    join public.memories m
      on m.id = mc.memory_id
     and m.owner_account_id = mc.owner_account_id
    where mc.owner_account_id = v_owner_account_id
      and not exists (
        select 1
        from public.memory_share_invitations i
        where i.accepted_collaboration_id = mc.id
          and i.memory_id = mc.memory_id
          and i.owner_account_id = mc.owner_account_id
      )
      and (
        exists (
          select 1
          from public.contact_account_links cal
          where cal.contact_id = p_contact_id
            and cal.owner_account_id = v_owner_account_id
            and cal.linked_account_id = mc.recipient_account_id
        )
        or exists (
          select 1
          from public.contact_profile_links cpl
          join public.profiles p on p.id = cpl.profile_id
          where cpl.contact_id = p_contact_id
            and cpl.owner_account_id = v_owner_account_id
            and p.account_id = mc.recipient_account_id
        )
      )
  ),
  photo_share_rows as (
    select
      'photo'::text as share_kind,
      'photo'::text as source_kind,
      s.id as share_id,
      m.id as memory_id,
      m.timeline_id,
      m.title as memory_title,
      case
        when s.status = 'pending' and s.expires_at <= now() then 'expired'
        else s.status
      end as share_status,
      s.created_at,
      s.accepted_at,
      s.revoked_at,
      s.expires_at,
      (
        select count(*)::integer
        from public.memory_photo_share_attachments sa
        where sa.share_id = s.id
      ) as photo_count
    from public.memory_photo_shares s
    join public.memories m
      on m.id = s.memory_id
     and m.owner_account_id = s.owner_account_id
    where s.owner_account_id = v_owner_account_id
      and s.recipient_contact_id = p_contact_id
  ),
  shares as (
    select * from album_invitation_rows
    union all
    select * from direct_collaboration_rows
    union all
    select * from photo_share_rows
  )
  select jsonb_build_object(
    'share_kind', share_kind,
    'source_kind', source_kind,
    'share_id', share_id,
    'memory_id', memory_id,
    'timeline_id', timeline_id,
    'memory_title', memory_title,
    'status', share_status,
    'created_at', created_at,
    'accepted_at', accepted_at,
    'revoked_at', revoked_at,
    'expires_at', expires_at,
    'photo_count', photo_count
  )
  from shares
  order by created_at desc, share_kind, share_id;
end;
$$;

alter function public.get_my_contact_memory_share_summary(uuid) owner to postgres;

revoke all on function public.get_my_contact_memory_share_summary(uuid) from public, anon;
grant execute on function public.get_my_contact_memory_share_summary(uuid) to authenticated;

commit;
