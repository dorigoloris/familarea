begin;

-- FamilArea — Creazione profilo compatibile con metadata email/password e OAuth.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_first_name text;
  v_last_name text;
  v_full_name text;
begin
  v_first_name := nullif(btrim(new.raw_user_meta_data ->> 'first_name'), '');
  if v_first_name is null then
    v_first_name := nullif(btrim(new.raw_user_meta_data ->> 'given_name'), '');
  end if;
  if v_first_name is null then
    v_full_name := coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'name'), '')
    );
    v_first_name := nullif(split_part(coalesce(v_full_name, ''), ' ', 1), '');
  end if;

  v_last_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'last_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'family_name'), ''),
    ''
  );

  insert into public.profiles (user_id, first_name, last_name)
  values (new.id, coalesce(v_first_name, ''), v_last_name);
  return new;
end;
$$;

comment on function public.handle_new_user() is
  'Trigger su auth.users: crea il profilo pubblico con metadata FamilArea o OAuth, senza importare avatar o token.';

alter function public.handle_new_user() owner to postgres;
revoke all on function public.handle_new_user() from public;

commit;
