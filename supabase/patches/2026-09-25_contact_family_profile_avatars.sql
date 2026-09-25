-- FamilArea — avatar Profile leggibili soltanto attraverso un Contact privato già collegato.
create or replace function public.can_read_linked_profile_avatar_path(p_path text)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select p_path is not null and exists (
    select 1
    from public.contact_profile_links l
    join public.profiles p on p.id = l.profile_id
    where l.owner_account_id = public.require_personal_account()
      and p.avatar_path = p_path
  )
$$;

create or replace function public.get_my_contacts()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select to_jsonb(c) || jsonb_build_object(
    'primary_email', (select cm.value from public.contact_methods cm where cm.contact_id = c.id and cm.method_type = 'email' order by cm.is_primary desc, cm.id limit 1),
    'primary_phone', (select cm.value from public.contact_methods cm where cm.contact_id = c.id and cm.method_type = 'phone' order by cm.is_primary desc, cm.id limit 1),
    'profile_avatar_path', (
      select p.avatar_path
      from public.contact_profile_links l
      join public.profiles p on p.id = l.profile_id
      where l.contact_id = c.id and l.owner_account_id = c.owner_account_id
      limit 1
    )
  )
  from public.contacts c
  where c.owner_account_id = public.require_current_account()
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id
$$;

create or replace function public.get_my_family()
returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object(
    'family', to_jsonb(f),
    'owner', jsonb_build_object(
      'profile_id', p.id,
      'first_name', p.first_name,
      'last_name', p.last_name,
      'birth_date', p.birth_date,
      'avatar_path', p.avatar_path
    ),
    'members', coalesce((
      select jsonb_agg(
        to_jsonb(fm) || jsonb_build_object(
          'first_name', coalesce(c.first_name, fm.first_name),
          'last_name', coalesce(c.last_name, fm.last_name),
          'profile_avatar_path', (
            select linked_profile.avatar_path
            from public.contact_profile_links l
            join public.profiles linked_profile on linked_profile.id = l.profile_id
            where l.contact_id = fm.contact_id and l.owner_account_id = f.owner_account_id
            limit 1
          )
        ) order by fm.first_name
      )
      from public.family_members fm
      left join public.contacts c on c.id = fm.contact_id and c.owner_account_id = f.owner_account_id
      where fm.family_id = f.id
    ), '[]'::jsonb)
  )
  from public.families f
  join public.profiles p on p.account_id = f.owner_account_id
  where f.owner_account_id = public.require_personal_account()
$$;

alter function public.can_read_linked_profile_avatar_path(text) owner to postgres;
alter function public.get_my_contacts() owner to postgres;
alter function public.get_my_family() owner to postgres;
revoke all on function public.can_read_linked_profile_avatar_path(text),public.get_my_contacts(),public.get_my_family() from public,anon;
grant execute on function public.can_read_linked_profile_avatar_path(text),public.get_my_contacts(),public.get_my_family() to authenticated;

drop policy if exists profile_avatars_select on storage.objects;
create policy profile_avatars_select on storage.objects for select to authenticated
using (
  bucket_id = 'profile-avatars'
  and (
    public.can_manage_own_avatar_path(name)
    or public.can_read_linked_profile_avatar_path(name)
  )
);
