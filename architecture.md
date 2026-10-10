# Layover Architecture

Version 2 | 11 October 2026

## Runtime

Flutter uses Riverpod to own the trip store, Material navigation, and the
Supabase client for authentication and RPCs. PostgreSQL is authoritative for
membership, terms, share calculation, transfers, and audit history. A Supabase
Edge Function delivers optional Firebase push notifications.

The application has two explicit modes. A configured build uses Supabase email
OTP and real persisted trip records. An unconfigured build opens a labeled,
locally persisted demo with three switchable travelers. Demo records never
reach the server or represent actual payments.

## Data Model

`0001_init.sql` retains the original profiles, trips, membership, invites, pot,
obligations, and provider-payment tables. `0002_companion.sql` adds:

- `trip_entries`: validated trip content, kinds, creator, revision, and details
  for polls, shortlists, itinerary, bookings, tasks, meetings, announcements,
  and voluntary shared emergency contacts.
- `entry_responses` and `entry_comments`: member votes/check-ins and discussions.
- `trip_expenses`: actual expenditure and server-computed paise allocations.
- `manual_transfers`: external reports, recipient acknowledgments, disputes,
  withdrawals, linked contributions/reimbursements, and corrections.
- `pot_revisions` and `term_acceptances`: immutable agreement history.
- `trip_activity`, `trip_notifications`, and `device_tokens`: audit and delivery.
- `command_receipts`: per-user idempotency results, including input comparison.

Provider payment attempts are retained for compatibility but unused by the
external-payment pilot. They must never be populated by manual acknowledgments.

## Public Interfaces

`companion_snapshot()` returns only trips the caller has joined, their member
display names, content, obligations, expenses, transfers, notifications, and
recent activity. Financial information is shared within the trip; provider
credentials and tokens are not returned. Invite metadata is organizer-only.

`companion_command(action, data, request_id)` accepts authenticated commands:

- Account: `profile`, `device_token`, `read_notification`.
- Trips: `create_trip`, `update_trip`, `duplicate_trip`, `join_trip`, `invite`, `revoke_invite`,
  `archive_trip`, `whatsapp`, `remove_member`, `reinvite_member`.
- Content: `save_entry`, `delete_entry`, `toggle_task`, `respond`, `comment`,
  `choose_entry`.
- Money: `save_pot`, `accept_terms`, `pot_outcome`, `add_expense`, `void_expense`,
  `report_transfer`, `transfer_status`.

All trip-scoped payloads require `trip_id`. Updates require the relevant
`version`. Financial writes send amount and split inputs; PostgreSQL computes
the result. The client calculates the same split for preview and tests verify
rounding and settlement invariants.

## Transactions and Access

The command function locks the request ID and target trip. It checks identity,
joined membership, organizer/author/recipient permissions, current versions,
and archive state before writing. The transaction records activity and the
idempotent result. Reusing an ID with changed input fails.

New tables have RLS enabled with no direct client write policies. Checked
security-definer functions have fixed search paths and restricted execute
grants. Reminder functions are service-role-only. Storage uses a private
`trip-files` bucket with paths `trip_id/user_id/random.ext`; membership controls
reads and the uploader controls writes. Signed download URLs expire after
60 seconds. Uploads are limited to 10 MB PDF, JPEG, or PNG.

Entry and pot version checks prevent stale overwrites. Pot changes reset current
acceptance without destroying previous revisions or money records. Removal is
blocked until that person's balance and pending transfers are resolved.

## Offline and Recovery

The store refreshes on resume, manual refresh, and a 45-second connected poll.
User-scoped local preferences retain non-financial itinerary/booking summaries
and expense drafts. No background financial writes occur offline. A successful
refresh removes inaccessible trips and their drafts.

Unknown command outcomes retain their original request IDs locally. Retry uses
that ID so a lost response cannot duplicate an expense or transfer. A known
validation failure permits correction; it is not treated as an unknown payment.

## Notifications

`enqueue_trip_reminders()` sweeps missed deadlines and creates deduplicated
24-hour pot reminders plus user-scheduled entry reminders. An authenticated
scheduler calls `trip-reminders`; it queues reminders, leases pending deliveries,
and optionally calls FCM HTTP v1 using a server-only service account.

The worker checks active membership and preferences immediately before sending,
removes invalid device tokens, and marks completed deliveries. Leases expire
after five minutes. Push delivery is at least once; Android notification tags
reduce visible duplicates. The app's in-app records remain authoritative.

## Verification and Operations

Flutter tests cover money parsing, split reconciliation, contribution/expense
accounting, corrections/refunds, settlement, caching, persistence, and responsive
navigation. The PostgreSQL integration suite uses PGlite with Supabase auth and
storage stubs to execute both migrations and test security/business rules.
Browser checks run the compiled web app at phone and desktop widths.

These local checks do not replace a hosted Supabase migration test, SMTP/OTP
delivery check, Firebase device test, physical Android validation, or user pilot.
See `app/README.md` for deployment and local-run instructions.
