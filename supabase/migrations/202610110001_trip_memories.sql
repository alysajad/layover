-- Camera memories are private by default, separate from group attachments.
begin;
create table public.trip_memories (
  id uuid primary key,
  trip_id uuid not null references public.trips(id),
  owner_id uuid not null references public.profiles(id),
  trip_title text not null,
  destination text not null default '',
  person_name text not null default '' check(char_length(person_name)<=120),
  note text not null default '' check(char_length(note)<=2000),
  place text not null default '' check(char_length(place)<=240),
  captured_at timestamptz not null check(captured_at between '2000-01-01'::timestamptz and '2101-01-01'::timestamptz),
  photo_path text not null unique,
  ready boolean not null default false,
  shared boolean not null default false,
  version integer not null default 1,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  check(photo_path=owner_id::text||'/'||id::text||'.jpg')
);
create index trip_memories_owner on public.trip_memories(owner_id,captured_at desc);
create index trip_memories_shared on public.trip_memories(trip_id) where shared and deleted_at is null;
alter table public.trip_memories enable row level security;
revoke all on public.trip_memories from anon,authenticated;

create function public.can_read_memory(p_path text) returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from trip_memories m where m.photo_path=p_path and m.deleted_at is null
    and (m.owner_id=auth.uid() or (m.ready and m.shared
      and active_member(m.trip_id,m.owner_id) and active_member(m.trip_id,auth.uid()))));
$$;
revoke all on function public.can_read_memory(text) from public,anon;
grant execute on function public.can_read_memory(text) to authenticated;

create function public.memory_snapshot() returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(to_jsonb(m)||jsonb_build_object('can_share',
    m.owner_id=auth.uid() and m.ready and m.deleted_at is null and active_member(m.trip_id,auth.uid())
      and exists(select 1 from trips t where t.id=m.trip_id and t.archived_at is null))
    order by m.captured_at desc),'[]'::jsonb)
  from trip_memories m where m.owner_id=auth.uid() or
    (m.deleted_at is null and m.ready and m.shared and active_member(m.trip_id,m.owner_id) and active_member(m.trip_id,auth.uid()));
$$;

create function public.memory_command(p_action text,p_data jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare uid uuid=auth.uid(); mid uuid; tid uuid; m trip_memories; t trips; old command_receipts; result jsonb;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  if p_request_id is null or p_data is null or octet_length(p_data::text)>12000 then raise exception 'Invalid request'; end if;
  if p_action is null or p_action not in ('save','ready','visibility','delete') then raise exception 'Unknown memory action'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text||p_request_id::text,0));
  select * into old from command_receipts where user_id=uid and request_id=p_request_id;
  if found then
    if old.input<>jsonb_build_object('action','memory:'||p_action,'data',p_data) then raise exception 'Request ID reused with different input'; end if;
    return old.result;
  end if;
  mid=(p_data->>'id')::uuid;
  -- Serialize commands for this photo, including first registration.
  perform pg_advisory_xact_lock(hashtextextended(mid::text,1));
  select * into m from trip_memories where id=mid for update;
  if not found then
    if p_action<>'save' then raise exception 'Memory unavailable'; end if;
    tid=(p_data->>'trip_id')::uuid;
    -- Lock membership so capture/share cannot race a membership removal.
    perform 1 from trip_members where trip_id=tid and user_id=uid and membership_status='joined' for share;
    if not found then raise exception 'Trip access denied. Your photo remains on this phone.'; end if;
    select * into t from trips where id=tid and archived_at is null for share;
    if not found then raise exception 'Trip is archived. Your photo remains on this phone.'; end if;
    insert into trip_memories(id,trip_id,owner_id,trip_title,destination,person_name,note,place,captured_at,photo_path)
      values(mid,tid,uid,t.title,coalesce(t.destination,''),trim(coalesce(p_data->>'person_name','')),
        trim(coalesce(p_data->>'note','')),trim(coalesce(p_data->>'place','')),
        (p_data->>'captured_at')::timestamptz,uid::text||'/'||mid::text||'.jpg') returning * into m;
  else
    if m.owner_id<>uid then raise exception 'Only the owner can change this memory'; end if;
    if p_action<>'delete' and m.deleted_at is not null then raise exception 'Memory was deleted'; end if;
    if p_action='visibility' and (p_data->>'version')::integer is distinct from m.version then
      raise exception 'Memory changed on another device. Refresh before editing.';
    end if;
    if p_action='save' then
      update trip_memories set person_name=trim(coalesce(p_data->>'person_name','')),
        note=trim(coalesce(p_data->>'note','')),place=trim(coalesce(p_data->>'place','')),
        version=version+1,updated_at=now() where id=mid returning * into m;
    elsif p_action='ready' then
      if not exists(select 1 from storage.objects where bucket_id='trip-memories' and name=m.photo_path) then raise exception 'Photo upload is incomplete'; end if;
      update trip_memories set ready=true,updated_at=now() where id=mid returning * into m;
    elsif p_action='visibility' then
      if (p_data->>'shared')::boolean then
        perform 1 from trip_members where trip_id=m.trip_id and user_id=uid and membership_status='joined' for share;
        if not found then raise exception 'Trip access denied'; end if;
        perform 1 from trips where id=m.trip_id and archived_at is null for share;
        if not found then raise exception 'Trip is archived'; end if;
        if not m.ready then raise exception 'Back up the photo before sharing'; end if;
      end if;
      update trip_memories set shared=(p_data->>'shared')::boolean,version=version+1,updated_at=now()
        where id=mid returning * into m;
    elsif p_action='delete' then
      update trip_memories set deleted_at=coalesce(deleted_at,now()),shared=false,person_name='',note='',place='',updated_at=now()
        where id=mid returning * into m;
    end if;
  end if;
  result=to_jsonb(m);
  insert into command_receipts values(uid,p_request_id,jsonb_build_object('action','memory:'||p_action,'data',p_data),result,now());
  return result;
end $$;
revoke all on function public.memory_snapshot() from public,anon;
revoke all on function public.memory_command(text,jsonb,uuid) from public,anon;
grant execute on function public.memory_snapshot() to authenticated;
grant execute on function public.memory_command(text,jsonb,uuid) to authenticated;

-- Reset actual visibility, so rejoining never silently shares old photos again.
create function public.unshare_departed_memories() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.membership_status<>'joined' and old.membership_status='joined' then
    update trip_memories set shared=false,version=version+1,updated_at=now()
      where trip_id=new.trip_id and owner_id=new.user_id and shared;
  end if;
  return new;
end $$;
create trigger memories_member_departure after update of membership_status on public.trip_members
  for each row execute function public.unshare_departed_memories();

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('trip-memories','trip-memories',false,10485760,array['image/jpeg']);
-- Small checked helpers avoid granting direct table access through storage.
create function public.owns_memory_photo(p_path text,p_upload boolean) returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from trip_memories m where m.photo_path=p_path and m.owner_id=auth.uid()
    and (not p_upload or (m.deleted_at is null and not m.ready)));
$$;
revoke all on function public.owns_memory_photo(text,boolean) from public,anon;
grant execute on function public.owns_memory_photo(text,boolean) to authenticated;
create policy memory_photo_read on storage.objects for select to authenticated
  using(bucket_id='trip-memories' and (public.can_read_memory(name) or public.owns_memory_photo(name,false)));
create policy memory_photo_insert on storage.objects for insert to authenticated
  with check(bucket_id='trip-memories' and public.owns_memory_photo(name,true));
create policy memory_photo_delete on storage.objects for delete to authenticated
  using(bucket_id='trip-memories' and public.owns_memory_photo(name,false));
commit;
