-- Ephemeral trails belong to a currently shared location. Every existing stop,
-- pause, removal and expiry path deletes the parent and cascades to the trail.
create table public.live_location_trail (
  session_id uuid not null,
  user_id uuid not null,
  sequence_number bigint not null,
  latitude double precision not null,
  longitude double precision not null,
  accuracy_m double precision not null,
  received_at timestamptz not null,
  primary key (session_id,user_id,sequence_number),
  foreign key (session_id,user_id) references public.live_locations on delete cascade
);
alter table public.live_location_trail enable row level security;
revoke all on public.live_location_trail from public,anon,authenticated;
create index live_trail_expiry on public.live_location_trail(received_at);

create function public.live_map_record_trail() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if exists(select 1 from location_sharing_consents where session_id=new.session_id and user_id=new.user_id
      and consent_version='live-map-v2' and sharing_status='sharing') then
    insert into live_location_trail values(new.session_id,new.user_id,new.sequence_number,
      new.latitude,new.longitude,new.accuracy_m,new.received_at) on conflict do nothing;
    delete from live_location_trail where session_id=new.session_id and user_id=new.user_id
      and (received_at<now()-interval '15 minutes' or sequence_number<new.sequence_number-179);
  end if;
  return new;
end $$;
create trigger record_live_trail after insert or update on public.live_locations
for each row execute function public.live_map_record_trail();
revoke all on function public.live_map_record_trail() from public,anon,authenticated;

-- Preserve the hardened command implementation and idempotency receipts.
alter function public.live_map_command(text,jsonb,uuid) rename to live_map_command_without_trails;
revoke all on function public.live_map_command_without_trails(text,jsonb,uuid) from public,anon,authenticated;
create function public.live_map_command(p_action text,p_data jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if p_data ? 'trail_consent' then raise exception 'Reserved consent field'; end if;
  if p_action='consent' and p_data->>'consent_version'='live-map-v2' then
    result:=live_map_command_without_trails(p_action,p_data||jsonb_build_object('consent_version','live-map-v1','trail_consent','live-map-v2'),p_request_id);
    update location_sharing_consents set consent_version='live-map-v2'
      where session_id=(p_data->>'session_id')::uuid and user_id=auth.uid()
        and generation=(result->>'generation')::bigint and sharing_status='sharing';
    return result;
  end if;
  -- Old clients may still share their latest point, but do not opt into trails.
  result:=live_map_command_without_trails(p_action,p_data,p_request_id);
  if p_action='consent' then
    update location_sharing_consents set consent_version='live-map-v1'
      where session_id=(p_data->>'session_id')::uuid and user_id=auth.uid()
        and generation=(result->>'generation')::bigint and sharing_status='sharing';
  end if;
  return result;
end $$;
revoke all on function public.live_map_command(text,jsonb,uuid) from public,anon;
grant execute on function public.live_map_command(text,jsonb,uuid) to authenticated;

alter function public.live_map_snapshot(uuid) rename to live_map_snapshot_without_trails;
revoke all on function public.live_map_snapshot_without_trails(uuid) from public,anon,authenticated;
create function public.live_map_snapshot(p_session_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  result:=live_map_snapshot_without_trails(p_session_id);
  return result||jsonb_build_object('trails',coalesce((select jsonb_agg(to_jsonb(t) order by t.received_at,t.sequence_number)
    from live_location_trail t where t.session_id=p_session_id and t.received_at>now()-interval '15 minutes'
      and exists(select 1 from jsonb_array_elements(result->'locations') l where l->>'user_id'=t.user_id::text)), '[]'::jsonb));
end $$;
revoke all on function public.live_map_snapshot(uuid) from public,anon;
grant execute on function public.live_map_snapshot(uuid) to authenticated;
