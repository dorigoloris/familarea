-- FamilArea — il proprietario della Family viene restituito come Profile separato.
-- Non viene creato né richiesto alcun FamilyMember per l'owner.
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
          'last_name', coalesce(c.last_name, fm.last_name)
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

alter function public.get_my_family() owner to postgres;
revoke all on function public.get_my_family() from public,anon;
grant execute on function public.get_my_family() to authenticated;
