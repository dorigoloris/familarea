-- FamilArea: eliminazione definitiva di un'Area da parte di un suo admin.
-- Gli inviti vengono rimossi per primi per liberare la FK composta RESTRICT
-- verso area_memberships; tutte le altre dipendenze restano in cascade.

create or replace function public.delete_area(p_area_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select p.id
  into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  -- Primo lock delle operazioni Area-scoped: impedisce modifiche concorrenti
  -- a inviti e membership fino alla cancellazione conclusa.
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
    raise exception 'Non sei autorizzato a eliminare questa Area';
  end if;

  -- Necessario per la FK area_invites(area_id, target_managed_profile_id)
  -- -> area_memberships(...), ON DELETE RESTRICT.
  delete from public.area_invites
  where area_id = p_area_id;

  -- Le FK ON DELETE CASCADE eliminano esclusivamente i dati Area-scoped.
  delete from public.areas
  where id = p_area_id;
end;
$$;

revoke all on function public.delete_area(uuid) from public;
grant execute on function public.delete_area(uuid) to authenticated;
