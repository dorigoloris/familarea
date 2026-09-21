begin;

-- FamilArea — Proposte private per future categorie degli Interessi.
create table public.interest_category_proposals (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  proposed_name text not null check (
    proposed_name = btrim(proposed_name)
    and char_length(proposed_name) between 1 and 100
  ),
  normalized_name text not null check (
    normalized_name = btrim(normalized_name)
    and char_length(normalized_name) between 1 and 100
  ),
  note text check (
    note is null or (note = btrim(note) and char_length(note) between 1 and 500)
  ),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'archived')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  constraint interest_category_proposals_review_state_check check (
    (status = 'pending') = (reviewed_at is null)
  ),
  unique (profile_id, normalized_name)
);

create index interest_category_proposals_pending_idx
  on public.interest_category_proposals(created_at, id)
  where status = 'pending';

alter table public.interest_category_proposals enable row level security;
alter table public.interest_category_proposals no force row level security;
revoke all on public.interest_category_proposals from public, anon, authenticated;

create function public.submit_my_interest_category_proposal(
  p_proposed_name text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_proposed_name text := btrim(coalesce(p_proposed_name, ''));
  v_normalized_name text;
  v_note text := nullif(btrim(p_note), '');
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;

  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();
  if v_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  if v_proposed_name = '' or char_length(v_proposed_name) > 100 then
    raise exception 'Nome categoria non valido';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'Nota non valida';
  end if;

  v_normalized_name := public.normalize_interest_name(v_proposed_name);
  if v_normalized_name is null or char_length(v_normalized_name) > 100 then
    raise exception 'Nome categoria non valido';
  end if;

  insert into public.interest_category_proposals (
    profile_id, proposed_name, normalized_name, note
  ) values (
    v_profile_id, v_proposed_name, v_normalized_name, v_note
  ) on conflict (profile_id, normalized_name) do nothing;
end;
$$;

alter table public.interest_category_proposals owner to postgres;
alter function public.submit_my_interest_category_proposal(text, text) owner to postgres;

revoke all on function public.submit_my_interest_category_proposal(text, text) from public, anon;
grant execute on function public.submit_my_interest_category_proposal(text, text) to authenticated;

commit;
