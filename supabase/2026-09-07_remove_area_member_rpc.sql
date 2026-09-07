-- FamilArea — rimozione sicura di una membership Area secondo la policy MVP.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create function public.remove_area_member(
  p_area_id uuid,
  p_profile_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_role text;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Utente non autorizzato: profilo non trovato';
  end if;

  -- Serializza le rimozioni nella stessa Area e protegge il conteggio admin.
  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;

  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'Utente non autorizzato: solo un admin dell''Area può rimuovere membri';
  end if;

  select am.role into v_target_role
  from public.area_memberships am
  where am.area_id = p_area_id and am.profile_id = p_profile_id
  for update;
  if not found then raise exception 'Membership del membro non trovata in questa Area'; end if;

  if v_target_role = 'admin' and not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.role = 'admin' and am.profile_id <> p_profile_id
  ) then
    raise exception 'Impossibile rimuovere l''ultimo amministratore dell''Area';
  end if;

  perform 1 from public.area_activities a
  where a.area_id = p_area_id and a.created_by_profile_id = p_profile_id
  for update;
  if found then raise exception 'Impossibile rimuovere il membro: è creatore di attività in questa Area'; end if;

  perform 1 from public.area_events e
  where e.area_id = p_area_id and e.created_by_profile_id = p_profile_id
  for update;
  if found then raise exception 'Impossibile rimuovere il membro: è creatore di eventi in questa Area'; end if;

  -- Blocca le sole attività che diverrebbero creator_assignees senza assegnatari.
  perform 1
  from public.area_activities a
  where a.area_id = p_area_id
    and a.visibility = 'creator_assignees'
    and exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id = p_profile_id)
    and not exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id <> p_profile_id)
  for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo assegnatario di attività selettiva'; end if;

  -- Blocca le sole righe evento che diverrebbero creator_participants senza partecipanti.
  perform 1
  from public.area_events e
  where e.area_id = p_area_id
    and e.visibility = 'creator_participants'
    and exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id = p_profile_id)
    and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id <> p_profile_id)
  for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di evento selettivo'; end if;

  delete from public.area_memberships
  where area_id = p_area_id and profile_id = p_profile_id;
end;
$$;

revoke all on function public.remove_area_member(uuid, uuid) from public;
grant execute on function public.remove_area_member(uuid, uuid) to authenticated;

commit;
