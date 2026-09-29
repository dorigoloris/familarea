-- FamilArea — allow authenticated Storage policies to invoke vehicle-image helpers.

begin;

grant execute on function public.can_read_my_deadline_item_image_path(text) to authenticated;
grant execute on function public.can_manage_my_deadline_item_image_path(text) to authenticated;

commit;
