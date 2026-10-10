# Layover Product Requirements

Version 2 | 11 October 2026 | Android-first pilot

**One-liner:** Plan the trip, agree on the money, and keep the group together.

Layover helps friends in India choose dates and stays, commit to a shared
booking, organize the trip, record costs, and settle afterward. The original
trip pot remains central to the pre-booking decision. The expanded scope was
approved for a longer solo build, estimated at 12-16 weeks, followed by a pilot
with five groups and then twenty.

## Product Decisions

- INR only; amounts are integer paise.
- One organizer and one pot per trip. A trip can exist without a pot.
- Friends pay each other outside Layover. No wallet, checkout, custody,
  automatic charge, or bank verification is implied.
- The sender reports a transfer. Only its recipient can acknowledge receipt
  or dispute it. Pending or disputed reports do not settle balances.
- Organizer-covered funds are a commitment, not a transfer. Readiness combines
  this commitment with recipient-acknowledged contributions and current terms
  acceptance. Funding readiness does not reserve inventory.
- Bookings and cancellation details are entered by the group and labeled as
  organizer-reported. An attachment is not provider verification.
- Mobile comes first. The web runner also supports local preview and layout tests.

## User Journeys

1. Create a trip, invite friends, and decide dates and budget through polls.
2. Add candidate stays or activities with links, prices, notes, and votes.
   The organizer chooses an option; a vote never creates a financial obligation.
3. Create a pot with a target, exact shares, organizer cover, deadline, and
   cancellation terms. Each person accepts the current version.
4. Report external contributions and have recipients acknowledge them. Review
   group readiness, then record a booking outcome and confirmation details.
5. Use a shared itinerary, packing/tasks, meeting points, check-ins, and contacts.
6. Record actual expenses, inspect balances, make external repayments, and
   acknowledge those repayments. Export or archive the completed trip.

## Features and Acceptance

| Area | Required behavior |
|---|---|
| Accounts | Email OTP, editable display name, sign-out, export, deletion request |
| Trips | Create, join by revocable expiring invite code, membership roles, archive/restore |
| Decisions | Date/budget polls, editable votes, comments, organizer selections |
| Shortlist | Stay/activity links, entered price, notes, votes, create a pot from price |
| Pot | Equal/exact/percentage/weighted shares, organizer cover, deadline, immutable terms revisions and acceptance history |
| Changes | Preview a dropout; propose revised shares; require fresh acceptance |
| Transfers | Report, recipient acknowledgment/dispute, withdraw pending report, correct with a new acknowledgment |
| Reimbursements | Record an external reimbursement as the opposite transfer, linked to the pot when applicable |
| Expenses | Payer, category, receipt, split preview, shared record, auditable void/replacement |
| Settlement | Compute balances from actual expenses and acknowledged transfers; suggest repayments |
| Itinerary | Dated entries, time, address, notes, external navigation links |
| Bookings | Owner, reference, address, cancellation terms, payment due date, private PDF/image attachment |
| Coordination | Assigned tasks, meeting locations, timestamped manual check-ins, announcements, optional shared contacts |
| Notifications | In-app changes, deadline/reminder records, optional configured push, preferences |
| Offline | Cached itinerary/booking summaries; local expense drafts explicitly submitted after reconnection |
| Repeat use | Duplicate itinerary/tasks with dates, assignments, completion and attachments cleared; CSV export |

## Financial Rules

An expense creates an obligation; a transfer moves money between two people.
Never create an expense from a pot contribution. For example, a INR 6,000 stay
split three ways is settled when two friends each transfer INR 2,000 to the
organizer and the organizer records paying INR 6,000 for the stay.

Equal pot splits assign rounding paise to the organizer if included. Other
proportional splits use largest remainders with stable member-ID tie-breaking.
Exact amounts must total the expense; percentages must total 100%.

Changes to amount, shares, deadline, organizer cover, or terms create a new
terms version. Earlier payments remain recorded, but readiness waits for
acceptance of the new version. A correction withdraws the original transfer
and creates a new report; the recipient must acknowledge the replacement.

A member with an unsettled balance or unresolved transfers cannot lose access
until those records are settled. Removal retains historical records and does
not silently redistribute costs. An organizer can instead revise proposed pot
shares while arranging a replacement.
Historical expenses involving a former member are protected from changes until
that person rejoins. The organizer can allow a new invitation; this does not
restore access until the person accepts an active invite.

## Privacy and Reliability

- Server membership checks govern every operation and private attachment read.
- Only joined members can view a trip. Revoked membership is removed from the
  local summary after the next successful refresh; sign-out clears summaries.
- Offline summaries exclude financial tables, contact entries, and attachment
  links. Previously cached offline data cannot be remotely erased without a
  network connection.
- Requests carry idempotency IDs. Unknown network outcomes retain the same
  request for retry, including recovery after app restart.
- Concurrent entry and pot edits require a matching version.
- Secrets and payment credentials never enter the client. Push messages use a
  generic body; detailed content stays in the authenticated app.

## Research Behind the Scope

- [Airbnb collaborative wishlists](https://www.airbnb.com/help/article/1236):
  shared choices and voting before booking.
- [Splitwise split options](https://kb.splitwise.com/balances-and-expenses/what-are-different-ways-i-can-split-an-expense):
  unequal amounts, percentages, and shares.
- [Wanderlog](https://wanderlog.com/en): shared itineraries and travel organization.
- [TripIt](https://www.tripit.com/web): keeping booking information together.
- [Tricount](https://www.tricount.com/en-us/features): group expenses, receipts,
  repayments, and offline workflows.
- [Airbnb scheduled payments](https://www.airbnb.com/help/article/2143): a future
  reference only. Its published options exclude INR; availability cannot be
  assumed for Layover.

## Pilot and Later Work

Measure creation time, invite acceptance, accepted pot shares, completed
settlements, crashes, failed requests, and support reports. The pilot must
complete a multi-account trip without duplicate records or false bank-confirmed
labels. Collect usability feedback from five groups before expanding to twenty.

Later work: multiple pots, co-organizers, receipt OCR, email booking import,
AI itinerary drafts, live transport updates, time-limited live location,
and payment-provider integrations. These are not part of this implementation.

Original requirements are preserved under `docs/archive/`.
