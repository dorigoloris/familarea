-- FamilArea — activation deferred for Album email invitations.
-- Apply only after the Album UI, acceptance page and Edge Function are deployed and tested.

begin;

grant execute on function public.search_my_memory_share_contacts(uuid, text),
  public.create_memory_share_invitation(uuid, uuid, text),
  public.get_memory_share_invitation_management(uuid),
  public.cancel_memory_share_invitation(uuid),
  public.revoke_memory_share_invitation(uuid),
  public.accept_my_memory_share_invitation(text),
  public.decline_my_memory_share_invitation(text)
to authenticated;

grant execute on function public.get_memory_share_invitation_context(text)
to anon, authenticated;

commit;