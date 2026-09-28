-- Storage RLS executes these helpers as authenticated callers.

begin;

grant execute on function public.can_read_managed_family_member_avatar_path(text) to authenticated;
grant execute on function public.can_manage_managed_family_member_avatar_path(text) to authenticated;

commit;
