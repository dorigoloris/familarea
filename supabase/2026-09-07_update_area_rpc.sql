-- FamilArea — RPC sicura per modificare il nome e il tipo di un'Area.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create function public.update_area(
  p_area_id uuid,
  p_name text,
  p_area_type text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  if not exists (
    select 1
    from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'permission denied: solo un admin dell''Area puÃ² modificare l''Area';
  end if;

  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'Il nome dell''Area Ã¨ obbligatorio';
  end if;

  if p_area_type not in ('family', 'school', 'sport', 'friends', 'course', 'travel', 'other') then
    raise exception 'Tipo Area non valido: %', p_area_type;
  end if;

  update public.areas
  set name = btrim(p_name),
      area_type = p_area_type
  where id = p_area_id;

  if not found then
    raise exception 'Area non trovata';
  end if;
end;
$$;

revoke all on function public.update_area(uuid, text, text) from public;
grant execute on function public.update_area(uuid, text, text) to authenticated;

commit;
