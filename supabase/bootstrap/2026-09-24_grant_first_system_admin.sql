-- Bootstrap MANUALE del primo System Admin.
-- Eseguire solo DOPO la migration 2026-09-24_system_admin_mvp.sql.
-- Non è una migration automatica e non deve essere eseguita dal frontend.

begin;

do $$
declare
  v_email text := lower(btrim('dorigoloris@gmail.com'));
  v_account_id uuid;
  v_matches integer;
begin
  select count(*) into v_matches
  from auth.users u
  join public.accounts a on a.auth_user_id = u.id
  where lower(btrim(u.email)) = v_email
    and u.email_confirmed_at is not null;

  if v_matches <> 1 then
    raise exception 'expected exactly one confirmed FamilArea account for bootstrap email';
  end if;

  select a.id into v_account_id
  from auth.users u
  join public.accounts a on a.auth_user_id = u.id
  where lower(btrim(u.email)) = v_email
    and u.email_confirmed_at is not null;

  insert into public.system_admins(account_id)
  values (v_account_id)
  on conflict (account_id) do nothing;
end;
$$;

commit;
