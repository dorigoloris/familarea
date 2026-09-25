-- FamilArea — V1 amministrazione catalogo Interessi, senza delete fisico.
begin;

alter table public.interest_categories
  add column if not exists status text not null default 'active';

alter table public.interest_category_proposals
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by_account_id uuid references public.accounts(id) on delete set null,
  add column if not exists review_note text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'interest_categories_status_v1_check') then
    alter table public.interest_categories add constraint interest_categories_status_v1_check check (status in ('active','inactive'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'interest_category_proposals_status_v1_check') then
    alter table public.interest_category_proposals add constraint interest_category_proposals_status_v1_check check (status in ('pending','approved','rejected'));
  end if;
end $$;

create or replace function public.get_interest_catalog()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('category_id',c.id,'category_name',c.name,'interest_id',i.id,'display_name',i.display_name)
  from public.interest_categories c join public.interests i on i.category_id=c.id
  where c.status='active' and i.origin='catalog' and i.publication_status='published' and i.status='active'
  order by c.name,i.display_name
$$;

create or replace function public.get_my_interests()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('interest_id',i.id,'category_id',i.category_id,'category_name',c.name,'display_name',i.display_name)
  from public.profile_interests pi join public.interests i on i.id=pi.interest_id
  join public.interest_categories c on c.id=i.category_id
  where pi.profile_id=public.require_personal_profile() and c.status='active' and i.status='active'
  order by c.name,i.display_name
$$;

create or replace function public.add_my_interest(p_category_id uuid,p_display_name text)
returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid:=public.require_personal_profile(); v_normalized text:=public.normalize_interest_name(p_display_name); v_interest uuid;
begin
  if v_normalized='' or not exists(select 1 from public.interest_categories where id=p_category_id and status='active') then raise exception 'invalid interest'; end if;
  perform pg_advisory_xact_lock(hashtext(v_normalized));
  select id into v_interest from public.interests where normalized_name=v_normalized;
  if v_interest is null then
    insert into public.interests(category_id,display_name,normalized_name,origin,publication_status,created_by_profile_id)
    values(p_category_id,btrim(p_display_name),v_normalized,'personal','private',v_profile) returning id into v_interest;
  end if;
  if not exists(select 1 from public.interests where id=v_interest and status='active') then raise exception 'interest unavailable'; end if;
  insert into public.profile_interests(profile_id,interest_id) values(v_profile,v_interest) on conflict do nothing;
  return v_interest;
end $$;

create or replace function public.submit_my_interest_category_proposal(p_proposed_name text,p_note text default null)
returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_profile uuid:=public.require_personal_profile(); v_normalized text:=public.normalize_interest_name(p_proposed_name);
begin
  if v_normalized='' or length(v_normalized)>100 or length(coalesce(p_note,''))>500 then raise exception 'invalid proposal'; end if;
  if exists(select 1 from public.interest_categories where normalized_name=v_normalized) then raise exception 'category already exists'; end if;
  insert into public.interest_category_proposals(profile_id,proposed_name,normalized_name,note)
  values(v_profile,btrim(p_proposed_name),v_normalized,nullif(btrim(p_note),''))
  on conflict(profile_id,normalized_name) do nothing;
end $$;

create or replace function public.admin_list_interest_categories()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('id',c.id,'name',c.name,'normalized_name',c.normalized_name,'status',c.status,
    'interest_count',(select count(*) from public.interests i where i.category_id=c.id),
    'active_interest_count',(select count(*) from public.interests i where i.category_id=c.id and i.status='active'),
    'created_at',c.created_at,'updated_at',c.updated_at)
  from public.interest_categories c cross join lateral (select public.require_system_admin()) guard
  order by c.name
$$;

create or replace function public.admin_update_interest_category(p_category_id uuid,p_name text,p_status text)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_name text:=btrim(coalesce(p_name,'')); v_normalized text:=public.normalize_interest_name(p_name); v_result jsonb;
begin
  perform public.require_system_admin();
  if p_status not in ('active','inactive') then raise exception 'invalid category status'; end if;
  if v_normalized='' or length(v_name)>100 then raise exception 'invalid category name'; end if;
  update public.interest_categories set name=v_name,normalized_name=v_normalized,status=p_status,updated_at=now()
  where id=p_category_id returning jsonb_build_object('id',id,'name',name,'status',status) into v_result;
  if v_result is null then raise exception 'category not found'; end if;
  return v_result;
end $$;

create or replace function public.admin_list_interests()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('id',i.id,'display_name',i.display_name,'normalized_name',i.normalized_name,
    'status',i.status,'origin',i.origin,'publication_status',i.publication_status,
    'category_id',c.id,'category_name',c.name,'category_status',c.status,
    'created_by_profile_id',i.created_by_profile_id,
    'created_by_name',nullif(concat_ws(' ',p.first_name,p.last_name),''),
    'user_count',(select count(*) from public.profile_interests pi where pi.interest_id=i.id),
    'created_at',i.created_at,'updated_at',i.updated_at)
  from public.interests i join public.interest_categories c on c.id=i.category_id
  left join public.profiles p on p.id=i.created_by_profile_id
  cross join lateral (select public.require_system_admin()) guard
  order by c.name,i.display_name
$$;

create or replace function public.admin_update_interest(p_interest_id uuid,p_display_name text,p_status text)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_name text:=btrim(coalesce(p_display_name,'')); v_normalized text:=public.normalize_interest_name(p_display_name); v_result jsonb;
begin
  perform public.require_system_admin();
  if p_status not in ('active','inactive') then raise exception 'invalid interest status'; end if;
  if v_normalized='' or length(v_name)>120 then raise exception 'invalid interest name'; end if;
  update public.interests set display_name=v_name,normalized_name=v_normalized,status=p_status,updated_at=now()
  where id=p_interest_id returning jsonb_build_object('id',id,'display_name',display_name,'status',status) into v_result;
  if v_result is null then raise exception 'interest not found'; end if;
  return v_result;
end $$;

create or replace function public.admin_list_interest_category_proposals()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('id',p.id,'proposed_name',p.proposed_name,'normalized_name',p.normalized_name,'note',p.note,
    'status',p.status,'profile_id',p.profile_id,'proposer_name',nullif(concat_ws(' ',pr.first_name,pr.last_name),''),
    'created_at',p.created_at,'reviewed_at',p.reviewed_at,'reviewed_by_account_id',p.reviewed_by_account_id,
    'review_note',p.review_note,'reviewer_name',coalesce(nullif(concat_ws(' ',reviewer.first_name,reviewer.last_name),''),org.name))
  from public.interest_category_proposals p left join public.profiles pr on pr.id=p.profile_id
  left join public.profiles reviewer on reviewer.account_id=p.reviewed_by_account_id
  left join public.organizations org on org.account_id=p.reviewed_by_account_id
  cross join lateral (select public.require_system_admin()) guard
  order by case when p.status='pending' then 0 else 1 end,p.created_at desc
$$;

create or replace function public.admin_review_interest_category_proposal(p_proposal_id uuid,p_action text,p_category_name text default null,p_review_note text default null)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_admin uuid:=public.require_system_admin(); v_proposal public.interest_category_proposals%rowtype; v_name text; v_normalized text; v_category_id uuid;
begin
  select * into v_proposal from public.interest_category_proposals where id=p_proposal_id for update;
  if not found then raise exception 'proposal not found'; end if;
  if v_proposal.status<>'pending' then raise exception 'proposal already reviewed'; end if;
  if p_action not in ('approved','rejected') then raise exception 'invalid proposal action'; end if;
  if length(coalesce(p_review_note,''))>500 then raise exception 'invalid review note'; end if;
  if p_action='approved' then
    v_name:=btrim(coalesce(nullif(p_category_name,''),v_proposal.proposed_name)); v_normalized:=public.normalize_interest_name(v_name);
    if v_normalized='' or length(v_name)>100 then raise exception 'invalid category name'; end if;
    insert into public.interest_categories(name,normalized_name,status) values(v_name,v_normalized,'active')
    on conflict(normalized_name) do update set name=excluded.name,status='active',updated_at=now()
    returning id into v_category_id;
  end if;
  update public.interest_category_proposals
  set status=p_action,reviewed_at=now(),reviewed_by_account_id=v_admin,review_note=nullif(btrim(p_review_note),'')
  where id=p_proposal_id;
  return jsonb_build_object('proposal_id',p_proposal_id,'status',p_action,'category_id',v_category_id);
end $$;

alter function public.get_interest_catalog() owner to postgres;
alter function public.get_my_interests() owner to postgres;
alter function public.add_my_interest(uuid,text) owner to postgres;
alter function public.submit_my_interest_category_proposal(text,text) owner to postgres;
alter function public.admin_list_interest_categories() owner to postgres;
alter function public.admin_update_interest_category(uuid,text,text) owner to postgres;
alter function public.admin_list_interests() owner to postgres;
alter function public.admin_update_interest(uuid,text,text) owner to postgres;
alter function public.admin_list_interest_category_proposals() owner to postgres;
alter function public.admin_review_interest_category_proposal(uuid,text,text,text) owner to postgres;

revoke all on function public.admin_list_interest_categories(),public.admin_update_interest_category(uuid,text,text),
  public.admin_list_interests(),public.admin_update_interest(uuid,text,text),public.admin_list_interest_category_proposals(),
  public.admin_review_interest_category_proposal(uuid,text,text,text) from public,anon;
grant execute on function public.admin_list_interest_categories(),public.admin_update_interest_category(uuid,text,text),
  public.admin_list_interests(),public.admin_update_interest(uuid,text,text),public.admin_list_interest_category_proposals(),
  public.admin_review_interest_category_proposal(uuid,text,text,text) to authenticated;

commit;
