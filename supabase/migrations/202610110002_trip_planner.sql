-- Funded pots become durable planning jobs. The scheduled worker also runs with
-- every app closed; provider credentials and generated prices never come from clients.
create table public.trip_planners (
  trip_id uuid primary key references public.trips(id) on delete cascade,
  settings jsonb not null,
  revision integer not null default 1,
  context jsonb not null,
  run_id uuid not null default gen_random_uuid(),
  state text not null default 'waiting' check(state in ('waiting','queued','running','ready','failed','shared')),
  result jsonb,
  error text,
  attempts integer not null default 0,
  lease_id uuid,
  leased_until timestamptz,
  requested_at timestamptz not null default now(),
  generated_at timestamptz,
  shared_at timestamptz,
  selected_option integer,
  check(jsonb_typeof(settings)='object' and octet_length(settings::text)<4000),
  check(result is null or (jsonb_typeof(result)='object' and octet_length(result::text)<500000))
);
alter table public.trip_planners enable row level security;
-- Access only through scoped RPCs; members can read the last published entries.
revoke all on public.trip_planners from anon,authenticated;
grant all on public.trip_planners to service_role;

create function public.planner_context(p_trip_id uuid) returns jsonb
language sql stable security definer set search_path=public as $$
  select jsonb_build_object('destination',t.destination,'start_date',t.start_date,'end_date',t.end_date,
    'budget_minor',p.target_minor_units,'currency',p.currency,'pot_id',p.id,'terms_version',p.terms_version,
    'members',(select coalesce(jsonb_agg(m.user_id order by m.user_id),'[]') from trip_members m
      where m.trip_id=t.id and m.membership_status='joined'))
  from trips t left join pots p on p.trip_id=t.id where t.id=p_trip_id
$$;
create function public.planner_funded(p_trip_id uuid) returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from pots p join trips t on t.id=p.trip_id
    where p.trip_id=p_trip_id and t.archived_at is null and p.status in ('target_reached','booked')
    and coalesce((select sum(case when x.recipient_id=t.organizer_user_id then x.amount_minor else -x.amount_minor end)
      from manual_transfers x where x.pot_id=p.id and x.status='acknowledged'),0)+p.organizer_cover_minor>=p.target_minor_units
    and not exists(select 1 from contribution_obligations o where o.pot_id=p.id and o.obligation_status<>'cancelled'
      and o.accepted_terms_version is distinct from p.terms_version))
$$;
create function public.planner_state(p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p trip_planners;
begin
  if auth.uid() is null or not is_trip_member(p_trip_id) or not is_trip_organizer(p_trip_id) then
    raise exception 'Organizer access required'; end if;
  select * into p from trip_planners where trip_id=p_trip_id;
  if not found then return null; end if;
  return (to_jsonb(p)-'lease_id'-'leased_until') || jsonb_build_object('funded',planner_funded(p_trip_id),
    'stale',p.context is distinct from planner_context(p_trip_id));
end $$;

create function public.planner_configure(p_trip_id uuid,p_settings jsonb,p_revision integer) returns jsonb
language plpgsql security definer set search_path=public as $$
declare t trips; p trip_planners; c jsonb; k text; amount bigint;
begin
  select * into t from trips where id=p_trip_id for update;
  if auth.uid() is null or not is_trip_member(p_trip_id) or t.organizer_user_id<>auth.uid() then
    raise exception 'Organizer access required'; end if;
  if t.archived_at is not null then raise exception 'Trip archived'; end if;
  c:=planner_context(p_trip_id);
  if c->>'budget_minor' is null or c->>'currency'<>'INR' then raise exception 'Create an INR pot first'; end if;
  if nullif(trim(t.destination),'') is null or t.start_date is null or t.end_date is null
    or t.start_date<current_date or t.end_date-t.start_date not between 0 and 13 then
    raise exception 'Set a destination and future trip dates (up to 14 days)'; end if;
  if jsonb_typeof(p_settings) is distinct from 'object' then raise exception 'Invalid settings'; end if;
  foreach k in array array['rooms','adults_per_room','food_daily_minor','transport_daily_minor','activity_daily_minor','journey_minor'] loop
    if p_settings->>k is null or p_settings->>k !~ '^\d{1,10}$' then raise exception 'Invalid %',k; end if;
    amount:=(p_settings->>k)::bigint;
    if amount>1000000000 or (k in ('rooms','adults_per_room') and amount not between 1 and 20) then
      raise exception 'Invalid %',k; end if;
  end loop;
  if (p_settings->>'adults_per_room')::integer>4 or
    (p_settings->>'rooms')::integer*(p_settings->>'adults_per_room')::integer<jsonb_array_length(c->'members') then
    raise exception 'Room occupancy must cover all current travelers (1–4 adults per room)'; end if;
  if p_settings->>'transport_mode' is null or p_settings->>'transport_mode' not in ('walking','transit','driving')
    or length(coalesce(p_settings->>'origin',''))>160 or length(coalesce(p_settings->>'food_preferences',''))>160 then
    raise exception 'Invalid travel preferences'; end if;
  select * into p from trip_planners where trip_id=p_trip_id for update;
  if coalesce(p.revision,0)<>p_revision then raise exception 'Plan changed; refresh before saving'; end if;
  if p.requested_at>now()-interval '1 minute' then raise exception 'Wait one minute before requesting another plan'; end if;
  insert into trip_planners(trip_id,settings,context,state)
    values(p_trip_id,p_settings,c,case when planner_funded(p_trip_id) then 'queued' else 'waiting' end)
    on conflict(trip_id) do update set settings=excluded.settings,context=excluded.context,revision=trip_planners.revision+1,
      state=excluded.state,run_id=gen_random_uuid(),result=null,error=null,attempts=0,lease_id=null,leased_until=null,
      requested_at=now(),generated_at=null,shared_at=null,selected_option=null;
  return planner_state(p_trip_id);
end $$;

-- One leased job per invocation; concurrent schedulers cannot double-publish results.
create function public.planner_claim(p_trip_id uuid default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p trip_planners; c jsonb;
begin
  for p in select q.* from trip_planners q join trips t on t.id=q.trip_id
    where (p_trip_id is null or q.trip_id=p_trip_id) and t.archived_at is null
      and t.start_date>=current_date order by q.requested_at for update of q skip locked loop
    c:=planner_context(p.trip_id);
    if c is distinct from p.context then
      update trip_planners set context=c,state='waiting',run_id=gen_random_uuid(),result=null,error=null,
        lease_id=null,leased_until=null,attempts=0,generated_at=null,shared_at=null,selected_option=null,revision=revision+1
        where trip_id=p.trip_id returning * into p;
    end if;
    if not planner_funded(p.trip_id) then continue; end if;
    if p.state not in ('waiting','queued','running') or (p.state='running' and p.leased_until>now()) then continue; end if;
    if p.attempts>=3 then
      update trip_planners set state='failed',error='Planning timed out. Request a fresh plan.' where trip_id=p.trip_id;
      continue;
    end if;
    update trip_planners set state='running',lease_id=gen_random_uuid(),leased_until=now()+interval '3 minutes',
      attempts=attempts+1 where trip_id=p.trip_id returning * into p;
    return to_jsonb(p);
  end loop;
  return null;
end $$;
create function public.planner_complete(p_trip_id uuid,p_lease_id uuid,p_result jsonb,p_error text default null) returns boolean
language plpgsql security definer set search_path=public as $$
declare p trip_planners; owner uuid;
begin
  -- Same trip-first lock order as commands/configure/publish.
  select organizer_user_id into owner from trips where id=p_trip_id for update;
  select * into p from trip_planners where trip_id=p_trip_id for update;
  if not found or p.lease_id is distinct from p_lease_id or p.state<>'running' or p.leased_until<now() then return false; end if;
  if p.context is distinct from planner_context(p_trip_id) or not planner_funded(p_trip_id) then
    update trip_planners set state='waiting',lease_id=null,leased_until=null where trip_id=p_trip_id;
    return false;
  end if;
  if p_error is null and (jsonb_typeof(p_result->'options') is distinct from 'array' or
    jsonb_array_length(p_result->'options')>3) then raise exception 'Invalid generated plan'; end if;
  update trip_planners set result=p_result,state=case when p_error is null then 'ready' else 'failed' end,
    error=left(p_error,400),generated_at=now(),lease_id=null,leased_until=null where trip_id=p_trip_id;
  insert into trip_notifications(user_id,trip_id,title,dedupe_key) values(owner,p_trip_id,
    case when p_error is null then 'Your funded trip plan is ready to review' else 'Your trip plan needs attention' end,
    'planner:'||p.run_id) on conflict do nothing;
  return true;
end $$;

-- Dedicated columns cannot be forged through save_entry's editable details JSON.
alter table public.trip_entries add column planner_key text;
alter table public.trip_entries add column planner_version integer;
create unique index planner_entry_key on public.trip_entries(trip_id,planner_key)
  where planner_key is not null;
create function public.planner_publish(p_trip_id uuid,p_run_id uuid,p_option integer) returns jsonb
language plpgsql security definer set search_path=public as $$
declare p trip_planners; t trips; option jsonb; item jsonb; d jsonb; keys text[]:=array[]::text[]; kept integer:=0; changed integer:=0; affected integer;
begin
  select * into t from trips where id=p_trip_id for update;
  if auth.uid() is null or not is_trip_member(p_trip_id) or t.organizer_user_id<>auth.uid() then raise exception 'Organizer access required'; end if;
  if t.archived_at is not null then raise exception 'Trip archived'; end if;
  select * into p from trip_planners where trip_id=p_trip_id for update;
  if not found or p.run_id<>p_run_id then raise exception 'Plan changed; refresh'; end if;
  if p.state='shared' and p.selected_option=p_option then return jsonb_build_object('already_shared',true); end if;
  if p.state<>'ready' or p.context is distinct from planner_context(p_trip_id) or not planner_funded(p_trip_id)
    then raise exception 'Refresh a funded plan before sharing'; end if;
  if p.generated_at<now()-interval '24 hours' then raise exception 'Prices are old; request a fresh plan'; end if;
  if p_option<0 or p_option>=jsonb_array_length(p.result->'options') then raise exception 'Invalid option'; end if;
  option:=p.result->'options'->p_option;
  if (option->>'total_minor')::bigint>(p.context->>'budget_minor')::bigint then raise exception 'Option exceeds the pot'; end if;
  if jsonb_typeof(option->'entries') is distinct from 'array' or jsonb_array_length(option->'entries')>180 then raise exception 'Invalid entries'; end if;
  for item in select value from jsonb_array_elements(option->'entries') loop
    if item->>'kind' not in ('itinerary','booking','task') or nullif(item->>'key','') is null then raise exception 'Invalid generated entry'; end if;
    d:=(item->'details')||jsonb_build_object('planner_key',item->>'key','planner_run',p.run_id);
    if item->>'kind'='booking' then d:=d||jsonb_build_object('booking_status','planned','reference','','assigned_to',auth.uid()); end if;
    keys:=array_append(keys,item->>'key');
    insert into trip_entries(trip_id,kind,title,details,created_by,planner_key,planner_version)
      values(p_trip_id,item->>'kind',item->>'title',d,auth.uid(),item->>'key',1)
      on conflict(trip_id,planner_key) where planner_key is not null
      do update set title=excluded.title,details=excluded.details,updated_at=now(),
        version=trip_entries.version+1,planner_version=trip_entries.version+1
        where trip_entries.version=trip_entries.planner_version and trip_entries.deleted_at is null;
    get diagnostics affected=row_count;
    if affected=0 then kept:=kept+1; else changed:=changed+1; end if;
  end loop;
  -- Preserve anything edited, completed, confirmed or removed by a traveler.
  update trip_entries set deleted_at=now(),version=version+1 where trip_id=p_trip_id and planner_key is not null
    and not(planner_key=any(keys)) and version=planner_version and deleted_at is null;
  insert into trip_entries(trip_id,kind,title,details,created_by) values(p_trip_id,'announcement',
    'The trip plan is ready',jsonb_build_object('notes',option->>'summary','planner_run',p.run_id),auth.uid());
  insert into trip_activity(trip_id,actor_id,action,detail) values(p_trip_id,auth.uid(),'planner_publish','Shared the funded trip itinerary and booking checklist');
  insert into trip_notifications(user_id,trip_id,title,dedupe_key)
    select user_id,p_trip_id,'Your trip itinerary is ready','plan-shared:'||p.run_id from trip_members
    where trip_id=p_trip_id and membership_status='joined' and user_id<>auth.uid() on conflict do nothing;
  update trip_planners set state='shared',shared_at=now(),selected_option=p_option where trip_id=p_trip_id;
  return jsonb_build_object('updated',changed,'preserved',kept);
end $$;
revoke all on function public.planner_context(uuid),public.planner_funded(uuid),public.planner_claim(uuid),
  public.planner_complete(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.planner_claim(uuid),public.planner_complete(uuid,uuid,jsonb,text) to service_role;
revoke all on function public.planner_state(uuid),public.planner_configure(uuid,jsonb,integer),public.planner_publish(uuid,uuid,integer) from public,anon;
grant execute on function public.planner_state(uuid),public.planner_configure(uuid,jsonb,integer),public.planner_publish(uuid,uuid,integer) to authenticated;
