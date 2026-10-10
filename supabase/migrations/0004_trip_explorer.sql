-- Immutable exploration versions; existing membership is the sole access authority.
create table public.exploration_plans (
  id uuid primary key,
  plan_id uuid not null,
  parent_id uuid references public.exploration_plans(id),
  trip_id uuid not null references public.trips(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  title text not null check (length(title) between 1 and 120),
  currency text not null check (currency in ('INR','USD','EUR','GBP','JPY','KWD')),
  total_budget_minor bigint not null check (total_budget_minor between 1 and 999999999999),
  group_size integer not null check (group_size between 1 and 50),
  start_at timestamptz not null,
  end_at timestamptz not null check (end_at > start_at and end_at <= start_at + interval '7 days'),
  version integer not null check (version > 0),
  status text not null default 'draft' check (status in ('draft','ready','shared')),
  snapshot jsonb not null check (jsonb_typeof(snapshot)='object' and octet_length(snapshot::text)<=1000000),
  request_hash text not null,
  created_at timestamptz not null default now(),
  shared_at timestamptz,
  unique(plan_id,version)
);
create index exploration_plans_trip on public.exploration_plans(trip_id,created_at desc);
create table public.exploration_plan_events (
  id uuid primary key default gen_random_uuid(),
  plan_version_id uuid not null references public.exploration_plans(id) on delete cascade,
  actor_user_id uuid not null references public.profiles(id),
  event_type text not null check (event_type in ('saved','shared')),
  created_at timestamptz not null default now()
);
create table public.exploration_provider_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_at timestamptz not null,
  calls integer not null
);
alter table public.exploration_plans enable row level security;
alter table public.exploration_plan_events enable row level security;
alter table public.exploration_provider_limits enable row level security;
create policy exploration_read on public.exploration_plans for select to authenticated
  using(public.is_trip_member(trip_id) and (public.is_trip_organizer(trip_id) or status='shared'));
create policy exploration_events_read on public.exploration_plan_events for select to authenticated
  using(exists(select 1 from public.exploration_plans p where p.id=plan_version_id));
grant select on public.exploration_plans,public.exploration_plan_events to authenticated;

create function public.explorer_validate_point(p jsonb) returns void
language plpgsql set search_path=public as $$
begin
  if jsonb_typeof(p) is distinct from 'array' then raise exception 'Invalid coordinate'; end if;
  if jsonb_array_length(p)<>2 or jsonb_typeof(p->0) is distinct from 'number'
    or jsonb_typeof(p->1) is distinct from 'number' then raise exception 'Invalid coordinate'; end if;
  if abs((p->>0)::numeric)>180 or abs((p->>1)::numeric)>85 then raise exception 'Invalid coordinate bounds'; end if;
end $$;

create function public.explorer_validate_snapshot(p jsonb) returns void
language plpgsql set search_path=public as $$
declare s jsonb:=p->'settings'; z jsonb:=s->'zone'; x jsonb; c jsonb; costs jsonb; candidates jsonb;
  leg jsonb; stop jsonb; minx numeric; maxx numeric; miny numeric; maxy numeric;
begin
  if p->>'schema_version' is distinct from '1' or jsonb_typeof(s) is distinct from 'object'
    or octet_length(p::text)>1000000 then raise exception 'Invalid plan snapshot'; end if;
  if (s->>'budget_minor') is null or (s->>'budget_minor') !~ '^\d{1,12}$'
    or (s->>'group_size') is null or (s->>'group_size') !~ '^\d{1,2}$'
    or (s->>'currency') is null or s->>'currency' not in ('INR','USD','EUR','GBP','JPY','KWD') then
    raise exception 'Invalid budget, group or currency'; end if;
  perform explorer_validate_point(s->'origin');
  if s->'destination' <> 'null'::jsonb then perform explorer_validate_point(s->'destination'); end if;
  if z->>'type'='circle' then
    perform explorer_validate_point(z->'center');
    if jsonb_typeof(z->'radius_m') is distinct from 'number' or (z->>'radius_m')::numeric not between 100 and 30000 then
      raise exception 'Invalid radius'; end if;
  elsif z->>'type'='polygon' then
    if jsonb_typeof(z->'vertices') is distinct from 'array' then raise exception 'Invalid polygon'; end if;
    if jsonb_array_length(z->'vertices') not between 3 and 20 then raise exception 'Invalid polygon'; end if;
    for x in select value from jsonb_array_elements(z->'vertices') loop perform explorer_validate_point(x); end loop;
    select min((value->>0)::numeric),max((value->>0)::numeric),min((value->>1)::numeric),max((value->>1)::numeric)
      into minx,maxx,miny,maxy from jsonb_array_elements(z->'vertices');
    if maxx-minx>1 or maxy-miny>1 then raise exception 'Polygon too large'; end if;
  else raise exception 'Invalid zone'; end if;
  if jsonb_typeof(s->'modes') is distinct from 'array' then raise exception 'Invalid modes'; end if;
  if jsonb_array_length(s->'modes') not between 1 and 3 or exists(
    select 1 from jsonb_array_elements_text(s->'modes') m where m not in ('walk','bicycle','drive')) then
    raise exception 'Invalid modes'; end if;
  if jsonb_typeof(s->'caps') is distinct from 'object' then raise exception 'Invalid caps'; end if;
  for x in select jsonb_build_object('key',key,'value',value) from jsonb_each(s->'caps') loop
    if x->>'key' not in ('transport','admission','food','fees','contingency') or x->>'value' !~ '^\d{1,12}$' then
      raise exception 'Invalid caps'; end if;
  end loop;
  if jsonb_typeof(p->'places') is distinct from 'array' or jsonb_typeof(p->'itineraries') is distinct from 'array'
    or jsonb_typeof(p->'allowances') is distinct from 'array' then raise exception 'Invalid plan collections'; end if;
  if jsonb_array_length(p->'places')>40 or jsonb_array_length(p->'itineraries')>3 then raise exception 'Plan too large'; end if;
  if p->>'selected_candidate' is null or p->>'selected_candidate' !~ '^\d$'
    or (p->>'selected_candidate')::integer>=greatest(1,jsonb_array_length(p->'itineraries')) then
    raise exception 'Invalid selected candidate'; end if;
  costs:=p->'allowances';
  for x in select value from jsonb_array_elements(p->'places') loop
    perform explorer_validate_point(x->'point');
    if x->>'selection_type' is null or x->>'selection_type' not in ('must_visit','optional','excluded')
      or x->>'dwell_minutes' is null or x->>'dwell_minutes' !~ '^\d{1,3}$'
      or (x->>'dwell_minutes')::integer>480 or nullif(x->>'provider_place_id','') is null
      or nullif(x->>'id','') is null or nullif(x->>'name','') is null
      or x->>'priority' is null or x->>'priority' !~ '^[1-5]$' then
      raise exception 'Invalid selected place'; end if;
    costs:=costs || jsonb_build_array(x->'cost');
  end loop;
  candidates:=p->'itineraries';
  for x in select value from jsonb_array_elements(p->'itineraries') loop
    if x ? 'route_alternatives' then
      if jsonb_typeof(x->'route_alternatives') is distinct from 'array' then raise exception 'Invalid path alternatives'; end if;
      if jsonb_array_length(x->'route_alternatives')>2 then raise exception 'Too many path alternatives'; end if;
      candidates:=candidates || (x->'route_alternatives');
    end if;
  end loop;
  for x in select value from jsonb_array_elements(candidates) loop
    if jsonb_typeof(x->'costs') is distinct from 'array' or jsonb_typeof(x->'stops') is distinct from 'array'
      or jsonb_typeof(x->'legs') is distinct from 'array' then raise exception 'Invalid itinerary'; end if;
    if jsonb_array_length(x->'stops') not between 1 and 8 or jsonb_array_length(x->'legs') not between 1 and 9
      or jsonb_array_length(x->'legs')<>jsonb_array_length(x->'stops')+(case when s->'destination'<>'null'::jsonb then 1 else 0 end) then
      raise exception 'Invalid stop/leg count'; end if;
    if nullif(x->>'id','') is null or nullif(x->>'provider','') is null or nullif(x->>'checked_at','') is null
      or x->>'mode' is null or x->>'mode' not in ('walk','bicycle','drive')
      or x->>'duration_seconds' is null or x->>'duration_seconds' !~ '^\d{1,9}$'
      or x->'geometry'->>'type' is null or x->'geometry'->>'type' not in ('LineString','MultiLineString')
      or jsonb_typeof(x->'geometry'->'coordinates') is distinct from 'array' then raise exception 'Invalid route data'; end if;
    for stop in select value from jsonb_array_elements(x->'stops') loop
      if nullif(stop->>'name','') is null or nullif(stop->>'id','') is null or stop->>'dwell_minutes' is null
        or stop->>'dwell_minutes' !~ '^\d{1,3}$' or (stop->>'dwell_minutes')::integer>480 then raise exception 'Invalid stop'; end if;
      perform explorer_validate_point(stop->'point');
    end loop;
    for leg in select value from jsonb_array_elements(x->'legs') loop
      if leg->>'leg_order' is null or leg->>'leg_order' !~ '^\d$'
        or leg->>'duration_seconds' is null or leg->>'duration_seconds' !~ '^\d{1,9}$'
        or jsonb_typeof(leg->'distance_m') is distinct from 'number' or (leg->>'distance_m')::numeric<0
        or leg->>'transport_mode' is distinct from x->>'mode' then raise exception 'Invalid leg'; end if;
      perform explorer_validate_point(leg->'origin');perform explorer_validate_point(leg->'destination');
    end loop;
    costs:=costs || (x->'costs');
  end loop;
  if jsonb_array_length(costs)>200 then raise exception 'Too many costs'; end if;
  for c in select value from jsonb_array_elements(costs) loop
    if c->>'currency' is distinct from s->>'currency' or c->>'cost_basis' is null
      or nullif(c->>'id','') is null or nullif(c->>'description','') is null
      or c->>'cost_basis' not in ('per_person','per_vehicle','per_group','per_ticket','flat')
      or c->>'quantity' is null or c->>'quantity' !~ '^\d{1,5}$'
      or (c->>'quantity')::integer not between 1 and 10000
      or c->>'category' is null or c->>'category' not in ('transport','admission','food','fees','contingency')
      or c->>'estimate_status' is null or c->>'estimate_status' not in
        ('unknown','manual','provider_quote','published_tariff','model_estimate') then raise exception 'Invalid cost'; end if;
    if c->>'estimate_status'<>'unknown' then
      if c->>'low_minor' is null or c->>'high_minor' is null
        or c->>'low_minor' !~ '^\d{1,12}$' or c->>'high_minor' !~ '^\d{1,12}$' then raise exception 'Invalid money'; end if;
      if (c->>'high_minor')::bigint<(c->>'low_minor')::bigint then raise exception 'Invalid cost range'; end if;
      if (c->>'high_minor')::numeric*(c->>'quantity')::numeric*
        (case when c->>'cost_basis'='per_person' then (s->>'group_size')::numeric else 1 end) > 9007199254740991 then
        raise exception 'Cost exceeds supported monetary range'; end if;
    end if;
    if c->>'estimate_status'='manual' and (nullif(c->>'author','') is null or nullif(c->>'checked_at','') is null) then
      raise exception 'Manual cost needs author and timestamp'; end if;
  end loop;
end $$;

-- Stamp new/edited manual amounts on the server; retain unchanged historical authors.
create function public.explorer_stamp_manual(p jsonb,prior jsonb,uid uuid,stamp timestamptz) returns jsonb
language plpgsql set search_path=public as $$
declare result jsonb; item jsonb; olditem jsonb; k text; i integer:=0;
begin
  if jsonb_typeof(p)='object' then
    if p->>'estimate_status'='manual' then
      if p=prior then return p; end if;
      return p || jsonb_build_object('author',uid,'checked_at',stamp,'source','User-entered','confidence','user_supplied');
    end if;
    result:='{}';
    for k,item in select key,value from jsonb_each(p) loop
      result:=result || jsonb_build_object(k,explorer_stamp_manual(item,prior->k,uid,stamp));
    end loop;
    return result;
  elsif jsonb_typeof(p)='array' then
    result:='[]';
    for item in select value from jsonb_array_elements(p) loop
      olditem:=null;
      if jsonb_typeof(prior)='array' then
        if item->>'id' is not null then
          select value into olditem from jsonb_array_elements(prior) where value->>'id'=item->>'id' limit 1;
        else olditem:=prior->i; end if;
      end if;
      result:=result || jsonb_build_array(explorer_stamp_manual(item,olditem,uid,stamp));
      i:=i+1;
    end loop;
    return result;
  end if;
  return p;
end $$;

create function public.explorer_save(p_id uuid,p_trip_id uuid,p_parent_id uuid,p_title text,p_snapshot jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); old exploration_plans; parent exploration_plans; result exploration_plans;
  owner uuid; archived timestamptz; lineage uuid; v integer; s jsonb:=p_snapshot->'settings';
  fingerprint text:=encode(digest(p_snapshot::text,'sha256'),'hex'); normalized jsonb;
begin
  select organizer_user_id,archived_at into owner,archived from trips where id=p_trip_id for update;
  if uid is null or not is_trip_member(p_trip_id) or owner<>uid then raise exception 'Organizer access required'; end if;
  if archived is not null then raise exception 'Trip archived'; end if;
  select * into old from exploration_plans where id=p_id;
  if found then
    if old.trip_id<>p_trip_id or old.created_by<>uid or old.request_hash<>fingerprint or old.title<>p_title
      or old.parent_id is distinct from p_parent_id then raise exception 'Request ID reused with different input'; end if;
    return to_jsonb(old);
  end if;
  perform explorer_validate_snapshot(p_snapshot);
  lineage:=p_id; v:=1;
  if p_parent_id is not null then
    select * into parent from exploration_plans where id=p_parent_id and trip_id=p_trip_id;
    if not found then raise exception 'Parent version unavailable'; end if;
    lineage:=parent.plan_id;
    select max(version)+1 into v from exploration_plans where plan_id=lineage;
  end if;
  normalized:=explorer_stamp_manual(p_snapshot,parent.snapshot,uid,now());
  insert into exploration_plans(id,plan_id,parent_id,trip_id,created_by,title,currency,total_budget_minor,
    group_size,start_at,end_at,version,status,snapshot,request_hash)
  values(p_id,lineage,p_parent_id,p_trip_id,uid,p_title,s->>'currency',(s->>'budget_minor')::bigint,
    (s->>'group_size')::integer,(s->>'start_at')::timestamptz,(s->>'end_at')::timestamptz,v,
    case when jsonb_array_length(p_snapshot->'itineraries')>0 then 'ready' else 'draft' end,normalized,fingerprint)
  returning * into result;
  insert into exploration_plan_events(plan_version_id,actor_user_id,event_type) values(p_id,uid,'saved');
  return to_jsonb(result);
end $$;

create function public.explorer_share(p_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare p exploration_plans; t uuid;
begin
  select trip_id into t from exploration_plans where id=p_id;
  perform 1 from trips where id=t for update;
  select * into p from exploration_plans where id=p_id for update;
  if not found or auth.uid() is null or not is_trip_member(p.trip_id) or not is_trip_organizer(p.trip_id) then
    raise exception 'Organizer access required'; end if;
  if exists(select 1 from trips where id=p.trip_id and archived_at is not null) then raise exception 'Trip archived'; end if;
  if p.status='draft' then raise exception 'Generate an itinerary before sharing'; end if;
  if p.status='shared' then return; end if;
  update exploration_plans set status='shared',shared_at=now() where id=p_id;
  insert into exploration_plan_events(plan_version_id,actor_user_id,event_type) values(p_id,auth.uid(),'shared');
end $$;

-- Called with the user's JWT by the provider proxy, before any billable request.
create function public.explorer_provider_access(p_trip_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare hits integer;
begin
  if auth.uid() is null or not is_trip_member(p_trip_id) or not is_trip_organizer(p_trip_id) then
    raise exception 'Organizer access required'; end if;
  if exists(select 1 from trips where id=p_trip_id and archived_at is not null) then raise exception 'Trip archived'; end if;
  insert into exploration_provider_limits(user_id,window_at,calls) values(auth.uid(),now(),1)
  on conflict(user_id) do update set
    calls=case when exploration_provider_limits.window_at < now()-interval '1 minute' then 1 else exploration_provider_limits.calls+1 end,
    window_at=case when exploration_provider_limits.window_at < now()-interval '1 minute' then now() else exploration_provider_limits.window_at end
  returning calls into hits;
  if hits>60 then raise exception 'Provider rate limit; retry in a minute'; end if;
end $$;

revoke all on function public.explorer_validate_point(jsonb),public.explorer_validate_snapshot(jsonb),public.explorer_stamp_manual(jsonb,jsonb,uuid,timestamptz) from public;
revoke all on function public.explorer_save(uuid,uuid,uuid,text,jsonb),public.explorer_share(uuid),public.explorer_provider_access(uuid) from public;
grant execute on function public.explorer_save(uuid,uuid,uuid,text,jsonb),public.explorer_share(uuid),public.explorer_provider_access(uuid) to authenticated;
