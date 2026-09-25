-- FamilArea — riuso esplicito di un Contact privato durante l'accettazione di una Contact Share.
create or replace function public.accept_contact_share_impl(p_token text,p_existing_contact_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_recipient record;
  v_share public.contact_shares%rowtype;
  v_sender_email text;
  v_first text;
  v_last text;
  v_contact uuid;
  v_link_profile uuid;
  v_count integer;
  v_has_email boolean;
begin
  select * into v_recipient from public.contact_share_recipient_identity();
  select * into v_share from public.contact_shares where token_hash=public.hash_contact_share_token(p_token) for update;
  if not found then raise exception 'contact share unavailable'; end if;
  if v_share.status='pending' and v_share.expires_at<=now() then update public.contact_shares set status='expired' where id=v_share.id; v_share.status:='expired'; end if;
  if v_share.status<>'pending' or v_share.recipient_email<>v_recipient.email then raise exception 'contact share unavailable'; end if;

  select p.first_name,p.last_name,public.normalize_contact_email(u.email) into v_first,v_last,v_sender_email
  from public.profiles p join public.accounts a on a.id=p.account_id join auth.users u on u.id=a.auth_user_id
  where p.id=v_share.sender_profile_id and u.email_confirmed_at is not null;
  if v_sender_email is null then raise exception 'contact share unavailable'; end if;

  select contact_id into v_contact from public.contact_profile_links where owner_account_id=v_recipient.account_id and profile_id=v_share.sender_profile_id;
  if p_existing_contact_id is not null then
    if v_contact is not null and v_contact<>p_existing_contact_id then raise exception 'contact share conflict'; end if;
    if not exists(select 1 from public.contacts c where c.id=p_existing_contact_id and c.owner_account_id=v_recipient.account_id) then raise exception 'selected contact unavailable'; end if;
    select l.profile_id into v_link_profile from public.contact_profile_links l where l.contact_id=p_existing_contact_id and l.owner_account_id=v_recipient.account_id;
    if v_link_profile is not null and v_link_profile<>v_share.sender_profile_id then raise exception 'Questo contatto è già collegato a un altro profilo FamilArea.'; end if;
    v_contact:=p_existing_contact_id;
  elsif v_contact is null then
    select count(distinct c.id),min(c.id::text)::uuid into v_count,v_contact from public.contacts c join public.contact_methods m on m.contact_id=c.id where c.owner_account_id=v_recipient.account_id and m.method_type='email' and lower(btrim(m.value))=v_sender_email;
    if v_count>1 then raise exception 'contact share conflict'; end if;
    if v_contact is null then
      insert into public.contacts(owner_account_id,first_name,last_name) values(v_recipient.account_id,v_first,nullif(v_last,'')) returning id into v_contact;
    else
      select l.profile_id into v_link_profile from public.contact_profile_links l where l.contact_id=v_contact;
      if v_link_profile is not null and v_link_profile<>v_share.sender_profile_id then raise exception 'contact share conflict'; end if;
    end if;
  end if;

  select exists(select 1 from public.contact_methods where contact_id=v_contact and method_type='email' and lower(btrim(value))=v_sender_email) into v_has_email;
  if not v_has_email then
    insert into public.contact_methods(contact_id,method_type,value,is_primary)
    values(v_contact,'email',v_sender_email,not exists(select 1 from public.contact_methods where contact_id=v_contact and method_type='email'));
  end if;
  insert into public.contact_profile_links(contact_id,owner_account_id,profile_id,linked_via)
  values(v_contact,v_recipient.account_id,v_share.sender_profile_id,'contact_share') on conflict do nothing;
  if not exists(select 1 from public.contact_profile_links where contact_id=v_contact and owner_account_id=v_recipient.account_id and profile_id=v_share.sender_profile_id) then raise exception 'contact share conflict'; end if;
  update public.contact_shares set status='completed',completed_at=now(),completed_by_profile_id=v_recipient.profile_id where id=v_share.id;
  return jsonb_build_object('contact_id',v_contact);
end $$;

create or replace function public.accept_contact_share(p_token text)
returns jsonb language sql security definer set search_path=public,pg_temp as $$ select public.accept_contact_share_impl(p_token,null) $$;

create function public.accept_contact_share(p_token text,p_existing_contact_id uuid)
returns jsonb language sql security definer set search_path=public,pg_temp as $$ select public.accept_contact_share_impl(p_token,p_existing_contact_id) $$;

alter function public.accept_contact_share_impl(text,uuid) owner to postgres;
alter function public.accept_contact_share(text) owner to postgres;
alter function public.accept_contact_share(text,uuid) owner to postgres;
revoke all on function public.accept_contact_share_impl(text,uuid),public.accept_contact_share(text),public.accept_contact_share(text,uuid) from public,anon;
grant execute on function public.accept_contact_share(text),public.accept_contact_share(text,uuid) to authenticated;
