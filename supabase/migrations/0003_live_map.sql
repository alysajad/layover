-- Private, foreground-only Live Map. Never route coordinates through companion receipts.
create table public.live_sessions (
  id uuid primary key default gen_random_uuid(),
  linked_trip_id uuid references public.trips(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  name text not null check (length(name) between 1 and 120),
  status text not null default 'created' check (status in ('created','active','ended','expired','cancelled')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  ended_at timestamptz,
  check (expires_at > created_at and expires_at <= created_at + interval '8 hours')
);
create table public.live_session_members (
  session_id uuid not null references public.live_sessions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  role text not null check (role in ('organizer','member')),
  membership_status text not null check (membership_status in ('invited','joined','left','removed')),
  invitation_expires_at timestamptz,
  joined_at timestamptz,
  removed_at timestamptz,
  primary key(session_id,user_id)
);
create index live_members_user on public.live_session_members(user_id);
create table public.location_sharing_consents (
  session_id uuid not null,
  user_id uuid not null,
  consent_version text not null default 'live-map-v1',
  generation bigint not null default 0,
  granted_at timestamptz,
  revoked_at timestamptz,
  sharing_status text not null default 'stopped' check (sharing_status in ('sharing','paused','stopped')),
  lease_expires_at timestamptz,
  sequence_number bigint not null default 0,
  last_received_at timestamptz,
  primary key(session_id,user_id),
  foreign key(session_id,user_id) references public.live_session_members on delete cascade
);
create table public.live_locations (
  session_id uuid not null,
  user_id uuid not null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_m double precision not null check (accuracy_m between 0 and 5000),
  heading double precision check (heading >= 0 and heading < 360),
  speed_mps double precision check (speed_mps between 0 and 100),
  client_timestamp timestamptz not null,
  received_at timestamptz not null default now(),
  sequence_number bigint not null,
  primary key(session_id,user_id),
  foreign key(session_id,user_id) references public.live_session_members on delete cascade
);
create table public.regroup_destinations (
  session_id uuid primary key references public.live_sessions(id) on delete cascade,
  set_by_user_id uuid not null references public.profiles(id),
  name text not null check (length(name) between 1 and 120),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  updated_at timestamptz not null default now()
);
create table public.live_session_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.live_sessions(id) on delete cascade,
  actor_user_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  created_at timestamptz not null default now()
);
-- Fingerprints only: never keep a destination payload or coordinates in a receipt.
create table public.live_map_receipts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_id uuid not null,
  fingerprint text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(user_id,request_id)
);

do $$ declare n text; begin
  foreach n in array array['live_sessions','live_session_members','location_sharing_consents','live_locations','regroup_destinations','live_session_events','live_map_receipts'] loop
    execute format('alter table public.%I enable row level security',n);
    execute format('revoke all on public.%I from anon, authenticated',n);
  end loop;
end $$;

create function public.live_map_trip_access(tid uuid, uid uuid) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from trips t join trip_members m on m.trip_id=t.id
    where t.id=tid and t.archived_at is null and m.user_id=uid and m.membership_status='joined');
$$;
create function public.live_map_eligible(tid uuid, organizer uuid, target uuid) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select case when tid is not null then live_map_trip_access(tid,organizer) and live_map_trip_access(tid,target)
    else exists(select 1 from trip_members a join trip_members b on a.trip_id=b.trip_id join trips t on t.id=a.trip_id
      where a.user_id=organizer and b.user_id=target and a.membership_status='joined' and b.membership_status='joined' and t.archived_at is null) end;
$$;
create function public.live_map_access(sid uuid, uid uuid) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select uid is not null and exists(select 1 from live_sessions s join live_session_members m on m.session_id=s.id
    where s.id=sid and s.status in ('created','active') and s.expires_at>now()
      and m.user_id=uid and m.membership_status='joined'
      and (s.linked_trip_id is null or live_map_trip_access(s.linked_trip_id,uid)));
$$;
create function public.live_map_sessions() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); result jsonb;
begin
  if uid is null then raise exception 'Sign in required' using errcode='42501'; end if;
  select jsonb_build_object('sessions',coalesce((select jsonb_agg(jsonb_build_object(
    'id',s.id,'name',s.name,'created_by',s.created_by,'linked_trip_id',s.linked_trip_id,
    'status',s.status,'expires_at',s.expires_at,'membership_status',m.membership_status))
    from live_sessions s join live_session_members m on m.session_id=s.id
    where m.user_id=uid and s.status in ('created','active') and s.expires_at>now()
      and (live_map_access(s.id,uid) or (m.membership_status='invited' and m.invitation_expires_at>now()
        and live_map_eligible(s.linked_trip_id,s.created_by,uid)))),'[]'::jsonb),
    'contacts',coalesce((select jsonb_agg(jsonb_build_object('user_id',p.id,'display_name',p.display_name))
      from profiles p where p.id<>uid and live_map_eligible(null,uid,p.id)),'[]'::jsonb)) into result;
  return result;
end $$;
create function public.live_map_snapshot(p_session_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not live_map_access(p_session_id,auth.uid()) then raise exception 'Session access denied or expired' using errcode='42501'; end if;
  return jsonb_build_object('server_time',now(),'session',(select to_jsonb(s) from live_sessions s where id=p_session_id),
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',p.display_name,
      'role',m.role,'membership_status',m.membership_status,
      'sharing_status',case when c.sharing_status='sharing' and c.lease_expires_at<=now() then 'paused' else coalesce(c.sharing_status,'stopped') end,
      'generation',case when m.user_id=auth.uid() then c.generation else null end,
      'lease_expires_at',c.lease_expires_at))
      from live_session_members m join profiles p on p.id=m.user_id
      left join location_sharing_consents c using(session_id,user_id)
      where m.session_id=p_session_id and m.membership_status in ('joined','invited')
        and (m.membership_status='joined' or m.invitation_expires_at>now())),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('stale',l.received_at<now()-interval '15 seconds','poor_accuracy',l.accuracy_m>100))
      from live_locations l join location_sharing_consents c using(session_id,user_id)
      where l.session_id=p_session_id and live_map_access(l.session_id,l.user_id)
        and c.sharing_status='sharing' and c.lease_expires_at>now() and l.received_at>now()-interval '30 seconds'),'[]'::jsonb),
    'destination',(select to_jsonb(d) from regroup_destinations d where session_id=p_session_id));
end $$;

create function public.live_map_command(p_action text,p_data jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  uid uuid:=auth.uid(); sid uuid; tid uuid; target uuid; s live_sessions; m live_session_members;
  receipt live_map_receipts; fingerprint text; result jsonb:='{}'; hours int;
begin
  if uid is null then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_request_id is null or p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>4096 then raise exception 'Invalid payload'; end if;
  if p_data ?| array['publisher_id','user_id'] then raise exception 'Publisher identity is derived from authentication'; end if;
  fingerprint:=encode(digest(p_action||p_data::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended(uid::text||p_request_id::text,0));
  select * into receipt from live_map_receipts where user_id=uid and request_id=p_request_id;
  if found then
    if receipt.fingerprint<>fingerprint then raise exception 'Request ID has different input'; end if;
    -- Receipts contain no coordinates and cannot renew consent or mutate a closed session.
    if not live_map_access((receipt.result->>'session_id')::uuid,uid) then raise exception 'Session access denied' using errcode='42501'; end if;
    return receipt.result;
  end if;
  if p_action='create' then
    tid:=nullif(p_data->>'linked_trip_id','')::uuid;
    if tid is not null and not live_map_trip_access(tid,uid) then raise exception 'Trip access denied' using errcode='42501'; end if;
    hours:=coalesce((p_data->>'duration_hours')::int,2);
    if hours not between 1 and 8 then raise exception 'Duration must be 1 to 8 hours'; end if;
    insert into live_sessions(linked_trip_id,created_by,name,expires_at)
      values(tid,uid,trim(p_data->>'name'),now()+hours*interval '1 hour') returning id into sid;
    insert into live_session_members(session_id,user_id,role,membership_status,joined_at) values(sid,uid,'organizer','joined',now());
  else
    sid:=(p_data->>'session_id')::uuid;
    -- ponytail: one session lock serializes publication and withdrawal; split locks only if group throughput demands it.
    select * into s from live_sessions where id=sid for update;
    if not found or s.status not in ('created','active') or s.expires_at<=now() then raise exception 'Session ended or expired' using errcode='42501'; end if;
    if s.linked_trip_id is not null and not live_map_trip_access(s.linked_trip_id,uid) then raise exception 'Trip access denied' using errcode='42501'; end if;
    select * into m from live_session_members where session_id=sid and user_id=uid;
    if p_action='join' then
      if m.membership_status is distinct from 'invited' or m.invitation_expires_at<=now()
        or not live_map_eligible(s.linked_trip_id,s.created_by,uid) then raise exception 'Invitation unavailable' using errcode='42501'; end if;
      update live_session_members set membership_status='joined',joined_at=now() where session_id=sid and user_id=uid;
    else
      if not live_map_access(sid,uid) then raise exception 'Session access denied' using errcode='42501'; end if;
      if p_action in ('start','cancel','invite','revoke','remove','end') and s.created_by<>uid then raise exception 'Only organizer can do this' using errcode='42501'; end if;
      if p_action='start' then
        if s.status<>'created' then raise exception 'Already started'; end if;
        update live_sessions set status='active' where id=sid;
      elsif p_action in ('cancel','end') then
        if p_action='cancel' and s.status<>'created' then raise exception 'End an active session'; end if;
        update live_sessions set status=case when p_action='cancel' then 'cancelled' else 'ended' end,ended_at=now() where id=sid;
        delete from live_locations where session_id=sid;
        delete from regroup_destinations where session_id=sid;
        update location_sharing_consents set sharing_status='stopped',revoked_at=now(),generation=generation+1,lease_expires_at=null where session_id=sid;
      elsif p_action='invite' then
        target:=(p_data->>'target_id')::uuid;
        if target=uid or not live_map_eligible(s.linked_trip_id,uid,target) then raise exception 'Choose an eligible trip contact'; end if;
        if (select count(*) from live_session_members where session_id=sid and (membership_status='joined' or (membership_status='invited' and invitation_expires_at>now())))>=50 then raise exception 'Session is full'; end if;
        insert into live_session_members(session_id,user_id,role,membership_status,invitation_expires_at)
          values(sid,target,'member','invited',least(s.expires_at,now()+interval '2 hours'))
          on conflict(session_id,user_id) do update set membership_status='invited',invitation_expires_at=excluded.invitation_expires_at,removed_at=null
            where live_session_members.membership_status in ('left','removed')
              or (live_session_members.membership_status='invited' and live_session_members.invitation_expires_at<=now());
      elsif p_action in ('revoke','remove','leave') then
        target:=case when p_action='leave' then uid else (p_data->>'target_id')::uuid end;
        if target=s.created_by then raise exception 'Organizer must end the session'; end if;
        if not exists(select 1 from live_session_members where session_id=sid and user_id=target and
          (p_action<>'revoke' or membership_status='invited')) then raise exception 'Member unavailable'; end if;
        update live_session_members set membership_status=case when p_action='leave' then 'left' else 'removed' end,removed_at=now() where session_id=sid and user_id=target;
        delete from live_locations where session_id=sid and user_id=target;
        update location_sharing_consents set sharing_status='stopped',revoked_at=now(),generation=generation+1,lease_expires_at=null where session_id=sid and user_id=target;
      elsif p_action in ('consent','pause','stop') then
        if p_action='consent' and (s.status<>'active' or p_data->>'consent_version' is distinct from 'live-map-v1') then raise exception 'Active session and explicit current consent required'; end if;
        insert into location_sharing_consents(session_id,user_id,generation,granted_at,revoked_at,sharing_status,lease_expires_at)
          values(sid,uid,1,case when p_action='consent' then now() end,case when p_action<>'consent' then now() end,
            case p_action when 'consent' then 'sharing' when 'pause' then 'paused' else 'stopped' end,
            case when p_action='consent' then now()+interval '30 seconds' end)
          on conflict(session_id,user_id) do update set generation=location_sharing_consents.generation+1,
            granted_at=excluded.granted_at,revoked_at=excluded.revoked_at,sharing_status=excluded.sharing_status,lease_expires_at=excluded.lease_expires_at,sequence_number=0
          returning jsonb_build_object('generation',generation) into result;
        delete from live_locations where session_id=sid and user_id=uid;
      elsif p_action='destination' then
        if s.status<>'active' then raise exception 'Start the session first'; end if;
        insert into regroup_destinations(session_id,set_by_user_id,name,latitude,longitude)
          values(sid,uid,trim(p_data->>'name'),(p_data->>'latitude')::double precision,(p_data->>'longitude')::double precision)
          on conflict(session_id) do update set set_by_user_id=uid,name=excluded.name,latitude=excluded.latitude,longitude=excluded.longitude,updated_at=now();
      else raise exception 'Unknown Live Map command'; end if;
    end if;
  end if;
  result:=result||jsonb_build_object('session_id',sid);
  insert into live_session_events(session_id,actor_user_id,event_type) values(sid,uid,p_action);
  insert into live_map_receipts(user_id,request_id,fingerprint,result) values(uid,p_request_id,fingerprint,result);
  return result;
end $$;

create function public.live_map_publish_location(p_session_id uuid,p_generation bigint,p_sequence bigint,
  p_latitude double precision,p_longitude double precision,p_accuracy_m double precision,p_client_timestamp timestamptz,
  p_heading double precision default null,p_speed_mps double precision default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); c location_sharing_consents; previous live_locations; distance_m double precision; elapsed double precision;
begin
  perform 1 from live_sessions where id=p_session_id and status='active' for update;
  if not found or not live_map_access(p_session_id,uid) then raise exception 'Session access denied' using errcode='42501'; end if;
  select * into c from location_sharing_consents where session_id=p_session_id and user_id=uid;
  if c.sharing_status is distinct from 'sharing' or c.generation is distinct from p_generation or c.lease_expires_at<=now() then raise exception 'Sharing paused; explicit resume required' using errcode='42501'; end if;
  if p_sequence is null or p_sequence<=c.sequence_number then raise exception 'Sequence must increase'; end if;
  if p_latitude is null or not(p_latitude between -90 and 90) or p_longitude is null or not(p_longitude between -180 and 180)
    or p_accuracy_m is null or not(p_accuracy_m between 0 and 5000)
    or (p_heading is not null and not(p_heading>=0 and p_heading<360))
    or (p_speed_mps is not null and not(p_speed_mps between 0 and 100)) then raise exception 'Invalid location'; end if;
  if p_client_timestamp is null or p_client_timestamp<now()-interval '30 seconds' or p_client_timestamp>now()+interval '10 seconds' then raise exception 'Use a fresh device fix'; end if;
  if c.last_received_at>now()-interval '5 seconds' then raise exception 'Publish at most once every five seconds'; end if;
  select * into previous from live_locations where session_id=p_session_id and user_id=uid;
  if found then
    elapsed:=extract(epoch from now()-previous.received_at);
    if elapsed<5 then raise exception 'Publish at most once every five seconds'; end if;
    if p_client_timestamp<=previous.client_timestamp then raise exception 'Use a newer device fix'; end if;
    distance_m:=6371000*2*asin(sqrt(least(1.0,power(sin(radians(p_latitude-previous.latitude)/2),2)+
      cos(radians(previous.latitude))*cos(radians(p_latitude))*power(sin(radians(p_longitude-previous.longitude)/2),2))));
    if distance_m>100*elapsed+p_accuracy_m+previous.accuracy_m then raise exception 'Implausible location jump'; end if;
  end if;
  insert into live_locations(session_id,user_id,latitude,longitude,accuracy_m,heading,speed_mps,client_timestamp,sequence_number)
    values(p_session_id,uid,p_latitude,p_longitude,p_accuracy_m,p_heading,p_speed_mps,p_client_timestamp,p_sequence)
    on conflict(session_id,user_id) do update set latitude=excluded.latitude,longitude=excluded.longitude,accuracy_m=excluded.accuracy_m,
      heading=excluded.heading,speed_mps=excluded.speed_mps,client_timestamp=excluded.client_timestamp,received_at=now(),sequence_number=p_sequence;
  update location_sharing_consents set sequence_number=p_sequence,last_received_at=now(),lease_expires_at=now()+interval '30 seconds' where session_id=p_session_id and user_id=uid;
  return jsonb_build_object('accepted',true,'lease_expires_at',now()+interval '30 seconds');
end $$;

create function public.live_map_cleanup() returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  -- Same lock order as commands, so cleanup cannot erase a newly renewed lease.
  perform 1 from live_sessions order by id for update;
  update live_sessions set status='expired',ended_at=expires_at where status in ('created','active') and expires_at<=now();
  delete from live_locations l where not live_map_access(l.session_id,l.user_id)
    or l.received_at<=now()-interval '30 seconds'
    or not exists(select 1 from location_sharing_consents c where c.session_id=l.session_id and c.user_id=l.user_id and c.sharing_status='sharing' and c.lease_expires_at>now());
  update location_sharing_consents c set sharing_status='paused',generation=generation+1,revoked_at=now(),lease_expires_at=null
    where sharing_status='sharing' and (lease_expires_at<=now() or not live_map_access(c.session_id,c.user_id));
  delete from regroup_destinations where session_id in (select id from live_sessions where status not in ('created','active') or expires_at<=now());
  delete from live_session_events where created_at<now()-interval '30 days';
  delete from live_map_receipts where created_at<now()-interval '30 days';
  delete from live_sessions where expires_at<now()-interval '30 days';
end $$;

create function public.live_map_trip_invalidation() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare tid uuid; removed_user uuid; sid uuid;
begin
  if tg_table_name='trips' then
    if new.archived_at is null then return new; end if;
    tid:=new.id;
  else
    if tg_op<>'DELETE' and new.membership_status='joined' then return new; end if;
    tid:=old.trip_id; removed_user:=old.user_id;
  end if;
  for sid in select id from live_sessions where linked_trip_id=tid order by id for update loop
    delete from live_locations where session_id=sid and (removed_user is null or user_id=removed_user);
    update location_sharing_consents set sharing_status='stopped',generation=generation+1,revoked_at=now(),lease_expires_at=null
      where session_id=sid and (removed_user is null or user_id=removed_user);
    if removed_user is null or exists(select 1 from live_sessions where id=sid and created_by=removed_user) then
      update live_sessions set status='ended',ended_at=now() where id=sid and status in ('created','active');
      delete from live_locations where session_id=sid;
      delete from regroup_destinations where session_id=sid;
    else
      update live_session_members set membership_status='removed',removed_at=now() where session_id=sid and user_id=removed_user;
    end if;
  end loop;
  return coalesce(new,old);
end $$;
create trigger live_map_trip_archive after update of archived_at on public.trips for each row execute function public.live_map_trip_invalidation();
create trigger live_map_trip_member_removed after update of membership_status or delete on public.trip_members for each row execute function public.live_map_trip_invalidation();

do $$ declare f record; begin
  for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname like 'live_map_%' loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  end loop;
end $$;
grant execute on function public.live_map_sessions(),public.live_map_snapshot(uuid),public.live_map_command(text,jsonb,uuid),
  public.live_map_publish_location(uuid,bigint,bigint,double precision,double precision,double precision,timestamptz,double precision,double precision) to authenticated;
grant execute on function public.live_map_cleanup() to service_role;
-- Deployment must schedule live_map_cleanup() every minute (see operations guide).
-- Supabase projects with Cron already enabled get the retention job on migration.
-- Local PostgreSQL/PGlite stays extension-independent. Enable Cron before rollout.
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    execute $job$select cron.schedule('live-map-cleanup','* * * * *','select public.live_map_cleanup()')$job$;
  end if;
end $$;
