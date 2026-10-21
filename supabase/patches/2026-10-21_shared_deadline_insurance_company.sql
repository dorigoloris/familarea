-- FamilArea V2 — insurance company in accepted shared-deadline projections.
-- This patch is intentionally not applied automatically.

begin;

create or replace function public.deadline_collaboration_view_projection(
  p_deadline_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'deadline_id', d.id,
    'title', d.title,
    'category', d.category,
    'first_due_on', d.first_due_on,
    'recurrence_months', d.recurrence_months,
    'start_time', d.start_time,
    'end_time', d.end_time,
    'status', d.status,
    'insurance_company', d.insurance_company,
    'shared_item_name', di.name,
    'shared_vehicle_plate', case
      when di.category = 'vehicle' then di.plate
      else null
    end,
    'shared_item_category', di.category
  )
  from public.deadlines d
  left join public.deadline_items di
    on di.id = d.deadline_item_id
   and di.owner_account_id = d.owner_account_id
  where d.id = p_deadline_id
$$;

alter function public.deadline_collaboration_view_projection(uuid) owner to postgres;

-- Keep the projection internal; existing shared-deadline RPCs authorize calls.
revoke all on function public.deadline_collaboration_view_projection(uuid)
  from public, anon, authenticated;

commit;
