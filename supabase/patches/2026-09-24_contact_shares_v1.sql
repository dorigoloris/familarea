-- FamilArea — V1 private, email-bound contact sharing.
create table public.contact_shares (
  id uuid primary key default gen_random_uuid(),
  sender_profile_id uuid not null references public.profiles(id) on delete cascade,
  recipient_email text not null check (recipient_email = lower(btrim(recipient_email)) and recipient_email <> ''),
  token_hash text not null unique,
  status text not null default 'pending' check (status in ('pending','completed','revoked','expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  completed_by_profile_id uuid references public.profiles(id) on delete set null,
  revoked_at timestamptz,
  check (expires_at > created_at),
  check ((status = 'completed') = (completed_at is not null and completed_by_profile_id is not null)),
  check ((status = 'revoked') = (revoked_at is not null))
);
create unique index contact_shares_one_pending_sender_recipient_idx on public.contact_shares(sender_profile_id,recipient_email) where status='pending';
create index contact_shares_token_status_idx on public.contact_shares(token_hash,status,expires_at);
alter table public.contact_shares enable row level security;
revoke all on public.contact_shares from public, anon, authenticated;

alter table public.contact_profile_links drop constraint contact_profile_links_linked_via_check;
alter table public.contact_profile_links add constraint contact_profile_links_linked_via_check check (linked_via in ('event_invite','verified','contact_share'));

create or replace function public.hash_contact_share_token(p_token text) returns text
language sql immutable set search_path=public,extensions,pg_temp as $$
  select encode(extensions.digest(convert_to(p_token,'UTF8'),'sha256'),'hex')
$$;

create or replace function public.contact_share_recipient_identity()
returns table(account_id uuid, profile_id uuid, email text)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  select a.id,p.id,public.normalize_contact_email(u.email) into account_id,profile_id,email
  from auth.users u join public.accounts a on a.auth_user_id=u.id and a.account_type='personal'
  join public.profiles p on p.account_id=a.id
  where u.id=auth.uid() and u.email_confirmed_at is not null;
  if account_id is null then raise exception 'verified personal profile required'; end if;
  return next;
end $$;

create or replace function public.create_contact_share(p_recipient_email text) returns jsonb
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare v_sender record; v_email text; v_token text:=encode(extensions.gen_random_bytes(32),'hex'); v_id uuid;
begin
  select * into v_sender from public.contact_share_recipient_identity();
  v_email:=public.normalize_contact_email(p_recipient_email);
  if v_email=v_sender.email then raise exception 'cannot share with your own email'; end if;
  update public.contact_shares set status='expired' where sender_profile_id=v_sender.profile_id and recipient_email=v_email and status='pending' and expires_at<=now();
  update public.contact_shares set status='revoked',revoked_at=now() where sender_profile_id=v_sender.profile_id and recipient_email=v_email and status='pending';
  insert into public.contact_shares(sender_profile_id,recipient_email,token_hash,expires_at)
  values(v_sender.profile_id,v_email,public.hash_contact_share_token(v_token),now()+interval '14 days') returning id into v_id;
  return jsonb_build_object('share_id',v_id,'token',v_token,'expires_at',now()+interval '14 days');
end $$;

create or replace function public.get_contact_share_for_recipient(p_token text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_recipient record; v_share public.contact_shares%rowtype; v_sender_email text; v_first text; v_last text;
begin
  select * into v_recipient from public.contact_share_recipient_identity();
  select * into v_share from public.contact_shares where token_hash=public.hash_contact_share_token(p_token) for update;
  if not found then raise exception 'contact share unavailable'; end if;
  if v_share.status='pending' and v_share.expires_at<=now() then update public.contact_shares set status='expired' where id=v_share.id; v_share.status:='expired'; end if;
  if v_share.status<>'pending' then raise exception 'contact share unavailable'; end if;
  if v_share.recipient_email<>v_recipient.email then raise exception 'contact share recipient mismatch'; end if;
  select p.first_name,p.last_name,public.normalize_contact_email(u.email) into v_first,v_last,v_sender_email from public.profiles p join public.accounts a on a.id=p.account_id join auth.users u on u.id=a.auth_user_id where p.id=v_share.sender_profile_id and u.email_confirmed_at is not null;
  if v_sender_email is null then raise exception 'contact share unavailable'; end if;
  return jsonb_build_object('first_name',v_first,'last_name',v_last,'email',v_sender_email,'expires_at',v_share.expires_at);
end $$;

create or replace function public.accept_contact_share(p_token text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_recipient record; v_share public.contact_shares%rowtype; v_sender_email text; v_first text; v_last text; v_contact uuid; v_link_profile uuid; v_count integer; v_has_email boolean;
begin
  select * into v_recipient from public.contact_share_recipient_identity();
  select * into v_share from public.contact_shares where token_hash=public.hash_contact_share_token(p_token) for update;
  if not found then raise exception 'contact share unavailable'; end if;
  if v_share.status='pending' and v_share.expires_at<=now() then update public.contact_shares set status='expired' where id=v_share.id; v_share.status:='expired'; end if;
  if v_share.status<>'pending' or v_share.recipient_email<>v_recipient.email then raise exception 'contact share unavailable'; end if;
  select p.first_name,p.last_name,public.normalize_contact_email(u.email) into v_first,v_last,v_sender_email from public.profiles p join public.accounts a on a.id=p.account_id join auth.users u on u.id=a.auth_user_id where p.id=v_share.sender_profile_id and u.email_confirmed_at is not null;
  if v_sender_email is null then raise exception 'contact share unavailable'; end if;
  select contact_id into v_contact from public.contact_profile_links where owner_account_id=v_recipient.account_id and profile_id=v_share.sender_profile_id;
  if v_contact is null then
    select count(distinct c.id),min(c.id::text)::uuid into v_count,v_contact from public.contacts c join public.contact_methods m on m.contact_id=c.id where c.owner_account_id=v_recipient.account_id and m.method_type='email' and lower(btrim(m.value))=v_sender_email;
    if v_count>1 then raise exception 'contact share conflict'; end if;
    if v_contact is null then
      insert into public.contacts(owner_account_id,first_name,last_name) values(v_recipient.account_id,v_first,nullif(v_last,'')) returning id into v_contact;
      insert into public.contact_methods(contact_id,method_type,value,is_primary) values(v_contact,'email',v_sender_email,true);
    else
      select profile_id into v_link_profile from public.contact_profile_links where contact_id=v_contact;
      if v_link_profile is not null and v_link_profile<>v_share.sender_profile_id then raise exception 'contact share conflict'; end if;
      select exists(select 1 from public.contact_methods where contact_id=v_contact and method_type='email' and lower(btrim(value))=v_sender_email) into v_has_email;
      if not v_has_email then insert into public.contact_methods(contact_id,method_type,value,is_primary) values(v_contact,'email',v_sender_email,not exists(select 1 from public.contact_methods where contact_id=v_contact and method_type='email')); end if;
    end if;
    insert into public.contact_profile_links(contact_id,owner_account_id,profile_id,linked_via) values(v_contact,v_recipient.account_id,v_share.sender_profile_id,'contact_share') on conflict do nothing;
    if not exists(select 1 from public.contact_profile_links where contact_id=v_contact and owner_account_id=v_recipient.account_id and profile_id=v_share.sender_profile_id) then raise exception 'contact share conflict'; end if;
  end if;
  update public.contact_shares set status='completed',completed_at=now(),completed_by_profile_id=v_recipient.profile_id where id=v_share.id;
  return jsonb_build_object('contact_id',v_contact);
end $$;

create or replace function public.revoke_contact_share(p_share_id uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_sender record;
begin select * into v_sender from public.contact_share_recipient_identity();
  update public.contact_shares set status='revoked',revoked_at=now() where id=p_share_id and sender_profile_id=v_sender.profile_id and status='pending' and expires_at>now();
  if not found then raise exception 'contact share unavailable'; end if;
end $$;

create or replace function public.get_my_pending_contact_shares() returns setof jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_sender record;
begin select * into v_sender from public.contact_share_recipient_identity();
  update public.contact_shares set status='expired' where sender_profile_id=v_sender.profile_id and status='pending' and expires_at<=now();
  return query select jsonb_build_object('share_id',id,'recipient_email',recipient_email,'expires_at',expires_at) from public.contact_shares where sender_profile_id=v_sender.profile_id and status='pending' order by created_at desc;
end $$;

revoke all on function public.hash_contact_share_token(text),public.contact_share_recipient_identity(),public.create_contact_share(text),public.get_contact_share_for_recipient(text),public.accept_contact_share(text),public.revoke_contact_share(uuid),public.get_my_pending_contact_shares() from public,anon;
grant execute on function public.create_contact_share(text),public.get_contact_share_for_recipient(text),public.accept_contact_share(text),public.revoke_contact_share(uuid),public.get_my_pending_contact_shares() to authenticated;
alter function public.hash_contact_share_token(text) owner to postgres;
alter function public.contact_share_recipient_identity() owner to postgres;
alter function public.create_contact_share(text) owner to postgres;
alter function public.get_contact_share_for_recipient(text) owner to postgres;
alter function public.accept_contact_share(text) owner to postgres;
alter function public.revoke_contact_share(uuid) owner to postgres;
alter function public.get_my_pending_contact_shares() owner to postgres;
