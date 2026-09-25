-- FamilArea — mostra categorie attive anche senza interessi pubblicati.
create or replace function public.get_interest_catalog()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('category_id',c.id,'category_name',c.name,'interest_id',i.id,'display_name',i.display_name)
  from public.interest_categories c
  left join public.interests i on i.category_id=c.id
    and i.origin='catalog' and i.publication_status='published' and i.status='active'
  where c.status='active'
  order by c.name,i.display_name nulls last
$$;

alter function public.get_interest_catalog() owner to postgres;
