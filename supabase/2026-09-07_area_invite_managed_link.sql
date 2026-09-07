-- FamilArea — Fase 2 Inviti: collegamento esplicito di un partecipante managed.
-- La conversione e' limitata alla sola Area dell'invito: il profilo tecnico
-- continua a esistere e puo' restare managed in altre Aree.

begin;

alter table public.area_invites
  add column target_managed_profile_id uuid;

alter table public.area_invites
  add constraint area_invites_target_managed_profile_fkey
    foreign key (target_managed_profile_id)
    references public.profiles(id)
    on delete restrict,
  add constraint area_invites_target_managed_membership_fkey
    foreign key (area_id, target_managed_profile_id)
    references public.area_memberships(area_id, profile_id)
    on delete restrict;

create index area_invites_target_managed_pending_idx
  on public.area_invites(area_id, target_managed_profile_id)
  where status = 'pending' and target_managed_profile_id is not null;

-- La firma precedente viene sostituita da una versione compatibile: il quinto
-- argomento e' opzionale, quindi le chiamate agli inviti normali restano valide.
drop function public.create_area_invite(uuid, text, text, text);

create function public.create_area_invite(
  p_area_id uuid,
  p_email text,
  p_first_name text default null,
  p_last_name text default null,
  p_target_managed_profile_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_invite_id uuid;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Utente non autorizzato';
  end if;

  perform 1 from public.areas where id = p_area_id for update;
  if not found then
    raise exception 'Area non trovata';
  end if;

  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role = 'admin'
  ) then
    raise exception 'permission denied';
  end if;

  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Email non valida';
  end if;

  -- Il target e' sempre selezionato esplicitamente dall'admin: non esiste
  -- alcun confronto automatico tra email, nomi o Contatti personali.
  if p_target_managed_profile_id is not null then
    perform 1
    from public.area_memberships am
    join public.profiles target_profile on target_profile.id = am.profile_id
    where am.area_id = p_area_id
      and am.profile_id = p_target_managed_profile_id
      and am.role = 'managed'
      and target_profile.user_id is null
    for update of am, target_profile;

    if not found then
      raise exception 'Il partecipante selezionato non e'' piu'' un profilo managed disponibile in questa Area';
    end if;
  end if;

  update public.area_invites
  set status = 'expired'
  where area_id = p_area_id
    and recipient_email = v_email
    and status = 'pending'
    and expires_at <= now();

  if exists (
    select 1
    from auth.users u
    join public.profiles p on p.user_id = u.id
    join public.area_memberships am on am.profile_id = p.id
    where lower(btrim(u.email)) = v_email
      and am.area_id = p_area_id
      and am.role in ('admin', 'member')
  ) then
    raise exception 'Impossibile creare l''invito per questo indirizzo';
  end if;

  if exists (
    select 1 from public.area_invites ai
    where ai.area_id = p_area_id
      and ai.recipient_email = v_email
      and ai.status = 'pending'
  ) then
    raise exception 'Esiste gia'' un invito in attesa per questo indirizzo';
  end if;

  insert into public.area_invites(
    area_id, recipient_email, first_name, last_name, expires_at,
    created_by_profile_id, target_managed_profile_id
  )
  values (
    p_area_id, v_email,
    nullif(btrim(coalesce(p_first_name, '')), ''),
    nullif(btrim(coalesce(p_last_name, '')), ''),
    now() + interval '7 days', v_caller_profile_id,
    p_target_managed_profile_id
  )
  returning id into v_invite_id;

  return v_invite_id;
end;
$$;

drop function public.get_area_invites(uuid);

create function public.get_area_invites(p_area_id uuid)
returns table(
  invite_id uuid,
  recipient_email text,
  first_name text,
  last_name text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  has_target_managed_participant boolean,
  target_first_name text,
  target_last_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then raise exception 'Utente non autorizzato'; end if;
  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin'
  ) then raise exception 'permission denied'; end if;

  return query
  select ai.id, ai.recipient_email, ai.first_name, ai.last_name,
         case when ai.status = 'pending' and ai.expires_at <= now() then 'expired' else ai.status end,
         ai.expires_at, ai.created_at,
         ai.target_managed_profile_id is not null,
         target_profile.first_name, target_profile.last_name
  from public.area_invites ai
  left join public.profiles target_profile on target_profile.id = ai.target_managed_profile_id
  where ai.area_id = p_area_id
  order by ai.created_at desc, ai.id;
end;
$$;

drop function public.get_my_area_invites();

create function public.get_my_area_invites()
returns table(
  invite_id uuid,
  area_id uuid,
  area_name text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  inviter_first_name text,
  inviter_last_name text,
  is_managed_participant_link boolean,
  target_first_name text,
  target_last_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_email text;
begin
  select lower(btrim(u.email)) into v_email
  from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;

  if v_email is null then raise exception 'Email dell''account non verificata'; end if;

  return query
  select ai.id, ai.area_id, a.name,
         case when ai.status = 'pending' and ai.expires_at <= now() then 'expired' else ai.status end,
         ai.expires_at, ai.created_at,
         inviter.first_name, inviter.last_name,
         ai.target_managed_profile_id is not null,
         target_profile.first_name, target_profile.last_name
  from public.area_invites ai
  join public.areas a on a.id = ai.area_id
  join public.profiles inviter on inviter.id = ai.created_by_profile_id
  left join public.profiles target_profile on target_profile.id = ai.target_managed_profile_id
  where ai.recipient_email = v_email
  order by case when ai.status = 'pending' and ai.expires_at > now() then 0 else 1 end,
           ai.created_at desc, ai.id;
end;
$$;

create or replace function public.accept_area_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
  v_email text;
  v_area_id uuid;
  v_recipient_email text;
  v_status text;
  v_expires_at timestamptz;
  v_accepted_by_profile_id uuid;
  v_target_profile_id uuid;
  v_target_role text;
  v_target_user_id uuid;
  v_caller_membership_role text;
  v_locked_profile_id uuid;
  v_locked_profile_count integer := 0;
begin
  select p.id, lower(btrim(u.email))
  into v_caller_profile_id, v_email
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where u.id = auth.uid() and u.email_confirmed_at is not null;

  if v_caller_profile_id is null or v_email is null then
    raise exception 'Email dell''account non verificata o profilo non trovato';
  end if;

  -- Lettura iniziale solo per sapere quale Area bloccare; i dati dell'invito
  -- vengono riletti e validati dopo il lock.
  select ai.area_id into v_area_id
  from public.area_invites ai
  where ai.id = p_invite_id;
  if v_area_id is null then raise exception 'Invito non trovato'; end if;

  perform 1 from public.areas where id = v_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;

  update public.area_invites
  set status = 'expired'
  where id = p_invite_id
    and area_id = v_area_id
    and status = 'pending'
    and expires_at <= now();

  select ai.recipient_email, ai.status, ai.expires_at,
         ai.accepted_by_profile_id, ai.target_managed_profile_id
  into v_recipient_email, v_status, v_expires_at,
       v_accepted_by_profile_id, v_target_profile_id
  from public.area_invites ai
  where ai.id = p_invite_id and ai.area_id = v_area_id
  for update;

  if not found then raise exception 'Invito non trovato'; end if;
  if v_recipient_email <> v_email then raise exception 'permission denied'; end if;
  if v_status = 'accepted' and v_accepted_by_profile_id = v_caller_profile_id then return; end if;
  if v_status <> 'pending' then raise exception 'L''invito non e'' accettabile'; end if;
  if v_expires_at <= now() then raise exception 'Invito scaduto'; end if;

  if v_target_profile_id is null then
    -- Flusso Fase 1 invariato per gli inviti senza collegamento esplicito.
    perform 1 from public.profiles p where p.id = v_caller_profile_id for update;
    if not found then raise exception 'Profilo non trovato'; end if;

    select am.role into v_caller_membership_role
    from public.area_memberships am
    where am.area_id = v_area_id and am.profile_id = v_caller_profile_id
    for update;

    if v_caller_membership_role is null then
      insert into public.area_memberships(area_id, profile_id, role)
      values (v_area_id, v_caller_profile_id, 'member');
    elsif v_caller_membership_role = 'managed' then
      update public.area_memberships
      set role = 'member'
      where area_id = v_area_id and profile_id = v_caller_profile_id;
    end if;

    update public.area_invites
    set status = 'accepted', responded_at = now(), accepted_by_profile_id = v_caller_profile_id
    where id = p_invite_id and area_id = v_area_id;
    return;
  end if;

  if v_target_profile_id = v_caller_profile_id then
    raise exception 'Collegamento del partecipante non valido';
  end if;

  -- Ordine stabile per due righe profiles; evita deadlock tra accettazioni
  -- che coinvolgono profili in ordine inverso.
  for v_locked_profile_id in
    select p.id
    from public.profiles p
    where p.id in (v_target_profile_id, v_caller_profile_id)
    order by p.id
    for update
  loop
    v_locked_profile_count := v_locked_profile_count + 1;
  end loop;
  if v_locked_profile_count <> 2 then raise exception 'Profilo non trovato'; end if;

  select am.role, target_profile.user_id
  into v_target_role, v_target_user_id
  from public.area_memberships am
  join public.profiles target_profile on target_profile.id = am.profile_id
  where am.area_id = v_area_id and am.profile_id = v_target_profile_id
  for update of am, target_profile;

  if not found
     or v_target_role <> 'managed'
     or v_target_user_id is not null then
    raise exception 'Il partecipante indicato non e'' piu'' collegabile in questa Area';
  end if;

  select am.role into v_caller_membership_role
  from public.area_memberships am
  where am.area_id = v_area_id and am.profile_id = v_caller_profile_id
  for update;

  if v_caller_membership_role is not null then
    raise exception 'Il tuo account e'' gia'' partecipante di questa Area: il collegamento richiede una risoluzione esplicita';
  end if;

  -- Le collisioni non dovrebbero essere possibili senza una membership A gia'
  -- esistente, ma vengono bloccate esplicitamente prima di ogni aggiornamento.
  if exists (
    select 1
    from public.activity_assignees target_row
    join public.activity_assignees account_row
      on account_row.activity_id = target_row.activity_id
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: assegnazioni attivita'' in conflitto'; end if;

  if exists (
    select 1
    from public.event_participants target_row
    join public.event_participants account_row
      on account_row.event_id = target_row.event_id
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: partecipazioni evento in conflitto'; end if;

  if exists (
    select 1
    from public.area_list_participants target_row
    join public.area_list_participants account_row
      on account_row.list_id = target_row.list_id
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: partecipazioni Lista in conflitto'; end if;

  if exists (
    select 1
    from public.profile_contacts target_row
    join public.profile_contacts account_row
      on account_row.area_id = target_row.area_id
     and account_row.contact_type = target_row.contact_type
     and (
       account_row.contact_value = target_row.contact_value
       or (account_row.is_primary and target_row.is_primary)
     )
    where target_row.area_id = v_area_id
      and target_row.profile_id = v_target_profile_id
      and account_row.profile_id = v_caller_profile_id
  ) then raise exception 'Collegamento non possibile: recapiti contestuali in conflitto'; end if;

  insert into public.area_memberships(area_id, profile_id, role)
  values (v_area_id, v_caller_profile_id, 'member');

  update public.profile_contacts
  set profile_id = v_caller_profile_id
  where area_id = v_area_id and profile_id = v_target_profile_id;

  update public.area_activities
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_activities
  set completed_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and completed_by_profile_id = v_target_profile_id;
  update public.activity_assignees aa
  set profile_id = v_caller_profile_id
  where aa.area_id = v_area_id and aa.profile_id = v_target_profile_id;
  update public.activity_assignees aa
  set assigned_by_profile_id = v_caller_profile_id
  from public.area_activities a
  where a.id = aa.activity_id and a.area_id = aa.area_id
    and a.area_id = v_area_id and aa.assigned_by_profile_id = v_target_profile_id;

  update public.area_events
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.event_participants ep
  set profile_id = v_caller_profile_id
  where ep.area_id = v_area_id and ep.profile_id = v_target_profile_id;
  update public.event_participants ep
  set added_by_profile_id = v_caller_profile_id
  from public.area_events e
  where e.id = ep.event_id and e.area_id = ep.area_id
    and e.area_id = v_area_id and ep.added_by_profile_id = v_target_profile_id;

  update public.areas
  set created_by = v_caller_profile_id
  where id = v_area_id and created_by = v_target_profile_id;

  update public.area_lists
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_list_participants alp
  set profile_id = v_caller_profile_id
  where alp.area_id = v_area_id and alp.profile_id = v_target_profile_id;
  update public.area_list_participants alp
  set added_by_profile_id = v_caller_profile_id
  from public.area_lists l
  where l.id = alp.list_id and l.area_id = alp.area_id
    and l.area_id = v_area_id and alp.added_by_profile_id = v_target_profile_id;
  update public.area_list_items i
  set created_by_profile_id = v_caller_profile_id
  from public.area_lists l
  where l.id = i.list_id and l.area_id = v_area_id
    and i.created_by_profile_id = v_target_profile_id;
  update public.area_list_items i
  set completed_by_profile_id = v_caller_profile_id
  from public.area_lists l
  where l.id = i.list_id and l.area_id = v_area_id
    and i.completed_by_profile_id = v_target_profile_id;

  -- Gli audit degli inviti sono area-scoped; non viene mai toccato un invito
  -- di un'altra Area. Gli inviti concorrenti allo stesso target vengono
  -- revocati: non possono degradare a inviti normali dopo la conversione.
  update public.area_invites
  set created_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and created_by_profile_id = v_target_profile_id;
  update public.area_invites
  set accepted_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and accepted_by_profile_id = v_target_profile_id;
  update public.area_invites
  set revoked_by_profile_id = v_caller_profile_id
  where area_id = v_area_id and revoked_by_profile_id = v_target_profile_id;
  update public.area_invites
  set status = case when status = 'pending' then 'revoked' else status end,
      revoked_at = case when status = 'pending' then now() else revoked_at end,
      revoked_by_profile_id = case when status = 'pending' then v_caller_profile_id else revoked_by_profile_id end,
      target_managed_profile_id = null
  where area_id = v_area_id
    and target_managed_profile_id = v_target_profile_id
    and id <> p_invite_id;

  update public.area_invites
  set status = 'accepted',
      responded_at = now(),
      accepted_by_profile_id = v_caller_profile_id,
      target_managed_profile_id = null
  where id = p_invite_id and area_id = v_area_id;

  delete from public.area_memberships
  where area_id = v_area_id and profile_id = v_target_profile_id;
end;
$$;

-- La rimozione di un partecipante deve rendere non accettabili tutti gli
-- inviti pending che lo indicavano esplicitamente come target. Il target viene
-- scollegato anche dagli inviti conclusi per liberare la FK composita prima
-- della rimozione della membership; lo stato concluso resta invariato.
create or replace function public.remove_area_member(p_area_id uuid, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_caller_profile_id uuid; v_target_role text;
begin
  select p.id into v_caller_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_caller_profile_id is null then raise exception 'Utente non autorizzato: profilo non trovato'; end if;

  perform 1 from public.areas where id = p_area_id for update;
  if not found then raise exception 'Area non trovata'; end if;

  if not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.profile_id = v_caller_profile_id and am.role = 'admin'
  ) then raise exception 'Utente non autorizzato: solo un admin dell''Area puo'' rimuovere membri'; end if;

  -- Lock Area -> Inviti target -> membership, coerente con accept_area_invite.
  perform 1 from public.area_invites ai
  where ai.area_id = p_area_id and ai.target_managed_profile_id = p_profile_id
  for update;

  select am.role into v_target_role from public.area_memberships am
  where am.area_id = p_area_id and am.profile_id = p_profile_id
  for update;
  if not found then raise exception 'Membership del membro non trovata in questa Area'; end if;

  if v_target_role = 'admin' and not exists (
    select 1 from public.area_memberships am
    where am.area_id = p_area_id and am.role = 'admin' and am.profile_id <> p_profile_id
  ) then raise exception 'Impossibile rimuovere l''ultimo amministratore dell''Area'; end if;

  perform 1 from public.area_activities a where a.area_id = p_area_id and a.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: e'' creatore di attivita'' in questa Area'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: e'' creatore di eventi in questa Area'; end if;
  perform 1 from public.area_lists l where l.area_id = p_area_id and l.created_by_profile_id = p_profile_id for update;
  if found then raise exception 'Impossibile rimuovere il membro: e'' creatore di Liste in questa Area'; end if;
  perform 1 from public.area_activities a where a.area_id = p_area_id and a.visibility = 'creator_assignees'
    and exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id = p_profile_id)
    and not exists (select 1 from public.activity_assignees aa where aa.activity_id = a.id and aa.profile_id <> p_profile_id)
    for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo assegnatario di attivita'' selettiva'; end if;
  perform 1 from public.area_events e where e.area_id = p_area_id and e.visibility = 'creator_participants'
    and exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id = p_profile_id)
    and not exists (select 1 from public.event_participants ep where ep.event_id = e.id and ep.profile_id <> p_profile_id)
    for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di evento selettivo'; end if;
  perform 1 from public.area_lists l where l.area_id = p_area_id and l.visibility = 'creator_participants'
    and exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id = p_profile_id)
    and not exists (select 1 from public.area_list_participants alp where alp.list_id = l.id and alp.profile_id <> p_profile_id)
    for update;
  if found then raise exception 'Impossibile rimuovere il membro: ultimo partecipante di Lista selettiva'; end if;

  update public.area_invites
  set status = case when status = 'pending' then 'revoked' else status end,
      revoked_at = case when status = 'pending' then now() else revoked_at end,
      revoked_by_profile_id = case when status = 'pending' then v_caller_profile_id else revoked_by_profile_id end,
      target_managed_profile_id = null
  where area_id = p_area_id and target_managed_profile_id = p_profile_id;

  delete from public.area_memberships
  where area_id = p_area_id and profile_id = p_profile_id;
end;
$$;

revoke all on function public.create_area_invite(uuid, text, text, text, uuid) from public;
revoke all on function public.get_area_invites(uuid) from public;
revoke all on function public.get_my_area_invites() from public;
revoke all on function public.accept_area_invite(uuid) from public;
revoke all on function public.remove_area_member(uuid, uuid) from public;
grant execute on function public.create_area_invite(uuid, text, text, text, uuid) to authenticated;
grant execute on function public.get_area_invites(uuid) to authenticated;
grant execute on function public.get_my_area_invites() to authenticated;
grant execute on function public.accept_area_invite(uuid) to authenticated;
grant execute on function public.remove_area_member(uuid, uuid) to authenticated;

commit;
