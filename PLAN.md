# Layover Full Companion Release

## Implemented in the Repository

- Flutter navigation for overview, planning, money, bookings, and group.
- Connected Supabase account/trip flows and a persistent local demo.
- Polls, shortlists, comments, itinerary, booking records, private attachments.
- Pot shares/acceptance, manual transfers, recipient acknowledgments,
  reimbursements, expenses, settlement, and CSV export.
- Tasks, meetings/check-ins, announcements, shared contacts, trip templates.
- Offline summaries/drafts, idempotent request recovery, activity and in-app
  notifications, push-registration client and reminder-worker source.
- Versioned database migration, accounting/access tests, browser preview tools.

## Deployment and Pilot Gates

1. Apply the migrations to a development Supabase project and configure Google
   sign-in. Test independent accounts on two devices, revoked invites, removal,
   attachment access, and a full group settlement.
2. Deploy the reminder Edge Function and configure a scheduler. Configure a
   Firebase project and test opt-in push on a physical Android device.
3. Confirm signed Android build, account-deletion review process, support owner,
   crash/error monitoring, storage retention, and backups.
4. Invite five groups. Observe creation time, invitation acceptance, corrections,
   offline behavior, settlement completion, and support requests.
5. Fix observed issues, then expand to twenty groups.

The original 12-16 week estimate includes integration, device testing, pilot
feedback, and operational work. Repository implementation alone does not mean
those rollout steps have happened.

## Deferred Scope

Multiple pots, co-organizers, real payment checkout, automated refunds,
installments, OCR, booking-email import, AI itinerary generation,
and transport tracking remain later features. The original hackathon plan is
preserved in `docs/archive/hackathon-plan.md`.

## Live Map P0 integration

Implemented private sessions, trip-contact invitations, explicit foreground
consent, three-second polling, latest-position leases, stop/pause, regroup
points, member controls, and the Android/web Mapbox adapter. Synthetic demo data
stays in memory. Migration 0003 adds checked RPCs, RLS, trip invalidation, and
cleanup. The original trip and Trip Pot workflows stay independent.

Release requires restricted Mapbox tokens, hosted multi-client RPC validation,
the minute cleanup schedule, verified backup/log retention, and physical Android
checks. Track evidence in [Live Map operations](docs/live-map-operations.md).
