-- FamilArea — private Contact suggestions between verified personal accounts.
-- This is deliberately separate from legacy contact_shares: no private contact
-- methods or other address-book data are transferred.

alter table public.contact_profile_links drop constraint contact_profile_links_linked_via_check;
alter table public.contact_profile_links add constraint contact_profile_links_linked_via_check
  check (linked_via in ('event_invite', 'verified', 'contact_share', 'family_invite', 'contact_suggestion'));

create table public.contact_suggestions (
  id uuid primary key default gen_random_uuid(),
  sender_account_id uuid not null references public.accounts(id) on delete cascade,
  recipient_email text not null check (recipient_email = public.normalize_contact_email(recipient_email)),
  suggested_profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'revoked', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  responded_at timestamptz,
  accepted_by_profile_id uuid references public.profiles(id) on delete set null,
  check (expires_at > created_at),
  check ((status = 'accepted') = (accepted_by_profile_id is not null))
);

create unique index contact_suggestions_one_pending_sender_recipient_subject
  on public.contact_suggestions(sender_account_id, recipient_email, suggested_profile_id)
  where status = 'pending';
create index contact_suggestions_recipient_status_expires
  on public.contact_suggestions(recipient_email, status, expires_at, created_at desc);

alter table public.contact_suggestions enable row level security;
revoke all on public.contact_suggestions from public, anon, authenticated;

create or replace function public.create_contact_suggestion(
  p_contact_id uuid,
  p_recipient_email text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sender_account_id uuid;
  v_recipient_email text;
  v_suggested_profile_id uuid;
  v_suggestion_id uuid;
begin
  v_sender_account_id := public.require_current_account();
  v_recipient_email := public.normalize_contact_email(p_recipient_email);

  select cpl.profile_id
  into v_suggested_profile_id
  from public.contacts as c
  join public.contact_profile_links as cpl
    on cpl.contact_id = c.id
   and cpl.owner_account_id = c.owner_account_id
  join public.profiles as suggested_profile on suggested_profile.id = cpl.profile_id
  join public.accounts as suggested_account
    on suggested_account.id = suggested_profile.account_id
   and suggested_account.account_type = 'personal'
  where c.id = p_contact_id
    and c.owner_account_id = v_sender_account_id;

  if v_suggested_profile_id is null then
    raise exception 'contact cannot be suggested';
  end if;

  update public.contact_suggestions as cs
  set status = 'expired'
  where cs.sender_account_id = v_sender_account_id
    and cs.recipient_email = v_recipient_email
    and cs.suggested_profile_id = v_suggested_profile_id
    and cs.status = 'pending'
    and cs.expires_at <= now();

  if exists (
    select 1
    from public.contact_suggestions as cs
    where cs.sender_account_id = v_sender_account_id
      and cs.recipient_email = v_recipient_email
      and cs.suggested_profile_id = v_suggested_profile_id
      and cs.status = 'pending'
  ) then
    raise exception 'contact suggestion already pending';
  end if;

  insert into public.contact_suggestions(
    sender_account_id, recipient_email, suggested_profile_id
  ) values (
    v_sender_account_id, v_recipient_email, v_suggested_profile_id
  ) returning id into v_suggestion_id;

  return jsonb_build_object('suggestion_id', v_suggestion_id, 'status', 'pending');
end;
$$;

create or replace function public.get_my_contact_suggestions()
returns table(
  suggestion_id uuid,
  status text,
  created_at timestamptz,
  expires_at timestamptz,
  sender_name text,
  suggested_first_name text,
  suggested_last_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  update public.contact_suggestions as cs
  set status = 'expired'
  where cs.recipient_email = v_recipient.email
    and cs.status = 'pending'
    and cs.expires_at <= now();

  return query
  select
    cs.id,
    cs.status,
    cs.created_at,
    cs.expires_at,
    coalesce(
      organization.name,
      nullif(btrim(concat_ws(' ', sender_profile.first_name, sender_profile.last_name)), ''),
      'Utente FamilArea'
    ),
    suggested_profile.first_name,
    suggested_profile.last_name
  from public.contact_suggestions as cs
  join public.profiles as suggested_profile on suggested_profile.id = cs.suggested_profile_id
  left join public.organizations as organization on organization.account_id = cs.sender_account_id
  left join public.profiles as sender_profile on sender_profile.account_id = cs.sender_account_id
  where cs.recipient_email = v_recipient.email
    and cs.status = 'pending'
    and cs.expires_at > now()
  order by cs.created_at desc, cs.id;
end;
$$;

create or replace function public.accept_my_contact_suggestion(p_suggestion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_suggestion public.contact_suggestions%rowtype;
  v_contact_id uuid;
  v_first_name text;
  v_last_name text;
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  select * into v_suggestion
  from public.contact_suggestions
  where id = p_suggestion_id
  for update;

  if not found
     or v_suggestion.recipient_email <> v_recipient.email
     or v_suggestion.status <> 'pending'
     or v_suggestion.expires_at <= now() then
    raise exception 'contact suggestion unavailable';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    v_recipient.account_id::text || ':' || v_suggestion.suggested_profile_id::text,
    0
  ));

  select cpl.contact_id
  into v_contact_id
  from public.contact_profile_links as cpl
  where cpl.owner_account_id = v_recipient.account_id
    and cpl.profile_id = v_suggestion.suggested_profile_id;

  if v_contact_id is null then
    select first_name, last_name
    into v_first_name, v_last_name
    from public.profiles
    where id = v_suggestion.suggested_profile_id;

    if v_first_name is null then
      raise exception 'contact suggestion unavailable';
    end if;

    insert into public.contacts(owner_account_id, first_name, last_name)
    values(v_recipient.account_id, v_first_name, nullif(btrim(coalesce(v_last_name, '')), ''))
    returning id into v_contact_id;

    insert into public.contact_profile_links(
      contact_id, owner_account_id, profile_id, linked_via
    ) values (
      v_contact_id, v_recipient.account_id, v_suggestion.suggested_profile_id, 'contact_suggestion'
    );
  end if;

  update public.contact_suggestions
  set status = 'accepted',
      accepted_by_profile_id = v_recipient.profile_id,
      responded_at = now()
  where id = v_suggestion.id;

  return jsonb_build_object('suggestion_id', v_suggestion.id, 'contact_id', v_contact_id, 'status', 'accepted');
end;
$$;

create or replace function public.decline_my_contact_suggestion(p_suggestion_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_suggestion public.contact_suggestions%rowtype;
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  select * into v_suggestion
  from public.contact_suggestions
  where id = p_suggestion_id
  for update;

  if not found
     or v_suggestion.recipient_email <> v_recipient.email
     or v_suggestion.status <> 'pending'
     or v_suggestion.expires_at <= now() then
    raise exception 'contact suggestion unavailable';
  end if;

  update public.contact_suggestions
  set status = 'declined', responded_at = now()
  where id = v_suggestion.id;
end;
$$;

revoke all on function public.create_contact_suggestion(uuid, text) from public, anon;
revoke all on function public.get_my_contact_suggestions() from public, anon;
revoke all on function public.accept_my_contact_suggestion(uuid) from public, anon;
revoke all on function public.decline_my_contact_suggestion(uuid) from public, anon;
grant execute on function public.create_contact_suggestion(uuid, text) to authenticated;
grant execute on function public.get_my_contact_suggestions() to authenticated;
grant execute on function public.accept_my_contact_suggestion(uuid) to authenticated;
grant execute on function public.decline_my_contact_suggestion(uuid) to authenticated;
alter function public.create_contact_suggestion(uuid, text) owner to postgres;
alter function public.get_my_contact_suggestions() owner to postgres;
alter function public.accept_my_contact_suggestion(uuid) owner to postgres;
alter function public.decline_my_contact_suggestion(uuid) owner to postgres;
