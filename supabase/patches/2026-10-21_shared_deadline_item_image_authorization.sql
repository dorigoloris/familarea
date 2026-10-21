-- FamilArea V2 — exact-deadline authorization for shared item-image signing.
--
-- This patch creates no Storage policy and grants no direct bucket access.
-- It is intentionally not applied automatically.

begin;

create or replace function public.get_my_authorized_deadline_item_image_path(
  p_deadline_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
  v_image_path text;
begin
  if p_deadline_id is null then
    raise exception 'shared deadline unavailable';
  end if;

  select di.image_path
    into v_image_path
  from public.deadlines d
  left join public.deadline_items di
    on di.id = d.deadline_item_id
   and di.owner_account_id = d.owner_account_id
  where d.id = p_deadline_id
    and (
      d.owner_account_id = v_account_id
      or exists (
        select 1
        from public.deadline_collaborations dc
        where dc.deadline_id = d.id
          and dc.owner_account_id = d.owner_account_id
          and dc.recipient_account_id = v_account_id
          and dc.status = 'accepted'
      )
    );

  if not found then
    raise exception 'shared deadline unavailable';
  end if;

  return v_image_path;
end;
$$;

alter function public.get_my_authorized_deadline_item_image_path(uuid) owner to postgres;
revoke all on function public.get_my_authorized_deadline_item_image_path(uuid)
  from public, anon;
grant execute on function public.get_my_authorized_deadline_item_image_path(uuid)
  to authenticated;

commit;
