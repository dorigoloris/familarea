-- FamilArea — Scadenze personali (MVP).
-- Le occorrenze sono calcolate al bisogno: vengono persistite solo le conferme.

begin;

create table public.deadlines (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (title = btrim(title) and char_length(title) > 0),
  category text not null check (category in ('vehicle', 'home', 'documents', 'animals', 'contracts_subscriptions', 'other')),
  reference text check (reference is null or reference = btrim(reference)),
  family_member_id uuid references public.family_members(id) on delete set null,
  first_due_on date not null,
  recurrence_months smallint check (recurrence_months is null or recurrence_months in (1, 6, 12, 24)),
  reminder_days smallint not null default 30 check (reminder_days in (0, 7, 15, 30)),
  notes text,
  status text not null default 'active' check (status in ('active', 'terminated')),
  terminated_on date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint deadlines_termination_check check (
    (status = 'active' and terminated_on is null)
    or (status = 'terminated' and terminated_on is not null and terminated_on >= first_due_on)
  )
);

create table public.deadline_occurrence_completions (
  deadline_id uuid not null references public.deadlines(id) on delete cascade,
  occurrence_on date not null,
  completed_at timestamptz not null default now(),
  completed_by_profile_id uuid references public.profiles(id) on delete set null,
  notes text,
  primary key (deadline_id, occurrence_on)
);

create index deadlines_owner_status_due_idx
  on public.deadlines (owner_profile_id, status, first_due_on, id);
create index deadlines_owner_family_member_idx
  on public.deadlines (owner_profile_id, family_member_id)
  where family_member_id is not null;

create function public.set_deadline_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger deadlines_set_updated_at
  before update on public.deadlines
  for each row execute function public.set_deadline_updated_at();

-- Restituisce le sole date della serie richieste nell'intervallo inclusivo.
-- Il giorno resta ancorato alla data base: 31/01 mensile produce 28/29 febbraio,
-- poi 31 marzo. Una serie annuale del 29 febbraio produce il 28 febbraio nei
-- non bisestili e torna al 29 febbraio negli anni bisestili.
create function public.deadline_occurrence_dates(
  p_first_due_on date,
  p_recurrence_months smallint,
  p_terminated_on date,
  p_from date,
  p_to date
)
returns table(occurrence_on date)
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_cap date;
  v_step integer;
  v_max_step integer;
  v_month date;
  v_day integer := extract(day from p_first_due_on)::integer;
  v_candidate date;
begin
  if p_first_due_on is null or p_from is null or p_to is null or p_from > p_to then
    return;
  end if;

  v_cap := least(p_to, coalesce(p_terminated_on, p_to));
  if v_cap < p_first_due_on then
    return;
  end if;

  if p_recurrence_months is null then
    if p_first_due_on between p_from and v_cap then
      occurrence_on := p_first_due_on;
      return next;
    end if;
    return;
  end if;

  v_max_step := (
    ((extract(year from v_cap)::integer - extract(year from p_first_due_on)::integer) * 12
      + extract(month from v_cap)::integer - extract(month from p_first_due_on)::integer)
    / p_recurrence_months
  );

  for v_step in 0..greatest(v_max_step, 0) loop
    v_month := (date_trunc('month', p_first_due_on)::date
      + make_interval(months => v_step * p_recurrence_months))::date;
    v_candidate := make_date(
      extract(year from v_month)::integer,
      extract(month from v_month)::integer,
      least(v_day, extract(day from (v_month + interval '1 month - 1 day'))::integer)
    );
    if v_candidate between p_from and v_cap then
      occurrence_on := v_candidate;
      return next;
    end if;
  end loop;
end;
$$;

alter table public.deadlines enable row level security;
alter table public.deadline_occurrence_completions enable row level security;
alter table public.deadlines no force row level security;
alter table public.deadline_occurrence_completions no force row level security;

revoke all on public.deadlines, public.deadline_occurrence_completions from public, anon, authenticated;

create function public.get_my_deadlines(p_status text default null)
returns table(
  id uuid, title text, category text, reference text, family_member_id uuid,
  first_due_on date, recurrence_months smallint, reminder_days smallint,
  notes text, status text, terminated_on date, created_at timestamptz, updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  if p_status is not null and p_status not in ('active', 'terminated') then
    raise exception 'Stato scadenza non valido';
  end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query
  select d.id, d.title, d.category, d.reference, d.family_member_id,
    d.first_due_on, d.recurrence_months, d.reminder_days,
    d.notes, d.status, d.terminated_on, d.created_at, d.updated_at
  from public.deadlines d
  where d.owner_profile_id = v_profile_id
    and (p_status is null or d.status = p_status)
  order by d.status = 'terminated', d.first_due_on, d.created_at, d.id;
end;
$$;

create function public.get_my_deadline(p_deadline_id uuid)
returns table(
  id uuid, title text, category text, reference text, family_member_id uuid,
  first_due_on date, recurrence_months smallint, reminder_days smallint,
  notes text, status text, terminated_on date, created_at timestamptz, updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query
  select d.id, d.title, d.category, d.reference, d.family_member_id,
    d.first_due_on, d.recurrence_months, d.reminder_days,
    d.notes, d.status, d.terminated_on, d.created_at, d.updated_at
  from public.deadlines d
  where d.id = p_deadline_id and d.owner_profile_id = v_profile_id;
  if not found then raise exception 'Scadenza non trovata o non accessibile'; end if;
end;
$$;

create function public.assert_my_deadline_family_member(p_profile_id uuid, p_family_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_family_member_id is null then return; end if;
  if not exists (
    select 1
    from public.family_members fm
    join public.families f on f.id = fm.family_id
    join public.family_access fa on fa.family_id = f.id
      and fa.profile_id = p_profile_id
      and fa.role = 'owner'
    where fm.id = p_family_member_id
      and f.created_by_profile_id = p_profile_id
  ) then
    raise exception 'Membro Famiglia non trovato o non accessibile';
  end if;
end;
$$;

create function public.create_my_deadline(
  p_title text,
  p_category text,
  p_first_due_on date,
  p_reference text default null,
  p_family_member_id uuid default null,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_deadline_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if btrim(coalesce(p_title, '')) = '' then raise exception 'Il titolo della scadenza e'' obbligatorio'; end if;
  if p_category not in ('vehicle', 'home', 'documents', 'animals', 'contracts_subscriptions', 'other') then raise exception 'Categoria scadenza non valida'; end if;
  if p_first_due_on is null then raise exception 'La prima scadenza e'' obbligatoria'; end if;
  if p_recurrence_months is not null and p_recurrence_months not in (1, 6, 12, 24) then raise exception 'Ricorrenza scadenza non valida'; end if;
  if coalesce(p_reminder_days, -1) not in (0, 7, 15, 30) then raise exception 'Anticipo promemoria non valido'; end if;
  perform public.assert_my_deadline_family_member(v_profile_id, p_family_member_id);
  insert into public.deadlines (
    owner_profile_id, title, category, reference, family_member_id, first_due_on,
    recurrence_months, reminder_days, notes
  ) values (
    v_profile_id, btrim(p_title), p_category, nullif(btrim(coalesce(p_reference, '')), ''),
    p_family_member_id, p_first_due_on, p_recurrence_months, p_reminder_days, p_notes
  ) returning id into v_deadline_id;
  return v_deadline_id;
end;
$$;

create function public.update_my_deadline(
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_reference text default null,
  p_family_member_id uuid default null,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_first_due_on date;
  v_recurrence_months smallint;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select d.first_due_on, d.recurrence_months into v_first_due_on, v_recurrence_months
  from public.deadlines d
  where d.id = p_deadline_id and d.owner_profile_id = v_profile_id and d.status = 'active'
  for update;
  if not found then raise exception 'Scadenza non trovata, terminata o non accessibile'; end if;
  if btrim(coalesce(p_title, '')) = '' then raise exception 'Il titolo della scadenza e'' obbligatorio'; end if;
  if p_category not in ('vehicle', 'home', 'documents', 'animals', 'contracts_subscriptions', 'other') then raise exception 'Categoria scadenza non valida'; end if;
  if p_first_due_on is null then raise exception 'La prima scadenza e'' obbligatoria'; end if;
  if p_recurrence_months is not null and p_recurrence_months not in (1, 6, 12, 24) then raise exception 'Ricorrenza scadenza non valida'; end if;
  if coalesce(p_reminder_days, -1) not in (0, 7, 15, 30) then raise exception 'Anticipo promemoria non valido'; end if;
  if (p_first_due_on is distinct from v_first_due_on or p_recurrence_months is distinct from v_recurrence_months)
    and exists (select 1 from public.deadline_occurrence_completions c where c.deadline_id = p_deadline_id) then
    raise exception 'Non puoi modificare data base o ricorrenza dopo una conferma: termina la serie e crea una nuova scadenza';
  end if;
  perform public.assert_my_deadline_family_member(v_profile_id, p_family_member_id);
  update public.deadlines
  set title = btrim(p_title), category = p_category,
      reference = nullif(btrim(coalesce(p_reference, '')), ''),
      family_member_id = p_family_member_id, first_due_on = p_first_due_on,
      recurrence_months = p_recurrence_months, reminder_days = p_reminder_days,
      notes = p_notes
  where id = p_deadline_id and owner_profile_id = v_profile_id;
end;
$$;

create function public.terminate_my_deadline(
  p_deadline_id uuid,
  p_terminated_on date default current_date
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid; v_first_due_on date;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select d.first_due_on into v_first_due_on from public.deadlines d
  where d.id = p_deadline_id and d.owner_profile_id = v_profile_id and d.status = 'active'
  for update;
  if not found then raise exception 'Scadenza non trovata, gia'' terminata o non accessibile'; end if;
  if p_terminated_on is null or p_terminated_on < v_first_due_on then
    raise exception 'La data di terminazione non puo'' precedere la prima scadenza';
  end if;
  update public.deadlines set status = 'terminated', terminated_on = p_terminated_on
  where id = p_deadline_id and owner_profile_id = v_profile_id;
end;
$$;

create function public.delete_my_deadline(p_deadline_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  delete from public.deadlines where id = p_deadline_id and owner_profile_id = v_profile_id;
  if not found then raise exception 'Scadenza non trovata o non accessibile'; end if;
end;
$$;

create function public.get_my_deadline_occurrences(p_from date, p_to date)
returns table(
  deadline_id uuid, title text, category text, reference text, family_member_id uuid,
  occurrence_on date, reminder_days smallint, status text, is_completed boolean,
  completed_at timestamptz, notes text, occurrence_state text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'Intervallo occorrenze non valido'; end if;
  if p_to > p_from + 1826 then raise exception 'Intervallo occorrenze troppo ampio'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query
  select d.id, d.title, d.category, d.reference, d.family_member_id,
    o.occurrence_on, d.reminder_days, d.status, c.deadline_id is not null,
    c.completed_at, d.notes,
    case when c.deadline_id is not null then 'completed'
      when o.occurrence_on < current_date then 'overdue'
      when o.occurrence_on = current_date then 'today'
      else 'upcoming' end
  from public.deadlines d
  cross join lateral public.deadline_occurrence_dates(
    d.first_due_on, d.recurrence_months, d.terminated_on, p_from, p_to
  ) o
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
  where d.owner_profile_id = v_profile_id
  order by o.occurrence_on, d.created_at, d.id;
end;
$$;

create function public.set_my_deadline_occurrence_completed(
  p_deadline_id uuid,
  p_occurrence_on date,
  p_completed boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_first_due_on date;
  v_recurrence_months smallint;
  v_terminated_on date;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  if p_occurrence_on is null then raise exception 'Data occorrenza obbligatoria'; end if;
  if p_completed is null then raise exception 'Stato completamento non valido'; end if;
  if p_occurrence_on > current_date then raise exception 'Non puoi confermare una scadenza futura'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select d.first_due_on, d.recurrence_months, d.terminated_on
    into v_first_due_on, v_recurrence_months, v_terminated_on
  from public.deadlines d
  where d.id = p_deadline_id and d.owner_profile_id = v_profile_id
  for update;
  if not found then raise exception 'Scadenza non trovata o non accessibile'; end if;
  if not exists (
    select 1 from public.deadline_occurrence_dates(
      v_first_due_on, v_recurrence_months, v_terminated_on, p_occurrence_on, p_occurrence_on
    )
  ) then
    raise exception 'La data indicata non corrisponde a un''occorrenza della scadenza';
  end if;
  if p_completed then
    insert into public.deadline_occurrence_completions (
      deadline_id, occurrence_on, completed_at, completed_by_profile_id
    ) values (p_deadline_id, p_occurrence_on, now(), v_profile_id)
    on conflict (deadline_id, occurrence_on) do update
      set completed_at = excluded.completed_at,
          completed_by_profile_id = excluded.completed_by_profile_id;
  else
    delete from public.deadline_occurrence_completions
    where deadline_id = p_deadline_id and occurrence_on = p_occurrence_on;
  end if;
end;
$$;

create function public.get_my_deadline_alerts(p_until date)
returns table(
  deadline_id uuid, title text, category text, reference text, family_member_id uuid,
  occurrence_on date, reminder_days smallint, notes text, occurrence_state text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  if p_until is null or p_until < current_date then raise exception 'Intervallo avvisi non valido'; end if;
  if p_until > current_date + 1826 then raise exception 'Intervallo avvisi troppo ampio'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query
  select d.id, d.title, d.category, d.reference, d.family_member_id,
    o.occurrence_on, d.reminder_days, d.notes,
    case when o.occurrence_on < current_date then 'overdue'
      when o.occurrence_on = current_date then 'today'
      else 'upcoming' end
  from public.deadlines d
  cross join lateral public.deadline_occurrence_dates(
    d.first_due_on, d.recurrence_months, null, d.first_due_on, p_until
  ) o
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
  where d.owner_profile_id = v_profile_id
    and d.status = 'active'
    and c.deadline_id is null
    and current_date >= o.occurrence_on - d.reminder_days
  order by o.occurrence_on, d.created_at, d.id;
end;
$$;

alter table public.deadlines owner to postgres;
alter table public.deadline_occurrence_completions owner to postgres;
alter function public.set_deadline_updated_at() owner to postgres;
alter function public.deadline_occurrence_dates(date, smallint, date, date, date) owner to postgres;
alter function public.assert_my_deadline_family_member(uuid, uuid) owner to postgres;
alter function public.get_my_deadlines(text) owner to postgres;
alter function public.get_my_deadline(uuid) owner to postgres;
alter function public.create_my_deadline(text, text, date, text, uuid, smallint, smallint, text) owner to postgres;
alter function public.update_my_deadline(uuid, text, text, date, text, uuid, smallint, smallint, text) owner to postgres;
alter function public.terminate_my_deadline(uuid, date) owner to postgres;
alter function public.delete_my_deadline(uuid) owner to postgres;
alter function public.get_my_deadline_occurrences(date, date) owner to postgres;
alter function public.set_my_deadline_occurrence_completed(uuid, date, boolean) owner to postgres;
alter function public.get_my_deadline_alerts(date) owner to postgres;

revoke all on function public.set_deadline_updated_at() from public, anon, authenticated;
revoke all on function public.deadline_occurrence_dates(date, smallint, date, date, date) from public, anon, authenticated;
revoke all on function public.assert_my_deadline_family_member(uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_my_deadlines(text) from public, anon;
revoke all on function public.get_my_deadline(uuid) from public, anon;
revoke all on function public.create_my_deadline(text, text, date, text, uuid, smallint, smallint, text) from public, anon;
revoke all on function public.update_my_deadline(uuid, text, text, date, text, uuid, smallint, smallint, text) from public, anon;
revoke all on function public.terminate_my_deadline(uuid, date) from public, anon;
revoke all on function public.delete_my_deadline(uuid) from public, anon;
revoke all on function public.get_my_deadline_occurrences(date, date) from public, anon;
revoke all on function public.set_my_deadline_occurrence_completed(uuid, date, boolean) from public, anon;
revoke all on function public.get_my_deadline_alerts(date) from public, anon;

grant execute on function public.get_my_deadlines(text) to authenticated;
grant execute on function public.get_my_deadline(uuid) to authenticated;
grant execute on function public.create_my_deadline(text, text, date, text, uuid, smallint, smallint, text) to authenticated;
grant execute on function public.update_my_deadline(uuid, text, text, date, text, uuid, smallint, smallint, text) to authenticated;
grant execute on function public.terminate_my_deadline(uuid, date) to authenticated;
grant execute on function public.delete_my_deadline(uuid) to authenticated;
grant execute on function public.get_my_deadline_occurrences(date, date) to authenticated;
grant execute on function public.set_my_deadline_occurrence_completed(uuid, date, boolean) to authenticated;
grant execute on function public.get_my_deadline_alerts(date) to authenticated;

commit;
