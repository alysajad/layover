-- Full trip companion. External transfers are never provider confirmations.
begin;

alter table public.trips add column archived_at timestamptz;
alter table public.trips add column whatsapp_url text;
alter table public.profiles add column reminders_enabled boolean not null default true;
alter table public.profiles add column deletion_requested_at timestamptz;
alter table public.pots add column funding_basis text not null default 'manual_acknowledgment';
alter table public.pots add column organizer_cover_minor bigint not null default 0
  check (organizer_cover_minor between 0 and target_minor_units);

create table public.trip_entries (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id),
  kind text not null check (kind in ('poll','shortlist','itinerary','booking','task','meeting','announcement','contact')),
  title text not null check (char_length(title) between 1 and 240),
  details jsonb not null default '{}',
  created_by uuid not null references public.profiles(id),
  version int not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (jsonb_typeof(details) = 'object' and octet_length(details::text) < 20000)
);
create table public.entry_responses (
  entry_id uuid not null references public.trip_entries(id),
  user_id uuid not null references public.profiles(id),
  response jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (entry_id,user_id)
);
create table public.entry_comments (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.trip_entries(id),
  user_id uuid not null references public.profiles(id),
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create table public.trip_expenses (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id),
  title text not null check (char_length(title) between 1 and 240),
  payer_id uuid not null references public.profiles(id),
  amount_minor bigint not null check (amount_minor between 1 and 99999999999),
  category text not null default 'Other',
  split_mode text not null check (split_mode in ('equal','exact','percentage','weighted')),
  splits jsonb not null,
  receipt_path text,
  created_by uuid not null references public.profiles(id),
  voided_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.manual_transfers (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id),
  pot_id uuid references public.pots(id),
  sender_id uuid not null references public.profiles(id),
  recipient_id uuid not null references public.profiles(id),
  amount_minor bigint not null check (amount_minor between 1 and 99999999999),
  status text not null default 'reported' check (status in ('reported','acknowledged','disputed','withdrawn')),
  note text not null default '' check (char_length(note) <= 1000),
  replaces_id uuid unique references public.manual_transfers(id),
  acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);
create table public.trip_activity (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id),
  actor_id uuid references public.profiles(id),
  action text not null,
  detail text not null,
  created_at timestamptz not null default now()
);
create table public.pot_revisions (
  pot_id uuid not null references public.pots(id),
  version int not null,
  terms text not null,
  shares jsonb not null,
  deadline_at timestamptz not null,
  created_at timestamptz not null default now(),
  primary key(pot_id,version)
);
create table public.term_acceptances (
  pot_id uuid not null references public.pots(id),
  version int not null,
  user_id uuid not null references public.profiles(id),
  accepted_at timestamptz not null default now(),
  primary key(pot_id,version,user_id),
  foreign key(pot_id,version) references public.pot_revisions(pot_id,version)
);
create table public.trip_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  trip_id uuid not null references public.trips(id),
  title text not null,
  dedupe_key text not null,
  read_at timestamptz,
  pushed_at timestamptz,
  claimed_until timestamptz,
  created_at timestamptz not null default now(),
  unique(user_id,dedupe_key)
);
create table public.device_tokens (
  token text primary key,
  user_id uuid not null references public.profiles(id),
  updated_at timestamptz not null default now()
);
create table public.command_receipts (
  user_id uuid not null references public.profiles(id),
  request_id uuid not null,
  input jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(user_id,request_id)
);
create index on public.trip_entries(trip_id,kind) where deleted_at is null;
create index on public.trip_expenses(trip_id);
create index on public.manual_transfers(trip_id,status);
create index on public.trip_activity(trip_id,created_at desc);
create index on public.trip_notifications(user_id,created_at desc);

create or replace function public.is_trip_member(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from trip_members where trip_id=p_trip and user_id=auth.uid() and membership_status='joined');
$$;

create function public.active_member(p_trip uuid,p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from trip_members where trip_id=p_trip and user_id=p_user and membership_status='joined');
$$;

-- The server computes shares; clients send inputs, never authoritative balances.
create function public.calculate_shares(p_amount bigint,p_weights jsonb,p_mode text,p_remainder uuid default null)
returns jsonb language plpgsql set search_path = public as $$
declare total numeric; result jsonb; rest bigint; k text;
begin
  if p_amount is null or p_amount not between 1 and 99999999999 or jsonb_typeof(p_weights) is distinct from 'object'
     or p_weights='{}' or p_mode is null or p_mode not in ('equal','exact','percentage','weighted') then
    raise exception 'Invalid amount or split';
  end if;
  if exists(select 1 from jsonb_each_text(p_weights) where value !~ '^\d{1,12}$') then
    raise exception 'Shares must be nonnegative integers';
  end if;
  if p_mode='equal' then select jsonb_object_agg(key,1) into p_weights from jsonb_each(p_weights); end if;
  select sum(value::numeric) into total from jsonb_each_text(p_weights);
  if total<=0 or (p_mode='percentage' and total<>10000) or (p_mode='exact' and total<>p_amount) then
    raise exception 'Shares do not reconcile with total';
  end if;
  if p_mode='exact' then return p_weights; end if;
  select jsonb_object_agg(key,floor(p_amount*value::numeric/total)::bigint) into result from jsonb_each_text(p_weights);
  select p_amount-sum(value::bigint) into rest from jsonb_each_text(result);
  if p_remainder is not null and result ? p_remainder::text then
    result=jsonb_set(result,array[p_remainder::text],to_jsonb((result->>p_remainder::text)::bigint+rest));
  else
    for k in select key from jsonb_each_text(p_weights) order by mod(p_amount*value::numeric,total) desc,key loop
      exit when rest=0;
      result=jsonb_set(result,array[k],to_jsonb((result->>k)::bigint+1)); rest=rest-1;
    end loop;
  end if;
  return result;
end $$;

create function public.companion_snapshot() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid=auth.uid(); tids uuid[]; result jsonb;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  select coalesce(array_agg(trip_id),'{}') into tids from trip_members where user_id=uid and membership_status='joined';
  select jsonb_build_object(
    'trips',(select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc),'[]') from trips t where id=any(tids)),
    'members',(select coalesce(jsonb_agg(to_jsonb(m)||jsonb_build_object('display_name',p.display_name)),'[]') from trip_members m join profiles p on p.id=m.user_id where m.trip_id=any(tids)),
    'entries',(select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at),'[]') from trip_entries e where trip_id=any(tids) and deleted_at is null),
    'responses',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from entry_responses r join trip_entries e on e.id=r.entry_id where e.trip_id=any(tids) and e.deleted_at is null),
    'comments',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]') from entry_comments c join trip_entries e on e.id=c.entry_id where e.trip_id=any(tids) and e.deleted_at is null),
    'pots',(select coalesce(jsonb_agg(to_jsonb(p)),'[]') from pots p where trip_id=any(tids)),
    'obligations',(select coalesce(jsonb_agg(to_jsonb(o)),'[]') from contribution_obligations o join pots p on p.id=o.pot_id where p.trip_id=any(tids)),
    'expenses',(select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc),'[]') from trip_expenses e where trip_id=any(tids)),
    'transfers',(select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc),'[]') from manual_transfers t where trip_id=any(tids)),
    'notifications',(select coalesce(jsonb_agg(to_jsonb(n) order by n.created_at desc),'[]') from trip_notifications n where user_id=uid and trip_id=any(tids)),
    'activity',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]') from (select * from trip_activity where trip_id=any(tids) order by created_at desc limit 300) a),
    'invites',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'trip_id',i.trip_id,'expires_at',i.expires_at,'revoked_at',i.revoked_at,'use_count',i.use_count)),'[]') from invites i join trips t on t.id=i.trip_id where t.organizer_user_id=uid),
    'profile',(select to_jsonb(p) from profiles p where id=uid)
  ) into result;
  return result;
end $$;

create function public.companion_command(p_action text,p_data jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid=auth.uid(); tid uuid; rid uuid; owner uuid; obj trip_entries; pot pots;
  transfer manual_transfers; expense trip_expenses; inv invites; old command_receipts;
  result jsonb='{}'; shares jsonb; detail text=p_action; key text; token text;
  amount bigint; mode text; state text; member_balance bigint; before jsonb; oldtrip uuid;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  if p_request_id is null or p_data is null or octet_length(p_data::text)>50000 then raise exception 'Invalid request'; end if;
  -- Serialize retries before looking up their receipt, including trip creation.
  perform pg_advisory_xact_lock(hashtextextended(uid::text||p_request_id::text,0));
  select * into old from command_receipts where user_id=uid and request_id=p_request_id;
  if found then
    if old.input<>jsonb_build_object('action',p_action,'data',p_data) then raise exception 'Request ID reused with different input'; end if;
    return old.result;
  end if;

  if p_action='profile' then
    update profiles set display_name=coalesce(nullif(left(trim(p_data->>'name'),80),''),display_name),
      reminders_enabled=coalesce((p_data->>'reminders_enabled')::boolean,reminders_enabled),
      deletion_requested_at=case when p_data->>'request_deletion'='true' then now() else deletion_requested_at end
      where id=uid;
  elsif p_action='device_token' then
    token=p_data->>'token';
    if length(token) not between 20 and 4096 then raise exception 'Invalid device token'; end if;
    if p_data->>'remove'='true' then delete from device_tokens where device_tokens.token=token and user_id=uid;
    else insert into device_tokens values(token,uid,now()) on conflict on constraint device_tokens_pkey do update set user_id=uid,updated_at=now(); end if;
  elsif p_action='read_notification' then
    update trip_notifications set read_at=now() where id=(p_data->>'id')::uuid and user_id=uid;
  elsif p_action in ('create_trip','duplicate_trip') then
    if p_action='duplicate_trip' then
      oldtrip=(p_data->>'source_id')::uuid;
      if not is_trip_member(oldtrip) then raise exception 'Trip access denied'; end if;
    end if;
    insert into trips(organizer_user_id,title,destination,start_date,end_date)
      values(uid,trim(p_data->>'title'),nullif(trim(p_data->>'destination'),''),nullif(p_data->>'start_date','')::date,nullif(p_data->>'end_date','')::date) returning id into tid;
    insert into trip_members(trip_id,user_id,role,membership_status,joined_at) values(tid,uid,'organizer','joined',now());
    if oldtrip is not null then
      insert into trip_entries(trip_id,kind,title,details,created_by)
        select tid,kind,title,details-'date'-'time'-'assigned_to'-'attachment'-'remind_at'||jsonb_build_object('done',false),uid
        from trip_entries where trip_id=oldtrip and kind in ('itinerary','task') and deleted_at is null;
    end if;
    result=jsonb_build_object('trip_id',tid); detail='Created trip';
  elsif p_action='join_trip' then
    select * into inv from invites where token_hash=encode(sha256(convert_to(p_data->>'token','UTF8')),'hex') for update;
    if not found or inv.revoked_at is not null or inv.expires_at<=now() then raise exception 'Invite expired or revoked'; end if;
    tid=inv.trip_id;
    perform 1 from trips where id=tid and archived_at is null for update;
    if not found then raise exception 'Trip is archived'; end if;
    if exists(select 1 from trip_members where trip_id=tid and user_id=uid and membership_status='removed') then raise exception 'Membership was removed'; end if;
    if not active_member(tid,uid) then
      if inv.use_count>=inv.max_uses then raise exception 'Invite is full'; end if;
      if (select count(*) from trip_members where trip_id=tid and membership_status='joined')>=50 then raise exception 'Trip is full'; end if;
      insert into trip_members(trip_id,user_id,role,membership_status,joined_at) values(tid,uid,'participant','joined',now())
        on conflict(trip_id,user_id) do update set membership_status='joined',joined_at=now();
      update invites set use_count=use_count+1 where id=inv.id;
    end if;
    result=jsonb_build_object('trip_id',tid); detail='Joined trip';
  else
    tid=(p_data->>'trip_id')::uuid;
    select organizer_user_id into owner from trips where id=tid for update;
    if not found or not active_member(tid,uid) then raise exception 'Trip access denied'; end if;
    if exists(select 1 from trips where id=tid and archived_at is not null) and p_action<>'archive_trip' then raise exception 'Trip is archived'; end if;

    if p_action='invite' then
      if uid<>owner then raise exception 'Only organizer can invite'; end if;
      token=encode(gen_random_bytes(24),'hex');
      insert into invites(trip_id,token_hash,created_by,expires_at,max_uses) values(tid,encode(sha256(convert_to(token,'UTF8')),'hex'),uid,now()+interval '7 days',50);
      result=jsonb_build_object('token',token); detail='Created invite';
    elsif p_action='revoke_invite' then
      if uid<>owner then raise exception 'Only organizer can revoke'; end if;
      update invites set revoked_at=now() where id=(p_data->>'id')::uuid and trip_id=tid;
      detail='Revoked invite';
    elsif p_action='update_trip' then
      if uid<>owner then raise exception 'Only organizer can edit trip details'; end if;
      if (select updated_at from trips where id=tid) is distinct from (p_data->>'expected_updated_at')::timestamptz then raise exception 'Trip changed. Refresh and try again'; end if;
      update trips set title=trim(p_data->>'title'),destination=nullif(trim(p_data->>'destination'),''),
        start_date=nullif(p_data->>'start_date','')::date,end_date=nullif(p_data->>'end_date','')::date,updated_at=now() where id=tid;
      detail='Updated trip dates and details';
    elsif p_action='archive_trip' then
      if uid<>owner then raise exception 'Only organizer can archive'; end if;
      update trips set archived_at=case when p_data->>'archived'='true' then now() else null end where id=tid;
      detail='Updated archive status';
    elsif p_action='whatsapp' then
      if uid<>owner then raise exception 'Only organizer can change group link'; end if;
      if coalesce(p_data->>'url','')<>'' and p_data->>'url' !~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]+$' then raise exception 'Use a WhatsApp group invite URL'; end if;
      update trips set whatsapp_url=nullif(p_data->>'url','') where id=tid; detail='Updated WhatsApp link';
    elsif p_action='remove_member' then
      rid=(p_data->>'user_id')::uuid;
      if (uid<>owner and uid<>rid) or rid=owner then raise exception 'Cannot remove this member'; end if;
      select coalesce((select sum(case when payer_id=rid then amount_minor else 0 end-coalesce((splits->>rid::text)::bigint,0)) from trip_expenses where trip_id=tid and voided_at is null),0)
        +coalesce((select sum(case when sender_id=rid then amount_minor else -amount_minor end) from manual_transfers where trip_id=tid and status='acknowledged' and (sender_id=rid or recipient_id=rid)),0) into member_balance;
      if member_balance<>0 or exists(select 1 from manual_transfers where trip_id=tid and status in ('reported','disputed') and (sender_id=rid or recipient_id=rid)) then
        raise exception 'Settle this member and resolve pending transfers before removing access';
      end if;
      update trip_members set membership_status=case when rid=uid then 'left'::membership_status else 'removed'::membership_status end where trip_id=tid and user_id=rid;
      detail='Member left; existing financial records retained';
    elsif p_action='reinvite_member' then
      if uid<>owner then raise exception 'Only organizer can invite members back'; end if;
      update trip_members set membership_status='invited' where trip_id=tid and user_id=(p_data->>'user_id')::uuid and membership_status in ('removed','left');
      if not found then raise exception 'Member is not eligible for a new invitation'; end if;
      detail='Member may rejoin with an active invite';
    elsif p_action='save_entry' then
      rid=nullif(p_data->>'id','')::uuid;
      before=coalesce(p_data->'details','{}')-'selected'-'choice';
      if coalesce(p_data->>'kind','') not in ('poll','shortlist','itinerary','booking','task','meeting','announcement','contact') then raise exception 'Unknown entry type'; end if;
      if (p_data->>'kind')='announcement' and uid<>owner then raise exception 'Only organizer can post announcements'; end if;
      if coalesce(before->>'url','')<>'' and before->>'url' !~ '^https?://[^\s]+$' then raise exception 'Use an HTTP or HTTPS link'; end if;
      if coalesce(before->>'assigned_to','')<>'' and not active_member(tid,(before->>'assigned_to')::uuid) then raise exception 'Assignee must be a member'; end if;
      if coalesce(before->>'attachment','')<>'' and split_part(before->>'attachment','/',1)<>tid::text then raise exception 'Invalid attachment'; end if;
      if before ? 'remind_at' and nullif(before->>'remind_at','') is not null then perform (before->>'remind_at')::timestamptz; end if;
      if p_data->>'kind'='poll' and (jsonb_typeof(before->'options') is distinct from 'array' or jsonb_array_length(before->'options') not between 2 and 12) then raise exception 'Poll needs 2 to 12 options'; end if;
      if rid is null then
        insert into trip_entries(trip_id,kind,title,details,created_by) values(tid,p_data->>'kind',trim(p_data->>'title'),before,uid) returning id into rid;
      else
        select * into obj from trip_entries where id=rid and trip_id=tid and deleted_at is null;
        if not found or (obj.created_by<>uid and uid<>owner) then raise exception 'Entry access denied'; end if;
        if obj.version is distinct from (p_data->>'version')::int then raise exception 'Entry changed. Refresh and try again'; end if;
        if obj.details ? 'selected' then before=before||jsonb_build_object('selected',obj.details->'selected','choice',obj.details->'choice'); end if;
        if obj.kind<>p_data->>'kind' then raise exception 'Cannot change entry type'; end if;
        if obj.kind='poll' and obj.details->'options' is distinct from before->'options' then
          if exists(select 1 from entry_responses where entry_id=rid) then raise exception 'Create a new poll to change options after voting'; end if;
        end if;
        update trip_entries set title=trim(p_data->>'title'),details=before,version=version+1,updated_at=now() where id=rid;
      end if;
      result=jsonb_build_object('id',rid); detail='Saved '||(p_data->>'kind')||': '||left(p_data->>'title',120);
    elsif p_action in ('delete_entry','toggle_task','respond','comment','choose_entry') then
      rid=(p_data->>'id')::uuid;
      select * into obj from trip_entries where id=rid and trip_id=tid and deleted_at is null;
      if not found then raise exception 'Entry not found'; end if;
      if p_action='delete_entry' then
        if uid<>owner and uid<>obj.created_by then raise exception 'Entry access denied'; end if;
        update trip_entries set deleted_at=now(),version=version+1 where id=rid; detail='Removed '||obj.title;
      elsif p_action='toggle_task' then
        if obj.kind<>'task' or (uid<>owner and uid<>obj.created_by and coalesce(obj.details->>'assigned_to','')<>uid::text) then raise exception 'Task access denied'; end if;
        update trip_entries set details=details||jsonb_build_object('done',(p_data->>'done')::boolean),version=version+1,updated_at=now() where id=rid; detail='Updated task: '||obj.title;
      elsif p_action='comment' then
        insert into entry_comments(entry_id,user_id,body) values(rid,uid,trim(p_data->>'body')); detail='Commented on '||obj.title;
      elsif p_action='choose_entry' then
        if uid<>owner or obj.kind not in ('shortlist','poll') then raise exception 'Only organizer can select'; end if;
        if obj.kind='poll' and not (obj.details->'options' @> jsonb_build_array(p_data->>'choice')) then raise exception 'Unknown poll option'; end if;
        update trip_entries set details=details||jsonb_build_object('selected',true,'choice',p_data->>'choice'),version=version+1 where id=rid; detail='Selected '||obj.title;
      else
        if obj.kind not in ('poll','shortlist','meeting') then raise exception 'Responses not supported'; end if;
        if obj.details->>'selected'='true' then raise exception 'Decision is closed'; end if;
        before=jsonb_build_object('choice',p_data->>'choice');
        if obj.kind='poll' and obj.details->>'poll_type'='Dates' then
          shares=coalesce(p_data->'choices',jsonb_build_array(p_data->>'choice'));
          if jsonb_typeof(shares) is distinct from 'array' or jsonb_array_length(shares)>12 or not(obj.details->'options' @> shares) then raise exception 'Unknown poll option'; end if;
          before=jsonb_build_object('choices',shares);
        elsif obj.kind='poll' and not(obj.details->'options' @> jsonb_build_array(p_data->>'choice')) then raise exception 'Unknown poll option'; end if;
        if obj.kind='shortlist' and coalesce(p_data->>'choice','') not in ('yes','no') then raise exception 'Invalid vote'; end if;
        if obj.kind='meeting' and coalesce(p_data->>'choice','') not in ('arrived','on_my_way') then raise exception 'Invalid check-in'; end if;
        insert into entry_responses(entry_id,user_id,response) values(rid,uid,before)
          on conflict(entry_id,user_id) do update set response=excluded.response,updated_at=now(); detail='Responded to '||obj.title;
      end if;
    elsif p_action in ('save_pot','add_expense') then
      amount=(p_data->>'amount_minor')::bigint; mode=p_data->>'split_mode';
      shares=calculate_shares(amount,p_data->'weights',mode,case when p_action='save_pot' then owner else null end);
      for key in select jsonb_object_keys(shares) loop
        if not active_member(tid,key::uuid) then raise exception 'Every share must belong to an active member'; end if;
      end loop;
      if p_action='save_pot' then
        if uid<>owner then raise exception 'Only organizer can change pot'; end if;
        if nullif(trim(p_data->>'terms'),'') is null or length(p_data->>'terms')>4000 then raise exception 'Terms are required (up to 4000 characters)'; end if;
        if (p_data->>'deadline_at')::timestamptz<=now() then raise exception 'Deadline must be in the future'; end if;
        select * into pot from pots where trip_id=tid;
        if found then
          if pot.version is distinct from (p_data->>'version')::int then raise exception 'Pot changed. Refresh and try again'; end if;
          if pot.status in ('booked','cancelled','closed') then raise exception 'Pot is closed to changes'; end if;
          update pots set target_minor_units=amount,organizer_cover_minor=coalesce((p_data->>'organizer_cover_minor')::bigint,0),title=trim(p_data->>'title'),deadline_at=(p_data->>'deadline_at')::timestamptz,
            terms_text=p_data->>'terms',terms_version=terms_version+1,version=version+1,status='open' where id=pot.id returning * into pot;
        else
          insert into pots(trip_id,title,target_minor_units,currency,deadline_at,terms_text,status,contribution_mode,participant_cap,organizer_cover_minor)
            values(tid,trim(p_data->>'title'),amount,'INR',(p_data->>'deadline_at')::timestamptz,p_data->>'terms','open','fixed',50,coalesce((p_data->>'organizer_cover_minor')::bigint,0)) returning * into pot;
        end if;
        insert into pot_revisions(pot_id,version,terms,shares,deadline_at) values(pot.id,pot.terms_version,pot.terms_text,shares,pot.deadline_at);
        update contribution_obligations set obligation_status='cancelled',accepted_at=null,accepted_terms_version=null where pot_id=pot.id;
        for key in select jsonb_object_keys(shares) loop
          insert into contribution_obligations(pot_id,user_id,amount_minor_units,currency) values(pot.id,key::uuid,(shares->>key)::bigint,'INR')
            on conflict(pot_id,user_id) do update set amount_minor_units=excluded.amount_minor_units,obligation_status='proposed',accepted_at=null,accepted_terms_version=null;
        end loop;
        detail='Proposed pot terms version '||pot.terms_version;
      else
        if not active_member(tid,(p_data->>'payer_id')::uuid) then raise exception 'Payer must be an active member'; end if;
        if coalesce(p_data->>'receipt_path','')<>'' and split_part(p_data->>'receipt_path','/',1)<>tid::text then raise exception 'Invalid receipt'; end if;
        insert into trip_expenses(trip_id,title,payer_id,amount_minor,category,split_mode,splits,receipt_path,created_by)
          values(tid,trim(p_data->>'title'),(p_data->>'payer_id')::uuid,amount,left(coalesce(p_data->>'category','Other'),60),mode,shares,nullif(p_data->>'receipt_path',''),uid) returning id into rid;
        result=jsonb_build_object('id',rid); detail='Recorded expense: '||left(p_data->>'title',120);
      end if;
    elsif p_action='void_expense' then
      select * into expense from trip_expenses where id=(p_data->>'id')::uuid and trip_id=tid and (created_by=uid or owner=uid) and voided_at is null;
      if not found then raise exception 'Expense access denied'; end if;
      if not active_member(tid,expense.payer_id) or exists(select 1 from jsonb_object_keys(expense.splits) as s(id) where not active_member(tid,s.id::uuid)) then
        raise exception 'Affected former members must rejoin before this expense can be corrected';
      end if;
      update trip_expenses set voided_at=now() where id=(p_data->>'id')::uuid and trip_id=tid and (created_by=uid or owner=uid) and voided_at is null;
      if not found then raise exception 'Expense access denied'; end if; detail='Voided expense; original retained';
    elsif p_action='accept_terms' then
      select * into pot from pots where trip_id=tid;
      if not found or pot.terms_version is distinct from (p_data->>'version')::int or pot.status not in ('open','funding','target_reached') or pot.deadline_at<=now() then raise exception 'Terms changed or pot closed'; end if;
      update contribution_obligations set obligation_status='accepted',accepted_terms_version=pot.terms_version,accepted_at=now()
        where pot_id=pot.id and user_id=uid and obligation_status<>'cancelled';
      if not found then raise exception 'No share assigned'; end if;
      insert into term_acceptances values(pot.id,pot.terms_version,uid,now()) on conflict do nothing; detail='Accepted current pot terms';
    elsif p_action='pot_outcome' then
      if uid<>owner then raise exception 'Only organizer can record booking outcome'; end if;
      state=p_data->>'status';
      if state not in ('booked','cancelled','closed') then raise exception 'Invalid outcome'; end if;
      select * into pot from pots where trip_id=tid;
      if not found then raise exception 'Pot not found'; end if;
      if state='booked' and pot.status<>'target_reached' then raise exception 'Acknowledged target and current acceptances are required before booking'; end if;
      if pot.status in ('cancelled','closed') then raise exception 'Pot already closed'; end if;
      update pots set status=state::pot_status,version=version+1 where id=pot.id; detail='Organizer reported pot '||state;
    elsif p_action='report_transfer' then
      rid=(p_data->>'recipient_id')::uuid;
      if rid=uid or not active_member(tid,rid) then raise exception 'Choose another active trip member'; end if;
      amount=(p_data->>'amount_minor')::bigint;
      if nullif(p_data->>'pot_id','') is not null then
        select * into pot from pots where id=(p_data->>'pot_id')::uuid and trip_id=tid;
        if not found then raise exception 'Pot not found'; end if;
        if uid=owner then
          if not exists(select 1 from manual_transfers where pot_id=pot.id and sender_id=rid and recipient_id=owner and status='acknowledged') then raise exception 'No acknowledged contribution to reimburse'; end if;
        elsif nullif(p_data->>'replaces_id','') is null then
          if pot.status not in ('open','funding','target_reached') or pot.deadline_at<=now() or rid<>owner then raise exception 'Pot is not accepting contributions'; end if;
          if not exists(select 1 from contribution_obligations where pot_id=pot.id and user_id=uid and accepted_terms_version=pot.terms_version and obligation_status='accepted') then raise exception 'Accept current terms first'; end if;
        end if;
      end if;
      if nullif(p_data->>'replaces_id','') is not null then
        select * into transfer from manual_transfers where id=(p_data->>'replaces_id')::uuid and trip_id=tid and sender_id=uid for update;
        if not found or transfer.status='withdrawn' then raise exception 'Transfer cannot be corrected'; end if;
        if transfer.recipient_id<>rid then raise exception 'Correction must keep original recipient'; end if;
        if transfer.pot_id is distinct from nullif(p_data->>'pot_id','')::uuid then raise exception 'Correction must keep original pot'; end if;
        update manual_transfers set status='withdrawn' where id=transfer.id;
      end if;
      insert into manual_transfers(trip_id,pot_id,sender_id,recipient_id,amount_minor,note,replaces_id)
        values(tid,nullif(p_data->>'pot_id','')::uuid,uid,rid,amount,coalesce(p_data->>'note',''),nullif(p_data->>'replaces_id','')::uuid) returning id into rid;
      result=jsonb_build_object('id',rid); detail='Reported external transfer; recipient acknowledgment pending';
    elsif p_action='transfer_status' then
      select * into transfer from manual_transfers where id=(p_data->>'id')::uuid and trip_id=tid for update;
      if not found then raise exception 'Transfer not found'; end if;
      state=p_data->>'status';
      if transfer.status='withdrawn' then raise exception 'Transfer was withdrawn'; end if;
      if state='withdrawn' then
        if uid<>transfer.sender_id or transfer.status='acknowledged' then raise exception 'Only sender can withdraw an unacknowledged report'; end if;
      elsif state in ('acknowledged','disputed') then
        if uid<>transfer.recipient_id then raise exception 'Only recipient can acknowledge or dispute'; end if;
      else raise exception 'Invalid transfer status'; end if;
      update manual_transfers set status=state,acknowledged_at=case when state='acknowledged' then now() else null end where id=transfer.id;
      detail='Transfer '||state;
    else raise exception 'Unknown action'; end if;
  end if;

  if tid is not null then
    -- Manual collection and provider payment attempts are intentionally separate.
    -- Readiness needs both acknowledged money and acceptance of current terms.
    update pots p set status=case
      when coalesce((select sum(case when t.recipient_id=tr.organizer_user_id then t.amount_minor else -t.amount_minor end)
        from manual_transfers t join trips tr on tr.id=p.trip_id where t.pot_id=p.id and t.status='acknowledged'),0)+p.organizer_cover_minor>=p.target_minor_units
        and not exists(select 1 from contribution_obligations o where o.pot_id=p.id and o.obligation_status<>'cancelled' and (o.accepted_terms_version is distinct from p.terms_version))
      then 'target_reached'::pot_status
      when p.deadline_at<=now() then 'target_missed'::pot_status
      else 'funding'::pot_status end
      where p.trip_id=tid and p.status in ('open','funding','target_reached','target_missed');
    insert into trip_activity(trip_id,actor_id,action,detail) values(tid,uid,p_action,detail);
    if p_action not in ('respond','comment','toggle_task','invite','revoke_invite') then
      insert into trip_notifications(user_id,trip_id,title,dedupe_key)
        select user_id,tid,detail,p_request_id::text from trip_members where trip_id=tid and membership_status='joined' and user_id<>uid
        on conflict do nothing;
    end if;
  end if;
  insert into command_receipts values(uid,p_request_id,jsonb_build_object('action',p_action,'data',p_data),result,now());
  return result;
end $$;

create function public.enqueue_trip_reminders() returns void
language plpgsql security definer set search_path = public as $$
begin
  update pots set status='target_missed',version=version+1 where status in ('open','funding') and deadline_at<=now();
  insert into trip_notifications(user_id,trip_id,title,dedupe_key)
    select o.user_id,p.trip_id,'Pot deadline: '||p.title,'pot:'||p.id||':'||p.terms_version
    from pots p join contribution_obligations o on o.pot_id=p.id join profiles u on u.id=o.user_id
      join trips t on t.id=p.trip_id
    where p.status in ('open','funding') and t.archived_at is null and u.reminders_enabled
      and active_member(p.trip_id,o.user_id) and o.obligation_status<>'cancelled'
      and p.deadline_at between now() and now()+interval '24 hours'
    on conflict do nothing;
  insert into trip_notifications(user_id,trip_id,title,dedupe_key)
    select m.user_id,e.trip_id,'Upcoming: '||e.title,'entry:'||e.id||':'||(e.details->>'remind_at')
    from trip_entries e join trip_members m on m.trip_id=e.trip_id join profiles u on u.id=m.user_id join trips t on t.id=e.trip_id
    where e.deleted_at is null and t.archived_at is null and m.membership_status='joined' and u.reminders_enabled
      and nullif(e.details->>'remind_at','')::timestamptz between now()-interval '24 hours' and now()
    on conflict do nothing;
end $$;

create function public.claim_trip_notifications() returns setof public.trip_notifications
language sql security definer set search_path = public as $$
  update trip_notifications set claimed_until=now()+interval '5 minutes'
  where id in (select id from trip_notifications where pushed_at is null
    and (claimed_until is null or claimed_until<now())
    order by created_at limit 100 for update skip locked)
  returning *;
$$;

do $$ declare tab text; begin
  foreach tab in array array['trip_entries','entry_responses','entry_comments','trip_expenses','manual_transfers','trip_activity','pot_revisions','term_acceptances','trip_notifications','device_tokens','command_receipts'] loop
    execute format('alter table public.%I enable row level security',tab);
  end loop;
end $$;
-- All writes and reads use the checked RPCs. No direct client write policies.
revoke all on function public.companion_snapshot() from public,anon;
revoke all on function public.companion_command(text,jsonb,uuid) from public,anon;
revoke all on function public.calculate_shares(bigint,jsonb,text,uuid) from public,anon,authenticated;
revoke all on function public.active_member(uuid,uuid) from public,anon,authenticated;
revoke all on function public.enqueue_trip_reminders() from public,anon,authenticated;
revoke all on function public.claim_trip_notifications() from public,anon,authenticated;
grant execute on function public.companion_snapshot() to authenticated;
grant execute on function public.companion_command(text,jsonb,uuid) to authenticated;
grant execute on function public.enqueue_trip_reminders() to service_role;
grant execute on function public.claim_trip_notifications() to service_role;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('trip-files','trip-files',false,10485760,array['image/jpeg','image/png','application/pdf']) on conflict(id) do nothing;
create policy trip_files_read on storage.objects for select to authenticated
  using(bucket_id='trip-files' and public.is_trip_member(((storage.foldername(name))[1])::uuid));
create policy trip_files_insert on storage.objects for insert to authenticated
  with check(bucket_id='trip-files' and public.is_trip_member(((storage.foldername(name))[1])::uuid)
    and (storage.foldername(name))[2]=auth.uid()::text);
create policy trip_files_delete on storage.objects for delete to authenticated
  using(bucket_id='trip-files' and (storage.foldername(name))[2]=auth.uid()::text
    and public.is_trip_member(((storage.foldername(name))[1])::uuid));

commit;
