-- FamilArea — rollback controllato per 2026-10-20_memory_share_email_invitations.sql
-- Non eseguire automaticamente. Eseguire solo con autorizzazione esplicita.
--
-- Sicurezza: procede soltanto se non e' stato creato alcun invito.
-- Non elimina quindi inviti, storico o collaborazioni Album gia' utilizzati.

begin;

do $$
begin
  if to_regclass('public.memory_share_invitations') is not null
     and exists (
       select 1
       from public.memory_share_invitations
     ) then
    raise exception
      'Rollback interrotto: esistono inviti Album. Non vengono eliminati dati o collaborazioni gia'' utilizzati.';
  end if;
end
$$;

drop function if exists public.mark_memory_share_invitation_delivery(uuid, text, text);
drop function if exists public.decline_my_memory_share_invitation(text);
drop function if exists public.accept_my_memory_share_invitation(text);
drop function if exists public.get_memory_share_invitation_context(text);
drop function if exists public.revoke_memory_share_invitation(uuid);
drop function if exists public.cancel_memory_share_invitation(uuid);
drop function if exists public.get_memory_share_invitation_management(uuid);
drop function if exists public.create_memory_share_invitation(uuid, uuid, text);
drop function if exists public.search_my_memory_share_contacts(uuid, text);
drop function if exists public.hash_memory_share_invitation_token(text);

drop table if exists public.memory_share_invitations;

commit;