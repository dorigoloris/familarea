-- FamilArea — atomically update an ordinary personal deadline and its optional item.

begin;

create or replace function public.update_my_deadline_with_item(
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_deadline_item_id uuid default null
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
  select d.*
  into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_account_id;

  if not found then
    raise exception 'deadline unavailable';
  end if;

  -- Reuse the established deadline validation/update path while preserving
  -- fields that this personal form intentionally does not expose.
  perform public.update_deadline(
    p_deadline_id,
    p_title,
    p_category,
    p_first_due_on,
    p_recurrence_months,
    p_reminder_days,
    p_notes,
    v_deadline.family_member_id,
    v_deadline.status
  );

  return public.set_my_deadline_item(p_deadline_id, p_deadline_item_id);
end;
$$;

alter function public.update_my_deadline_with_item(uuid, text, text, date, smallint, smallint, text, uuid) owner to postgres;
revoke all on function public.update_my_deadline_with_item(uuid, text, text, date, smallint, smallint, text, uuid) from public, anon;
grant execute on function public.update_my_deadline_with_item(uuid, text, text, date, smallint, smallint, text, uuid) to authenticated;

commit;
