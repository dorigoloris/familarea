-- FamilArea — reuse the managed Family-member ownership assertion for deadlines.

begin;

create or replace function public.create_deadline(
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_family_member_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account uuid := public.require_current_account();
  v_id uuid;
begin
  if p_family_member_id is not null then
    perform public.assert_manage_owned_family_member(p_family_member_id);
  end if;

  insert into public.deadlines(
    owner_account_id, title, category, first_due_on, recurrence_months,
    reminder_days, notes, family_member_id
  ) values (
    v_account, nullif(btrim(p_title), ''), nullif(btrim(p_category), ''),
    p_first_due_on, p_recurrence_months, coalesce(p_reminder_days, 30),
    nullif(btrim(p_notes), ''), p_family_member_id
  ) returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.create_deadline(text,text,date,smallint,smallint,text,uuid) from public, anon;
grant execute on function public.create_deadline(text,text,date,smallint,smallint,text,uuid) to authenticated;
alter function public.create_deadline(text,text,date,smallint,smallint,text,uuid) owner to postgres;

commit;
