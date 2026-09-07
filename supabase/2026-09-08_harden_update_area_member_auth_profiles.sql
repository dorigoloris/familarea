-- FamilArea: impedisce agli admin Area di modificare profili collegati ad account Auth.
-- La RPC resta destinata esclusivamente ai profili gestiti senza user_id.

create or replace function public.update_area_member(
  p_area_id uuid,
  p_profile_id uuid,
  p_first_name text,
  p_last_name text,
  p_birth_date date
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_target_user_id uuid;
begin
  select p.id
  into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  -- Stesso primo lock delle operazioni che modificano membership nell'Area.
  perform 1
  from public.areas a
  where a.id = p_area_id
  for update;

  if not found then
    raise exception 'Area non trovata';
  end if;

  if not exists (
    select 1
    from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'permission denied: solo un admin dell''Area puo'' modificare i partecipanti';
  end if;

  -- Blocca insieme membership e profilo target prima di valutarne lo stato.
  select p.user_id
  into v_target_user_id
  from public.area_memberships am
  join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id
    and am.profile_id = p_profile_id
  for update of am, p;

  if not found then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  if exists (
    select 1
    from public.contact_participant_profiles cpp
    where cpp.profile_id = p_profile_id
  ) then
    raise exception 'Impossibile modificare questo partecipante: i dati provengono da un Contatto personale';
  end if;

  if v_target_user_id is not null then
    raise exception 'Impossibile modificare un profilo collegato a un account utente';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome e'' obbligatorio';
  end if;

  update public.profiles
  set first_name = btrim(p_first_name),
      last_name = nullif(btrim(coalesce(p_last_name, '')), ''),
      birth_date = p_birth_date
  where id = p_profile_id;
end;
$$;

revoke all on function public.update_area_member(uuid, uuid, text, text, date) from public;
grant execute on function public.update_area_member(uuid, uuid, text, text, date) to authenticated;
