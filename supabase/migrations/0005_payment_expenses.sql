-- Raw payment notifications stay on the device. Only reviewed expenses sync.
begin;

alter table public.trip_expenses add column expense_date date;
update public.trip_expenses set expense_date=created_at::date;
alter table public.trip_expenses alter column expense_date set default current_date;
alter table public.trip_expenses alter column expense_date set not null;
alter table public.trip_expenses add column capture_id uuid;
create unique index trip_expense_capture on public.trip_expenses(created_by,capture_id) where capture_id is not null;

create table public.personal_expenses (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id),
  created_by uuid not null references public.profiles(id),
  title text not null check (char_length(trim(title)) between 1 and 240),
  amount_minor bigint not null check (amount_minor between 1 and 99999999999),
  category text not null check (category in ('Stay','Transport','Food','Activities','Shopping','Other')),
  expense_date date not null,
  capture_id uuid,
  voided_at timestamptz,
  created_at timestamptz not null default now(),
  unique(created_by,capture_id)
);
alter table public.personal_expenses enable row level security;
-- Like the other financial tables, access is exclusively through checked RPCs.

alter function public.companion_snapshot() rename to companion_snapshot_base;
revoke all on function public.companion_snapshot_base() from public,anon,authenticated;
create function public.companion_snapshot() returns jsonb
language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
  result=companion_snapshot_base();
  return result || jsonb_build_object('personal_expenses',(
    select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc),'[]')
    from personal_expenses e where e.created_by=auth.uid() and active_member(e.trip_id,auth.uid())
  ));
end $$;

-- Keep the existing accounting and idempotency implementation for shared data.
alter function public.companion_command(text,jsonb,uuid) rename to companion_command_base;
revoke all on function public.companion_command_base(text,jsonb,uuid) from public,anon,authenticated;
create function public.companion_command(p_action text,p_data jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare uid uuid=auth.uid(); tid uuid; rid uuid; result jsonb; old command_receipts; capture uuid; day date;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  if p_action not in ('add_expense','add_personal_expense','void_personal_expense') then
    return companion_command_base(p_action,p_data,p_request_id);
  end if;
  if p_request_id is null or p_data is null or octet_length(p_data::text)>50000 then raise exception 'Invalid request'; end if;
  capture=nullif(p_data->>'capture_id','')::uuid;
  if capture is not null and capture<>p_request_id then raise exception 'Capture ID must match request ID'; end if;
  day=coalesce(nullif(p_data->>'expense_date','')::date,current_date);
  if day not between date '2000-01-01' and date '2100-12-31' then raise exception 'Invalid expense date'; end if;
  if p_action='add_expense' then
    result=companion_command_base(p_action,p_data,p_request_id);
    update trip_expenses set expense_date=day,capture_id=capture
      where id=(result->>'id')::uuid and created_by=uid;
    return result;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(uid::text||p_request_id::text,0));
  select * into old from command_receipts where user_id=uid and request_id=p_request_id;
  if found then
    if old.input<>jsonb_build_object('action',p_action,'data',p_data) then raise exception 'Request ID reused with different input'; end if;
    return old.result;
  end if;
  tid=(p_data->>'trip_id')::uuid;
  if not active_member(tid,uid) then raise exception 'Trip access denied'; end if;
  perform 1 from trips where id=tid and archived_at is null for update;
  if not found then raise exception 'Trip is archived'; end if;
  if p_action='add_personal_expense' then
    insert into personal_expenses(trip_id,created_by,title,amount_minor,category,expense_date,capture_id)
      values(tid,uid,trim(p_data->>'title'),(p_data->>'amount_minor')::bigint,coalesce(p_data->>'category','Other'),day,capture)
      returning id into rid;
  else
    update personal_expenses set voided_at=now()
      where id=(p_data->>'id')::uuid and trip_id=tid and created_by=uid and voided_at is null returning id into rid;
    if not found then raise exception 'Expense access denied'; end if;
  end if;
  result=jsonb_build_object('id',rid);
  insert into command_receipts values(uid,p_request_id,jsonb_build_object('action',p_action,'data',p_data),result,now());
  -- Personal entries deliberately do not create group activity or notifications.
  return result;
end $$;
revoke all on function public.companion_snapshot() from public,anon;
revoke all on function public.companion_command(text,jsonb,uuid) from public,anon;
grant execute on function public.companion_snapshot() to authenticated;
grant execute on function public.companion_command(text,jsonb,uuid) to authenticated;
commit;
