# Archived Layover Hackathon Plan

Historical setup plan. See `../../PLAN.md` for the full companion release.

Derived from `prd.md` and `architecture.md`. This plan trims them to what is
actually required to ship a demoable hackathon MVP, and records every place it
deviates from the architecture doc.

## 1. Deviations from architecture.md (and why)

| architecture.md | This plan | Reason |
|---|---|---|
| FastAPI backend + self-hosted Postgres | **Supabase** (managed Postgres + Auth + RLS + Edge Functions) | No server to host/operate; no Docker/sudo on the dev machine; still real Postgres with constraints, transactions and RLS. Satisfies "managed auth + managed PostgreSQL". |
| Server-side state machine in API code | **Postgres RPC functions** (`security definer`) | Keeps transitions server-authoritative and transactional without a separate API tier. |
| Webhook processor service | **One Edge Function** (`payment-webhook`) | Signature check + idempotent insert into `provider_events`. Mock signer for the demo. |
| Reconciliation worker | **`pg_cron` job** calling an RPC (deadline sweep) | One scheduled job covers `TARGET_MISSED`. Stale-payment reconcile is Phase 2. |
| Riverpod *or* Bloc | **Riverpod** (no codegen) | Fewer moving parts than Bloc, no build_runner step. |
| dio | **supabase_flutter client** | It already handles auth headers, refresh and PostgREST/RPC calls. |
| FCM push | **Deferred (P1)** | Needs a Firebase project; not needed for the demo. In-app status is authoritative anyway. |
| Redis/Kafka/K8s | Not used | Per architecture's own advice. |

If you would rather keep FastAPI, the Flutter side does not change: only the
`data/` repositories do.

## 2. Scope actually built

**P0 only**, in this order (matches architecture §12):

1. Auth (email magic link / email+password via Supabase) + profile
2. Create trip + exactly one pot (target, currency, equal/fixed shares, deadline, terms)
3. Invite by code/deep link (hashed token, expiry, revoke), join/decline, accept share + terms version
4. Contribution ledger + **mock** payment adapter (pending → confirmed / failed / refund)
5. Pot progress (confirmed vs pending), state machine, activity log
6. Cancel flow, deadline-missed sweep
7. Loading / empty / error / offline states

**Not built:** real payment provider, push notifications, deadline extension,
share/export, booking integration, anything in the PRD "out of scope" list.

## 3. Stack

- **App:** Flutter (stable), Dart, Android first. Test on a physical phone over USB (no emulator).
- **State:** `flutter_riverpod` · **Routing:** `go_router` (invite deep links)
- **Backend:** `supabase_flutter` · **Money:** integer minor units (paise) + `intl` for formatting
- **Share invite:** `share_plus` · **Connectivity:** `connectivity_plus`
- **Tests:** `flutter_test`, `mocktail`; SQL checks against the Supabase local/hosted DB
- **Config:** `--dart-define-from-file=env.json` (gitignored). Only the Supabase URL and
  *publishable (anon)* key go in the app. The service-role key and payment secrets never enter the app.

## 4. Folder layout

```
layover /
  prd.md  architecture.md  PLAN.md
  app/                      Flutter project
    lib/
      main.dart
      app/        (router, theme, bootstrap)
      core/       (supabase client, money, errors, connectivity)
      features/   authentication, trips, trip_pot, invitations,
                  contributions, activity, profile_privacy
                  each: presentation/ domain/ data/
    test/
    env.example.json
  supabase/
    migrations/0001_init.sql   schema + RLS
    functions/                 payment-webhook (later)
    seed.sql                   demo data (later)
```

## 5. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | **Setup (this step)** | `flutter doctor` clean for Android, app builds, phone detected, schema file ready, Supabase connection check screen works |
| M1 | Auth + profile | Sign in on phone; `profiles` row created by trigger |
| M2 | Trip + pot create | RPC `create_trip_with_pot` validates share math; list/detail screens |
| M3 | Invites + join | Code/deep link join, accept share + terms version recorded |
| M4 | Payments (mock) | Payment attempt RPC with idempotency key; webhook function updates ledger; duplicates ignored |
| M5 | State machine + audit | Target reached / missed / cancelled transitions; activity screen |
| M6 | Hardening + demo | PRD §13 checklist, the 10 E2E scenarios in architecture §10 |

## 6. Decisions I made (change if you disagree)

- Currency: **INR only** in the MVP, stored as paise.
- Equal split remainder: **assigned to the organizer** (shown explicitly before acceptance).
- Auth: **Supabase email OTP/magic link** (no password storage by us).
- Booking status: **organizer-reported**, labelled as such.
- Real-money mode: **disabled** by config; production fails closed without provider config.

## 7. What you need to do (cannot be done for you)

1. Create a free project at supabase.com.
2. Copy Project URL + publishable key into `app/env.json` (copy from `env.example.json`).
3. Run `supabase/migrations/0001_init.sql` in the Supabase SQL editor.
4. Enable USB debugging on the phone, plug in, accept the RSA prompt.

## 8. Run commands

```bash
cd "app"
flutter devices                                   # phone should appear
flutter run --dart-define-from-file=env.json
```
