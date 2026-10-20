-- FamilArea — disattivazione immediata delle RPC per gli inviti Album via email.
-- Non elimina inviti, storico o collaborazioni. Non modifica i dati esistenti.
-- Applicare solo con autorizzazione esplicita se occorre fermare il flusso utenti.

begin;

revoke execute on function public.search_my_memory_share_contacts(uuid, text),
  public.create_memory_share_invitation(uuid, uuid, text),
  public.get_memory_share_invitation_management(uuid),
  public.cancel_memory_share_invitation(uuid),
  public.revoke_memory_share_invitation(uuid),
  public.accept_my_memory_share_invitation(text),
  public.decline_my_memory_share_invitation(text)
from authenticated;

revoke execute on function public.get_memory_share_invitation_context(text)
from anon, authenticated;

commit;