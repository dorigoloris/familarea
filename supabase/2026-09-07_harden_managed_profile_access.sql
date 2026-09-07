-- =============================================================================
-- FamilArea - impedisce l'accesso autonomo ai profili managed collegati ad Auth
-- =============================================================================

begin;

create or replace function public.is_area_member(p_area_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.area_memberships am
    join public.profiles p on p.id = am.profile_id
    where am.area_id = p_area_id
      and p.user_id = auth.uid()
      and am.role in ('admin', 'member')
  );
$$;

comment on function public.is_area_member(uuid) is
  'Vero se l''utente autenticato ha una membership autonoma admin o member nell''Area indicata. I profili managed non ottengono accesso autonomo anche se collegati ad Auth.';

create or replace function public.can_view_profile(p_profile_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    exists (
      select 1
      from public.profiles me
      where me.id = p_profile_id
        and me.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.area_memberships am_target
      join public.area_memberships am_me on am_me.area_id = am_target.area_id
      join public.profiles me on me.id = am_me.profile_id
      where am_target.profile_id = p_profile_id
        and me.user_id = auth.uid()
        and am_me.role in ('admin', 'member')
    );
$$;

comment on function public.can_view_profile(uuid) is
  'Vero se il profilo e'' quello dell''utente autenticato, oppure se il chiamante e'' admin/member in un''Area condivisa con quel profilo. I managed non ottengono visibilita'' autonoma sulle Aree.';

revoke all on function public.is_area_member(uuid) from public;
revoke all on function public.can_view_profile(uuid) from public;
grant execute on function public.is_area_member(uuid) to authenticated;
grant execute on function public.can_view_profile(uuid) to authenticated;

commit;
