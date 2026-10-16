-- FamilArea V2 — fotografia di copertina per Timeline Ricordi.
--
-- La fotografia resta un allegato privato esistente: questo file salva soltanto
-- il suo riferimento sul Ricordo, senza duplicare file o percorsi Storage.

begin;

alter table public.memories
  add column if not exists cover_attachment_id uuid;

do $$
declare
  v_cover_attnum smallint;
  v_cover_type regtype;
begin
  select a.attnum, a.atttypid::regtype
  into v_cover_attnum, v_cover_type
  from pg_attribute a
  where a.attrelid = 'public.memories'::regclass
    and a.attname = 'cover_attachment_id'
    and not a.attisdropped;

  if v_cover_attnum is null then
    raise exception 'memories.cover_attachment_id is unavailable';
  end if;

  if v_cover_type <> 'uuid'::regtype then
    raise exception 'memories.cover_attachment_id must be uuid';
  end if;

  if exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.memories'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.attachments'::regclass
      and c.confdeltype = 'n'
      and c.conkey = array[v_cover_attnum]::smallint[]
  ) then
    return;
  end if;

  if exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.memories'::regclass
      and c.contype = 'f'
      and v_cover_attnum = any(c.conkey)
  ) then
    raise exception 'memories.cover_attachment_id has an unexpected foreign key';
  end if;

  alter table public.memories
    add constraint memories_cover_attachment_id_fkey
    foreign key (cover_attachment_id)
    references public.attachments(id)
    on delete set null;
end;
$$;

create or replace function public.set_memory_cover(
  p_memory_id uuid,
  p_attachment_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_memory public.memories%rowtype;
begin
  select *
  into v_memory
  from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = public.require_current_account();

  if not found then
    raise exception 'memory unavailable';
  end if;

  if p_attachment_id is not null
    and not exists (
      select 1
      from public.attachments a
      where a.id = p_attachment_id
        and a.target_type = 'memory'
        and a.target_id = p_memory_id
        and a.mime_type in ('image/jpeg', 'image/png', 'image/webp')
    ) then
    raise exception 'cover attachment is unavailable';
  end if;

  update public.memories m
  set cover_attachment_id = p_attachment_id,
      updated_at = now()
  where m.id = p_memory_id
    and m.owner_account_id = public.require_current_account()
  returning * into v_memory;

  return to_jsonb(v_memory);
end;
$$;

alter function public.set_memory_cover(uuid, uuid) owner to postgres;

revoke all on function public.set_memory_cover(uuid, uuid) from public, anon;
grant execute on function public.set_memory_cover(uuid, uuid) to authenticated;

commit;
