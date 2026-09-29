-- FamilArea — update or clear an ordinary deadline's optional management item.

begin;

create or replace function public.set_my_deadline_item(
  p_deadline_id uuid,
  p_item_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_deadline public.deadlines%rowtype;
begin
  if not exists (
    select 1
    from public.deadlines d
    where d.id = p_deadline_id
      and d.owner_account_id = v_account_id
  ) then
    raise exception 'deadline unavailable';
  end if;

  if p_item_id is not null then
    perform public.assert_my_deadline_item(p_item_id);
  end if;

  update public.deadlines d
  set deadline_item_id = p_item_id
  where d.id = p_deadline_id
    and d.owner_account_id = v_account_id
  returning d.* into v_deadline;

  return to_jsonb(v_deadline);
end;
$$;

alter function public.set_my_deadline_item(uuid, uuid) owner to postgres;
revoke all on function public.set_my_deadline_item(uuid, uuid) from public, anon;
grant execute on function public.set_my_deadline_item(uuid, uuid) to authenticated;

commit;
