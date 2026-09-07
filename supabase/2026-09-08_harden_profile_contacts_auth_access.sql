-- FamilArea: i recapiti contestuali legacy appartengono solo ai profili managed.

create or replace function public.get_area_member_contacts(p_area_id uuid, p_profile_id uuid)
returns table (id uuid, contact_type text, contact_value text, is_primary boolean, created_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_target_user_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then
    raise exception 'permission denied: solo un admin dell''Area puo'' gestire i contatti';
  end if;
  select p.user_id into v_target_user_id from public.area_memberships am join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id and am.profile_id = p_profile_id;
  if not found then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  return query select pc.id, pc.contact_type, pc.contact_value, pc.is_primary, pc.created_at
  from public.profile_contacts pc where pc.area_id = p_area_id and pc.profile_id = p_profile_id
  order by pc.contact_type, pc.is_primary desc, pc.created_at, pc.id;
end;
$$;

create or replace function public.add_area_member_contact(p_area_id uuid, p_profile_id uuid, p_contact_type text, p_contact_value text, p_is_primary boolean default false)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_target_user_id uuid; v_contact_type text := lower(btrim(p_contact_type)); v_contact_value text; v_is_primary boolean; v_existing_count integer; v_contact_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then raise exception 'permission denied: solo un admin dell''Area puo'' gestire i contatti'; end if;
  select p.user_id into v_target_user_id from public.area_memberships am join public.profiles p on p.id = am.profile_id where am.area_id = p_area_id and am.profile_id = p_profile_id;
  if not found then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  if v_contact_type is null or v_contact_type not in ('email', 'phone') then raise exception 'Tipo di contatto non valido'; end if;
  v_contact_value := case when v_contact_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_contact_value, '') = '' then raise exception 'Il valore del contatto e'' obbligatorio'; end if;
  if v_contact_type = 'phone' and v_contact_value !~ '^\+[1-9][0-9]{1,14}$' then raise exception 'Il telefono deve essere nel formato internazionale E.164'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select count(*) into v_existing_count from public.profile_contacts where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type;
  v_is_primary := v_existing_count = 0 or coalesce(p_is_primary, false);
  if v_is_primary then update public.profile_contacts set is_primary = false where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type; end if;
  insert into public.profile_contacts (area_id, profile_id, contact_type, contact_value, is_primary) values (p_area_id, p_profile_id, v_contact_type, v_contact_value, v_is_primary) returning id into v_contact_id;
  return v_contact_id;
end;
$$;

create or replace function public.update_area_member_contact(p_area_id uuid, p_profile_id uuid, p_contact_id uuid, p_contact_value text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_target_user_id uuid; v_contact_type text; v_contact_value text;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then raise exception 'permission denied: solo un admin dell''Area puo'' gestire i contatti'; end if;
  select p.user_id into v_target_user_id from public.area_memberships am join public.profiles p on p.id = am.profile_id where am.area_id = p_area_id and am.profile_id = p_profile_id;
  if not found then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type into v_contact_type from public.profile_contacts where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_contact_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  v_contact_value := case when v_contact_type = 'email' then lower(btrim(p_contact_value)) else btrim(p_contact_value) end;
  if coalesce(v_contact_value, '') = '' then raise exception 'Il valore del contatto e'' obbligatorio'; end if;
  if v_contact_type = 'phone' and v_contact_value !~ '^\+[1-9][0-9]{1,14}$' then raise exception 'Il telefono deve essere nel formato internazionale E.164'; end if;
  update public.profile_contacts set contact_value = v_contact_value where id = p_contact_id;
end;
$$;

create or replace function public.set_area_member_contact_primary(p_area_id uuid, p_profile_id uuid, p_contact_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_target_user_id uuid; v_contact_type text;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then raise exception 'permission denied: solo un admin dell''Area puo'' gestire i contatti'; end if;
  select p.user_id into v_target_user_id from public.area_memberships am join public.profiles p on p.id = am.profile_id where am.area_id = p_area_id and am.profile_id = p_profile_id;
  if not found then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type into v_contact_type from public.profile_contacts where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_contact_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  update public.profile_contacts set is_primary = false where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type;
  update public.profile_contacts set is_primary = true where id = p_contact_id;
end;
$$;

create or replace function public.delete_area_member_contact(p_area_id uuid, p_profile_id uuid, p_contact_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_caller_profile_id uuid; v_target_user_id uuid; v_contact_type text; v_was_primary boolean; v_replacement_id uuid;
begin
  select id into v_caller_profile_id from public.profiles where user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if not exists (select 1 from public.area_memberships where area_id = p_area_id and profile_id = v_caller_profile_id and role = 'admin') then raise exception 'permission denied: solo un admin dell''Area puo'' gestire i contatti'; end if;
  select p.user_id into v_target_user_id from public.area_memberships am join public.profiles p on p.id = am.profile_id where am.area_id = p_area_id and am.profile_id = p_profile_id;
  if not found then raise exception 'permission denied: il profilo indicato non appartiene a questa Area'; end if;
  if v_target_user_id is not null then raise exception 'Impossibile gestire recapiti di un profilo collegato a un account utente'; end if;
  perform 1 from public.profiles where id = p_profile_id for update;
  select contact_type, is_primary into v_contact_type, v_was_primary from public.profile_contacts where id = p_contact_id and area_id = p_area_id and profile_id = p_profile_id;
  if v_contact_type is null then raise exception 'Contatto non trovato per il profilo e l''Area indicati'; end if;
  delete from public.profile_contacts where id = p_contact_id;
  if v_was_primary then
    select id into v_replacement_id from public.profile_contacts where area_id = p_area_id and profile_id = p_profile_id and contact_type = v_contact_type order by created_at, id limit 1;
    if v_replacement_id is not null then update public.profile_contacts set is_primary = true where id = v_replacement_id; end if;
  end if;
end;
$$;

-- Nel link T -> A i recapiti contestuali dell'Area dell'invito non diventano
-- recapiti dell'account Auth. La funzione completa mantiene invariati gli altri flussi.
create or replace function public.accept_area_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_caller_profile_id uuid; v_email text; v_area_id uuid; v_recipient_email text; v_status text; v_expires_at timestamptz; v_accepted_by_profile_id uuid; v_target_profile_id uuid; v_target_role text; v_target_user_id uuid; v_caller_membership_role text; v_locked_profile_id uuid; v_locked_profile_count integer := 0;
begin
  select p.id, lower(btrim(u.email)) into v_caller_profile_id, v_email from auth.users u join public.profiles p on p.user_id = u.id where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_caller_profile_id is null or v_email is null then raise exception 'Email dell''account non verificata o profilo non trovato'; end if;
  select ai.area_id into v_area_id from public.area_invites ai where ai.id = p_invite_id;
  if v_area_id is null then raise exception 'Invito non trovato'; end if;
  perform 1 from public.areas where id = v_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;
  update public.area_invites set status = 'expired' where id = p_invite_id and area_id = v_area_id and status = 'pending' and expires_at <= now();
  select ai.recipient_email, ai.status, ai.expires_at, ai.accepted_by_profile_id, ai.target_managed_profile_id into v_recipient_email, v_status, v_expires_at, v_accepted_by_profile_id, v_target_profile_id from public.area_invites ai where ai.id = p_invite_id and ai.area_id = v_area_id for update;
  if not found then raise exception 'Invito non trovato'; end if;
  if v_recipient_email <> v_email then raise exception 'permission denied'; end if;
  if v_status = 'accepted' and v_accepted_by_profile_id = v_caller_profile_id then return; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' accettabile'; end if;
  if v_expires_at <= now() then raise exception 'Invito scaduto'; end if;
  if v_target_profile_id is null then
    perform 1 from public.profiles p where p.id = v_caller_profile_id for update;
    if not found then raise exception 'Profilo non trovato'; end if;
    select am.role into v_caller_membership_role from public.area_memberships am where am.area_id = v_area_id and am.profile_id = v_caller_profile_id for update;
    if v_caller_membership_role is null then insert into public.area_memberships(area_id, profile_id, role) values (v_area_id, v_caller_profile_id, 'member');
    elsif v_caller_membership_role = 'managed' then update public.area_memberships set role = 'member' where area_id = v_area_id and profile_id = v_caller_profile_id; end if;
    update public.area_invites set status = 'accepted', responded_at = now(), accepted_by_profile_id = v_caller_profile_id where id = p_invite_id and area_id = v_area_id;
    return;
  end if;
  if v_target_profile_id = v_caller_profile_id then raise exception 'Collegamento del partecipante non valido'; end if;
  for v_locked_profile_id in select p.id from public.profiles p where p.id in (v_target_profile_id, v_caller_profile_id) order by p.id for update loop v_locked_profile_count := v_locked_profile_count + 1; end loop;
  if v_locked_profile_count <> 2 then raise exception 'Profilo non trovato'; end if;
  select am.role, target_profile.user_id into v_target_role, v_target_user_id from public.area_memberships am join public.profiles target_profile on target_profile.id = am.profile_id where am.area_id = v_area_id and am.profile_id = v_target_profile_id for update of am, target_profile;
  if not found or v_target_role <> 'managed' or v_target_user_id is not null then raise exception 'Il partecipante indicato non e'' piu'' collegabile in questa Area'; end if;
  select am.role into v_caller_membership_role from public.area_memberships am where am.area_id = v_area_id and am.profile_id = v_caller_profile_id for update;
  if v_caller_membership_role is not null then raise exception 'Il tuo account e'' gia'' partecipante di questa Area: il collegamento richiede una risoluzione esplicita'; end if;
  if exists (select 1 from public.activity_assignees target_row join public.activity_assignees account_row on account_row.activity_id = target_row.activity_id where target_row.area_id = v_area_id and target_row.profile_id = v_target_profile_id and account_row.profile_id = v_caller_profile_id) then raise exception 'Collegamento non possibile: assegnazioni attivita'' in conflitto'; end if;
  if exists (select 1 from public.event_participants target_row join public.event_participants account_row on account_row.event_id = target_row.event_id where target_row.area_id = v_area_id and target_row.profile_id = v_target_profile_id and account_row.profile_id = v_caller_profile_id) then raise exception 'Collegamento non possibile: partecipazioni evento in conflitto'; end if;
  if exists (select 1 from public.area_list_participants target_row join public.area_list_participants account_row on account_row.list_id = target_row.list_id where target_row.area_id = v_area_id and target_row.profile_id = v_target_profile_id and account_row.profile_id = v_caller_profile_id) then raise exception 'Collegamento non possibile: partecipazioni Lista in conflitto'; end if;
  if exists (select 1 from public.profile_contacts target_row join public.profile_contacts account_row on account_row.area_id = target_row.area_id and account_row.contact_type = target_row.contact_type and (account_row.contact_value = target_row.contact_value or (account_row.is_primary and target_row.is_primary)) where target_row.area_id = v_area_id and target_row.profile_id = v_target_profile_id and account_row.profile_id = v_caller_profile_id) then raise exception 'Collegamento non possibile: recapiti contestuali in conflitto'; end if;
  insert into public.area_memberships(area_id, profile_id, role) values (v_area_id, v_caller_profile_id, 'member');
  delete from public.profile_contacts where area_id = v_area_id and profile_id = v_target_profile_id;
  update public.area_activities set created_by_profile_id = v_caller_profile_id where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_activities set completed_by_profile_id = v_caller_profile_id where area_id = v_area_id and completed_by_profile_id = v_target_profile_id;
  update public.activity_assignees aa set profile_id = v_caller_profile_id where aa.area_id = v_area_id and aa.profile_id = v_target_profile_id;
  update public.activity_assignees aa set assigned_by_profile_id = v_caller_profile_id from public.area_activities a where a.id = aa.activity_id and a.area_id = aa.area_id and a.area_id = v_area_id and aa.assigned_by_profile_id = v_target_profile_id;
  update public.area_events set created_by_profile_id = v_caller_profile_id where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.event_participants ep set profile_id = v_caller_profile_id where ep.area_id = v_area_id and ep.profile_id = v_target_profile_id;
  update public.event_participants ep set added_by_profile_id = v_caller_profile_id from public.area_events e where e.id = ep.event_id and e.area_id = ep.area_id and e.area_id = v_area_id and ep.added_by_profile_id = v_target_profile_id;
  update public.areas set created_by = v_caller_profile_id where id = v_area_id and created_by = v_target_profile_id;
  update public.area_lists set created_by_profile_id = v_caller_profile_id where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_list_participants alp set profile_id = v_caller_profile_id where alp.area_id = v_area_id and alp.profile_id = v_target_profile_id;
  update public.area_list_participants alp set added_by_profile_id = v_caller_profile_id from public.area_lists l where l.id = alp.list_id and l.area_id = alp.area_id and l.area_id = v_area_id and alp.added_by_profile_id = v_target_profile_id;
  update public.area_list_items i set created_by_profile_id = v_caller_profile_id from public.area_lists l where l.id = i.list_id and l.area_id = v_area_id and i.created_by_profile_id = v_target_profile_id;
  update public.area_list_items i set completed_by_profile_id = v_caller_profile_id from public.area_lists l where l.id = i.list_id and l.area_id = v_area_id and i.completed_by_profile_id = v_target_profile_id;
  update public.area_invites set created_by_profile_id = v_caller_profile_id where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_invites set accepted_by_profile_id = v_caller_profile_id where area_id = v_area_id and accepted_by_profile_id = v_target_profile_id;
  update public.area_invites set revoked_by_profile_id = v_caller_profile_id where area_id = v_area_id and revoked_by_profile_id = v_target_profile_id;
  update public.area_invites set status = case when status = 'pending' then 'revoked' else status end, revoked_at = case when status = 'pending' then now() else revoked_at end, revoked_by_profile_id = case when status = 'pending' then v_caller_profile_id else revoked_by_profile_id end, target_managed_profile_id = null where area_id = v_area_id and target_managed_profile_id = v_target_profile_id and id <> p_invite_id;
  update public.area_invites set status = 'accepted', responded_at = now(), accepted_by_profile_id = v_caller_profile_id, target_managed_profile_id = null where id = p_invite_id and area_id = v_area_id;
  delete from public.area_memberships where area_id = v_area_id and profile_id = v_target_profile_id;
end;
$$;

revoke all on function public.get_area_member_contacts(uuid, uuid) from public;
revoke all on function public.add_area_member_contact(uuid, uuid, text, text, boolean) from public;
revoke all on function public.update_area_member_contact(uuid, uuid, uuid, text) from public;
revoke all on function public.set_area_member_contact_primary(uuid, uuid, uuid) from public;
revoke all on function public.delete_area_member_contact(uuid, uuid, uuid) from public;
revoke all on function public.accept_area_invite(uuid) from public;
grant execute on function public.get_area_member_contacts(uuid, uuid) to authenticated;
grant execute on function public.add_area_member_contact(uuid, uuid, text, text, boolean) to authenticated;
grant execute on function public.update_area_member_contact(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.set_area_member_contact_primary(uuid, uuid, uuid) to authenticated;
grant execute on function public.delete_area_member_contact(uuid, uuid, uuid) to authenticated;
grant execute on function public.accept_area_invite(uuid) to authenticated;
