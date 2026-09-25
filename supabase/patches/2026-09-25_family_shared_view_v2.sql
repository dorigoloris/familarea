-- FamilArea — Famiglia V2, fase 2: vista condivisa per membership confermate.
-- L'accesso come membro deriva esclusivamente da family_access, mai da linked_profile_id da solo.

create or replace function public.get_my_family()
returns jsonb
language sql
stable security definer
set search_path=public,pg_temp as $$
  with viewer as (
    select a.id as account_id, p.id as profile_id
    from public.accounts a
    join public.profiles p on p.account_id = a.id
    where a.auth_user_id = auth.uid() and a.account_type = 'personal'
  ), selected_family as (
    select f.*, v.profile_id as viewer_profile_id,
           (f.owner_account_id = v.account_id) as viewer_is_owner,
           case when f.owner_account_id = v.account_id then 'owner' else fa.role end as viewer_role
    from public.families f
    cross join viewer v
    left join public.family_access fa on fa.family_id = f.id and fa.profile_id = v.profile_id
    where f.owner_account_id = v.account_id or fa.profile_id is not null
    order by (f.owner_account_id = v.account_id) desc, f.created_at
    limit 1
  )
  select jsonb_build_object(
    'family', to_jsonb(sf) - 'viewer_profile_id' - 'viewer_is_owner' - 'viewer_role',
    'viewer', jsonb_build_object(
      'profile_id', sf.viewer_profile_id,
      'is_owner', sf.viewer_is_owner,
      'role', sf.viewer_role
    ),
    'owner', jsonb_build_object(
      'profile_id', owner_profile.id,
      'first_name', owner_profile.first_name,
      'last_name', owner_profile.last_name,
      'birth_date', owner_profile.birth_date,
      'avatar_path', owner_profile.avatar_path
    ),
    'members', coalesce((
      select jsonb_agg(
        to_jsonb(fm) || jsonb_build_object(
          'first_name', case when sf.viewer_is_owner then coalesce(owner_contact.first_name, fm.first_name) else fm.first_name end,
          'last_name', case when sf.viewer_is_owner then coalesce(owner_contact.last_name, fm.last_name) else fm.last_name end,
          'profile_avatar_path', case when confirmed_access.profile_id is not null then linked_profile.avatar_path else null end,
          'membership_status', case
            when confirmed_access.profile_id is not null then 'confirmed'
            when sf.viewer_is_owner and pending_invite.id is not null then 'pending'
            else 'private'
          end,
          'pending_invite_id', case when sf.viewer_is_owner then pending_invite.id else null end
        )
        order by lower(fm.first_name), lower(coalesce(fm.last_name, '')), fm.id
      )
      from public.family_members fm
      left join public.contacts owner_contact
        on owner_contact.id = fm.contact_id
       and owner_contact.owner_account_id = sf.owner_account_id
       and sf.viewer_is_owner
      left join public.family_access confirmed_access
        on confirmed_access.family_id = sf.id
       and confirmed_access.profile_id = fm.linked_profile_id
      left join public.profiles linked_profile on linked_profile.id = confirmed_access.profile_id
      left join lateral (
        select fi.id
        from public.family_invites fi
        where sf.viewer_is_owner
          and fi.family_id = sf.id
          and fi.family_member_id = fm.id
          and fi.status = 'pending'
          and fi.expires_at > now()
        order by fi.created_at desc
        limit 1
      ) pending_invite on true
      where fm.family_id = sf.id
    ), '[]'::jsonb)
  )
  from selected_family sf
  join public.profiles owner_profile on owner_profile.account_id = sf.owner_account_id
$$;

alter function public.get_my_family() owner to postgres;
revoke all on function public.get_my_family() from public, anon;
grant execute on function public.get_my_family() to authenticated;
