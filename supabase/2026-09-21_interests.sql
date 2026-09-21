begin;

-- FamilArea — Interessi V1. Catalogo curato, termini canonici privati e selezioni personali.
create table public.interest_categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug = lower(btrim(slug)) and slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  name text not null check (name = btrim(name) and char_length(name) between 1 and 80),
  sort_order smallint not null default 0 check (sort_order >= 0),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.interests (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.interest_categories(id) on delete restrict,
  display_name text not null check (display_name = btrim(display_name) and char_length(display_name) between 1 and 120),
  normalized_name text not null unique check (normalized_name = btrim(normalized_name) and char_length(normalized_name) between 1 and 120),
  sort_order smallint not null default 0 check (sort_order >= 0),
  origin text not null check (origin in ('catalog', 'user')),
  publication_status text not null check (publication_status in ('private', 'published', 'retired')),
  status text not null default 'active' check (status in ('active', 'inactive', 'merged')),
  created_by_profile_id uuid references public.profiles(id) on delete set null,
  merged_into_interest_id uuid references public.interests(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint interests_catalog_provenance_check check (
    origin <> 'catalog' or (created_by_profile_id is null and publication_status in ('published', 'retired'))
  ),
  constraint interests_private_is_user_origin_check check (
    publication_status <> 'private' or origin = 'user'
  ),
  constraint interests_merge_state_check check (
    (status = 'merged') = (merged_into_interest_id is not null)
  ),
  constraint interests_merge_target_not_self_check check (
    merged_into_interest_id is null or merged_into_interest_id <> id
  )
);

create table public.profile_interests (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  interest_id uuid not null references public.interests(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (profile_id, interest_id)
);

create index interests_catalog_list_idx
  on public.interests(category_id, sort_order, display_name, id)
  where status = 'active' and publication_status = 'published';
create index profile_interests_profile_idx
  on public.profile_interests(profile_id, created_at, interest_id);

create function public.normalize_interest_name(p_name text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select nullif(
    regexp_replace(lower(btrim(p_name)), '[-[:space:]]+', ' ', 'g'),
    ''
  );
$$;

create function public.set_interest_category_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create function public.set_interest_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger interest_categories_set_updated_at
  before update on public.interest_categories
  for each row execute function public.set_interest_category_updated_at();
create trigger interests_set_updated_at
  before update on public.interests
  for each row execute function public.set_interest_updated_at();

insert into public.interest_categories (slug, name, sort_order, status)
values
  ('sport', 'Sport', 1, 'active'),
  ('natura-e-outdoor', 'Natura e outdoor', 2, 'active'),
  ('cultura-e-spettacolo', 'Cultura e spettacolo', 3, 'active'),
  ('cucina-e-gastronomia', 'Cucina e gastronomia', 4, 'active'),
  ('creativita-e-hobby', 'Creatività e hobby', 5, 'active'),
  ('viaggi-e-tempo-libero', 'Viaggi e tempo libero', 6, 'active')
on conflict (slug) do update set
  name = excluded.name,
  sort_order = excluded.sort_order,
  status = excluded.status;

with seed(category_slug, display_name, sort_order) as (
  values
    ('sport', 'Calcio', 1), ('sport', 'Padel', 2), ('sport', 'Tennis', 3), ('sport', 'Ciclismo', 4), ('sport', 'Running', 5),
    ('natura-e-outdoor', 'Trekking', 1), ('natura-e-outdoor', 'Campeggio', 2), ('natura-e-outdoor', 'Sci alpino', 3), ('natura-e-outdoor', 'Giardinaggio', 4), ('natura-e-outdoor', 'Pesca', 5),
    ('cultura-e-spettacolo', 'Cinema', 1), ('cultura-e-spettacolo', 'Teatro', 2), ('cultura-e-spettacolo', 'Concerti', 3), ('cultura-e-spettacolo', 'Musei', 4), ('cultura-e-spettacolo', 'Lettura', 5),
    ('cucina-e-gastronomia', 'Cucina', 1), ('cucina-e-gastronomia', 'Pasticceria', 2), ('cucina-e-gastronomia', 'Enogastronomia', 3), ('cucina-e-gastronomia', 'Degustazioni', 4), ('cucina-e-gastronomia', 'Ristorazione', 5),
    ('creativita-e-hobby', 'Pittura', 1), ('creativita-e-hobby', 'Fotografia', 2), ('creativita-e-hobby', 'Ceramica', 3), ('creativita-e-hobby', 'Artigianato', 4), ('creativita-e-hobby', 'Giochi di carte', 5),
    ('viaggi-e-tempo-libero', 'Viaggi', 1), ('viaggi-e-tempo-libero', 'Gite', 2), ('viaggi-e-tempo-libero', 'Borghi', 3), ('viaggi-e-tempo-libero', 'Sagre', 4), ('viaggi-e-tempo-libero', 'Ballo', 5)
)
insert into public.interests (
  category_id, display_name, normalized_name, sort_order,
  origin, publication_status, status, created_by_profile_id
)
select c.id, s.display_name, public.normalize_interest_name(s.display_name), s.sort_order,
  'catalog', 'published', 'active', null
from seed s
join public.interest_categories c on c.slug = s.category_slug
on conflict (normalized_name) do nothing;

alter table public.interest_categories enable row level security;
alter table public.interests enable row level security;
alter table public.profile_interests enable row level security;
alter table public.interest_categories no force row level security;
alter table public.interests no force row level security;
alter table public.profile_interests no force row level security;
revoke all on public.interest_categories, public.interests, public.profile_interests from public, anon, authenticated;

create function public.get_interest_catalog()
returns table(
  category_id uuid,
  category_slug text,
  category_name text,
  category_sort_order smallint,
  interest_id uuid,
  display_name text,
  interest_sort_order smallint
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  return query
  select c.id, c.slug, c.name, c.sort_order, i.id, i.display_name, i.sort_order
  from public.interest_categories c
  join public.interests i on i.category_id = c.id
  where c.status = 'active'
    and i.status = 'active'
    and i.publication_status = 'published'
  order by c.sort_order, c.name, i.sort_order, i.display_name, i.id;
end;
$$;

create function public.get_my_interests()
returns table(
  interest_id uuid,
  category_id uuid,
  category_slug text,
  category_name text,
  display_name text,
  is_catalog boolean,
  selected_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  return query
  select i.id, c.id, c.slug, c.name, i.display_name,
    i.publication_status = 'published', pi.created_at
  from public.profile_interests pi
  join public.interests i on i.id = pi.interest_id
  join public.interest_categories c on c.id = i.category_id
  where pi.profile_id = v_profile_id
  order by c.sort_order, c.name, i.sort_order, i.display_name, i.id;
end;
$$;

create function public.add_my_interest(p_category_id uuid, p_display_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_category_id uuid;
  v_display_name text := btrim(coalesce(p_display_name, ''));
  v_normalized_name text;
  v_interest_id uuid;
  v_status text;
  v_merged_into_interest_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  select c.id into v_category_id from public.interest_categories c
  where c.id = p_category_id and c.status = 'active';
  if v_category_id is null then raise exception 'Categoria non disponibile'; end if;
  if v_display_name = '' or char_length(v_display_name) > 120 then raise exception 'Nome interesse non valido'; end if;
  v_normalized_name := public.normalize_interest_name(v_display_name);
  if v_normalized_name is null or char_length(v_normalized_name) > 120 then raise exception 'Nome interesse non valido'; end if;

  -- Serializza la risoluzione dello stesso termine normalizzato e previene race UNIQUE.
  perform pg_advisory_xact_lock(hashtextextended(v_normalized_name, 0));
  select i.id, i.status, i.merged_into_interest_id
    into v_interest_id, v_status, v_merged_into_interest_id
  from public.interests i
  where i.normalized_name = v_normalized_name
  for update;

  if found and v_status = 'merged' then
    select i.id, i.status into v_interest_id, v_status
    from public.interests i
    where i.id = v_merged_into_interest_id
    for update;
  end if;
  if found and v_status <> 'active' then raise exception 'Interesse non disponibile'; end if;

  if v_interest_id is null then
    insert into public.interests (
      category_id, display_name, normalized_name, origin,
      publication_status, status, created_by_profile_id
    ) values (
      v_category_id, v_display_name, v_normalized_name, 'user',
      'private', 'active', v_profile_id
    ) returning id into v_interest_id;
  end if;

  insert into public.profile_interests (profile_id, interest_id)
  values (v_profile_id, v_interest_id)
  on conflict (profile_id, interest_id) do nothing;
  return v_interest_id;
end;
$$;

create function public.remove_my_interest(p_interest_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  if p_interest_id is null then raise exception 'Interesse non valido'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  delete from public.profile_interests
  where profile_id = v_profile_id and interest_id = p_interest_id;
end;
$$;

alter table public.interest_categories owner to postgres;
alter table public.interests owner to postgres;
alter table public.profile_interests owner to postgres;
alter function public.normalize_interest_name(text) owner to postgres;
alter function public.set_interest_category_updated_at() owner to postgres;
alter function public.set_interest_updated_at() owner to postgres;
alter function public.get_interest_catalog() owner to postgres;
alter function public.get_my_interests() owner to postgres;
alter function public.add_my_interest(uuid, text) owner to postgres;
alter function public.remove_my_interest(uuid) owner to postgres;

revoke all on function public.normalize_interest_name(text) from public, anon, authenticated;
revoke all on function public.set_interest_category_updated_at() from public, anon, authenticated;
revoke all on function public.set_interest_updated_at() from public, anon, authenticated;
revoke all on function public.get_interest_catalog() from public, anon;
revoke all on function public.get_my_interests() from public, anon;
revoke all on function public.add_my_interest(uuid, text) from public, anon;
revoke all on function public.remove_my_interest(uuid) from public, anon;
grant execute on function public.get_interest_catalog() to authenticated;
grant execute on function public.get_my_interests() to authenticated;
grant execute on function public.add_my_interest(uuid, text) to authenticated;
grant execute on function public.remove_my_interest(uuid) to authenticated;

commit;
