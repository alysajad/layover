-- Layover / Trip Pot — initial schema (M0)
-- Run in Supabase SQL editor (or `supabase db push`).
-- Design rules (from architecture.md §5):
--   * money = integer minor units + ISO currency, never floats
--   * client has READ access via RLS only; all writes go through
--     security-definer RPCs added in later milestones, so the app can never
--     set payment_status = 'confirmed' or advance a pot state itself.

create extension if not exists pgcrypto;

-- ---------- enums ----------
create type pot_status as enum (
  'draft','open','funding','target_reached','booked',
  'target_missed','cancel_requested','cancelled','closed'
);
create type member_role as enum ('organizer','participant');
create type membership_status as enum ('invited','joined','declined','left','removed');
create type contribution_mode as enum ('equal','fixed');
create type obligation_status as enum ('proposed','accepted','waived','cancelled');
create type payment_status as enum (
  'created','pending','confirmed','failed','cancelled',
  'refund_pending','partially_refunded','refunded','unknown'
);

-- ---------- profiles (1:1 with auth.users) ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  account_status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1)));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- trips & membership ----------
create table public.trips (
  id uuid primary key default gen_random_uuid(),
  organizer_user_id uuid not null references public.profiles(id),
  title text not null check (char_length(title) between 1 and 120),
  destination text,
  start_date date,
  end_date date check (end_date is null or start_date is null or end_date >= start_date),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.trip_members (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  role member_role not null default 'participant',
  membership_status membership_status not null default 'invited',
  joined_at timestamptz,
  unique (trip_id, user_id)
);

create table public.invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  token_hash text not null unique,          -- sha256 of the raw token; raw token is never stored
  created_by uuid not null references public.profiles(id),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  max_uses int not null default 20 check (max_uses > 0),
  use_count int not null default 0 check (use_count >= 0),
  created_at timestamptz not null default now()
);

-- ---------- pot (one per trip in MVP) ----------
create table public.pots (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null unique references public.trips(id) on delete cascade,
  title text not null,
  target_minor_units bigint not null check (target_minor_units > 0),
  currency char(3) not null default 'INR' check (currency = upper(currency)),
  contribution_mode contribution_mode not null default 'equal',
  participant_cap int not null default 10 check (participant_cap between 2 and 50),
  deadline_at timestamptz not null,
  terms_version int not null default 1,
  terms_text text not null,
  status pot_status not null default 'draft',
  version int not null default 1,           -- optimistic concurrency
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.contribution_obligations (
  id uuid primary key default gen_random_uuid(),
  pot_id uuid not null references public.pots(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount_minor_units bigint not null check (amount_minor_units >= 0),
  currency char(3) not null,
  obligation_status obligation_status not null default 'proposed',
  accepted_terms_version int,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pot_id, user_id)                  -- no duplicate obligations per member
);

-- ---------- payments ledger ----------
create table public.payment_attempts (
  id uuid primary key default gen_random_uuid(),
  pot_id uuid not null references public.pots(id),
  contribution_obligation_id uuid not null references public.contribution_obligations(id),
  user_id uuid not null references public.profiles(id),
  provider text not null default 'mock',
  provider_payment_id text,
  idempotency_key text not null,
  amount_minor_units bigint not null check (amount_minor_units > 0),
  currency char(3) not null,
  status payment_status not null default 'created',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  unique (user_id, idempotency_key)
);

create table public.provider_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  provider_event_id text not null,
  payment_attempt_id uuid references public.payment_attempts(id),
  event_type text not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  processing_status text not null default 'received',
  unique (provider, provider_event_id)      -- webhook dedupe
);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_attempt_id uuid not null references public.payment_attempts(id),
  provider_refund_id text,
  amount_minor_units bigint not null check (amount_minor_units > 0),
  currency char(3) not null,
  status text not null default 'pending',
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);

-- ---------- audit log ----------
create table public.pot_events (
  id uuid primary key default gen_random_uuid(),
  pot_id uuid not null references public.pots(id) on delete cascade,
  actor_user_id uuid references public.profiles(id),   -- null = system/provider
  event_type text not null,
  old_state pot_status,
  new_state pot_status,
  metadata_redacted jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index on public.trip_members (user_id);
create index on public.contribution_obligations (pot_id);
create index on public.payment_attempts (pot_id, status);
create index on public.pot_events (pot_id, created_at desc);

-- ---------- RLS helpers (security definer avoids policy recursion) ----------
create function public.is_trip_member(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from trip_members
    where trip_id = p_trip and user_id = auth.uid()
      and membership_status in ('invited','joined')
  );
$$;

create function public.is_trip_organizer(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from trips where id = p_trip and organizer_user_id = auth.uid());
$$;

-- ---------- RLS: enable everywhere; default deny ----------
alter table public.profiles                 enable row level security;
alter table public.trips                    enable row level security;
alter table public.trip_members             enable row level security;
alter table public.invites                  enable row level security;
alter table public.pots                     enable row level security;
alter table public.contribution_obligations enable row level security;
alter table public.payment_attempts         enable row level security;
alter table public.provider_events          enable row level security;
alter table public.refunds                  enable row level security;
alter table public.pot_events               enable row level security;

-- Reads only. No insert/update/delete policies => writes are impossible from
-- the client until the matching RPC exists.
create policy profiles_self_read on public.profiles
  for select using (id = auth.uid());
create policy profiles_self_update on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

create policy trips_member_read on public.trips
  for select using (public.is_trip_member(id));

create policy members_read on public.trip_members
  for select using (public.is_trip_member(trip_id));

create policy pots_member_read on public.pots
  for select using (public.is_trip_member(trip_id) and status <> 'draft'
                    or public.is_trip_organizer(trip_id));

create policy obligations_member_read on public.contribution_obligations
  for select using (
    user_id = auth.uid()
    or exists (select 1 from pots p where p.id = pot_id and public.is_trip_organizer(p.trip_id))
  );

-- A participant sees only their own payment attempts (PRD: no exposure of
-- other members' transaction details); the organizer sees status via an RPC/view later.
create policy payments_own_read on public.payment_attempts
  for select using (user_id = auth.uid());

create policy refunds_own_read on public.refunds
  for select using (exists (
    select 1 from payment_attempts a where a.id = payment_attempt_id and a.user_id = auth.uid()));

create policy pot_events_member_read on public.pot_events
  for select using (exists (
    select 1 from pots p where p.id = pot_id and public.is_trip_member(p.trip_id)));

-- invites & provider_events: no client policies at all (server/RPC only).
