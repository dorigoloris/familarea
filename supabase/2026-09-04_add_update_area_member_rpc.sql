-- =============================================================================
-- FamilArea — migrazione incrementale: RPC update_area_member
-- =============================================================================
-- Da eseguire manualmente sul database Supabase remoto esistente.
-- NON ricrea tabelle, trigger o altre funzioni già presenti: aggiunge
-- esclusivamente la nuova RPC per la modifica anagrafica di un membro.
--
-- Prerequisiti già presenti sul remoto (non toccati da questo file):
--   - tabella public.profiles (colonne first_name, last_name, birth_date, user_id)
--   - tabella public.area_memberships (colonne area_id, profile_id, role)
--   - RLS invariata: nessuna policy viene creata o modificata qui.
--
-- Sicurezza:
--   - SECURITY DEFINER con search_path fissato a public, pg_temp;
--   - EXECUTE revocato da PUBLIC e concesso solo ad authenticated;
--   - verifica lato server che il chiamante sia admin dell'Area indicata;
--   - verifica che il profilo target appartenga effettivamente a quella Area;
--   - non consente di modificare user_id o altre colonne di collegamento.
-- =============================================================================

create or replace function public.update_area_member(
  p_area_id    uuid,
  p_profile_id uuid,
  p_first_name text,
  p_last_name  text,
  p_birth_date date
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select id into v_caller_profile_id
  from public.profiles
  where user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  if not exists (
    select 1 from public.area_memberships
    where area_id = p_area_id
      and profile_id = v_caller_profile_id
      and role = 'admin'
  ) then
    raise exception 'permission denied: solo un admin dell''Area può modificare i membri';
  end if;

  if not exists (
    select 1 from public.area_memberships
    where area_id = p_area_id
      and profile_id = p_profile_id
  ) then
    raise exception 'permission denied: il profilo indicato non appartiene a questa Area';
  end if;

  if btrim(coalesce(p_first_name, '')) = '' then
    raise exception 'Il nome è obbligatorio';
  end if;

  update public.profiles
  set first_name = btrim(p_first_name),
      last_name  = nullif(btrim(coalesce(p_last_name, '')), ''),
      birth_date = p_birth_date
  where id = p_profile_id;
end;
$$;
comment on function public.update_area_member(uuid, uuid, text, text, date) is
  'Aggiorna nome, cognome e data di nascita di un membro dell''Area. Richiede che il chiamante sia admin di quella Area; non modifica user_id né altre colonne.';

revoke all on function public.update_area_member(uuid, uuid, text, text, date) from public;
grant execute on function public.update_area_member(uuid, uuid, text, text, date) to authenticated;
