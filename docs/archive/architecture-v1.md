# Archived Technical Architecture (Version 1)

Historical proposal. The implemented Supabase architecture is described in
`../../architecture.md`.

## Group Travel Trip Pot --- Flutter MVP

**Version:** 1.0\
**Date:** 10 October 2026\
**Status:** Proposed architecture; no implementation code included

------------------------------------------------------------------------

## 1. Architecture decision

Use a **Flutter client + backend API + relational database +
payment-provider adapter**. The backend is the authority for membership,
contribution math, pot state, deadlines, and payment confirmation.

For the hackathon, run the payment integration in **mock/sandbox mode**.
Do not hold funds or place payment secrets in the mobile app. A real
payment provider and India-specific legal/compliance review are release
gates, not implementation details to improvise.

### Logical architecture

``` text
┌──────────────────────────── Flutter mobile app ────────────────────────────┐
│ Presentation (screens/widgets)                                              │
│        ↓                                                                     │
│ State management / controllers                                               │
│        ↓                                                                     │
│ Domain models + use cases                                                    │
│        ↓                                                                     │
│ Repositories / API client                                                    │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │ HTTPS + access token
                                ▼
┌──────────────────────────── Backend API ───────────────────────────────────┐
│ Authentication / authorization                                               │
│ Trip & membership service  ─ Pot/state-machine service                      │
│ Contribution service       ─ Payment orchestration adapter                  │
│ Invite service             ─ Notification service (optional P1)             │
│ Audit/event service        ─ Reconciliation worker                           │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │
              ┌─────────────────┼───────────────────┐
              ▼                 ▼                   ▼
       Relational DB       Payment provider     Push/email provider
       (source of truth)   hosted checkout      (optional P1)
              ▲                 │
              └──── signed webhooks + reconciliation ────┘
```

The diagram describes logical boundaries, not a requirement to deploy
every service independently. Start as a modular monolith; split services
only when scale or ownership justifies it.

------------------------------------------------------------------------

## 2. Recommended technology choices

  --------------------------------------------------------------------------
  Layer                   Recommended starting       Rationale / notes
                          choice                     
  ----------------------- -------------------------- -----------------------
  Mobile                  Flutter + Dart             One mobile codebase;
                                                     Android-first testing,
                                                     with iOS-compatible
                                                     patterns.

  UI architecture         Feature-first folders with Keeps payment logic out
                          presentation/domain/data   of widgets and makes
                          separation                 features testable.

  State management        Riverpod or Bloc; choose   Avoid mixing
                          one and standardize        state-management
                                                     approaches across
                                                     features.

  Navigation              `go_router` or equivalent  Deep links for trip
                          declarative router         invitations.

  Networking              `dio` or Flutter's `http`  Centralized auth
                          client                     headers, timeouts,
                                                     error mapping, and
                                                     request IDs.

  Serialization           Typed models; generated    Avoid passing untyped
                          serialization optional     maps through the app.

  Backend                 FastAPI (Python) or an     REST API is sufficient
                          equivalent team-familiar   for the MVP; keep
                          API framework              payment state
                                                     server-side.

  Database                PostgreSQL                 Transactions,
                                                     constraints, relational
                                                     membership/payment
                                                     records, and
                                                     auditability.

  Authentication          Managed auth provider or   Avoid building password
                          backend-verified OIDC      security from scratch.

  Background work         A worker/queue or          Webhook processing,
                          scheduled job              reminders, and payment
                                                     reconciliation.

  Payment                 Provider-hosted/approved   Start with
                          checkout via adapter       mock/sandbox. Select a
                                                     provider only after
                                                     confirming supported
                                                     flow and legal
                                                     suitability.

  Notifications           Firebase Cloud Messaging   Push is a delivery
                          plus backend notification  channel, not the source
                          records                    of truth.

  Hosting                 A managed container/app    Minimize infrastructure
                          platform and managed       work during the
                          PostgreSQL                 hackathon.

  Observability           Structured server logs,    Payment mismatches and
                          crash reporting, metrics   state errors need
                          and alerts                 visibility.
  --------------------------------------------------------------------------

**Do not add microservices, Redis, Kafka, Kubernetes, or a custom wallet
for the hackathon by default.** Add infrastructure only to solve a
demonstrated requirement.

------------------------------------------------------------------------

## 3. Flutter application structure

Suggested feature-first organization (illustrative structure, not source
code):

``` text
lib/
  app/
    app_bootstrap
    router
    theme
    dependency_setup
  core/
    api/
    auth/
    errors/
    logging/
    money/
    permissions/
    result_types/
  features/
    authentication/
      presentation/
      domain/
      data/
    trips/
      presentation/
      domain/
      data/
    trip_pot/
      presentation/
      domain/
      data/
    invitations/
      presentation/
      domain/
      data/
    contributions/
      presentation/
      domain/
      data/
    activity/
      presentation/
      domain/
      data/
    profile_privacy/
      presentation/
      domain/
      data/
```

### Responsibilities

-   **Presentation:** renders state and forwards user intent; contains
    no authoritative payment or pot rules.
-   **Domain:** use cases, value objects, validation rules, and state
    labels.
-   **Data:** repositories, DTO mapping, local cache, and API calls.
-   **Core:** shared networking, money formatting, error types, logging,
    and auth utilities.

### Client-side state

Use the backend as the source of truth. Local state can hold drafts and
cached read-only data, but must not independently confirm a payment or
advance the pot state. On resume from checkout, refresh status from the
backend. Do not rely on a deep-link result or redirect alone as proof of
payment.

------------------------------------------------------------------------

## 4. Backend modules

### 4.1 Authentication and authorization

-   Verify the identity token on every authenticated request.
-   Derive the user identity from the verified token, never from a
    client-supplied `user_id`.
-   Enforce trip membership and role checks at the API/data-access
    layer.
-   Use roles such as `organizer` and `participant`; do not rely on
    hidden UI controls for authorization.

### 4.2 Trip and membership module

-   Creates and updates trip metadata.
-   Adds the organizer as a member.
-   Manages invite codes/links, expiry, revocation, join, decline, and
    leave rules.
-   Does not reveal member payment details to non-members.

### 4.3 Pot/state-machine module

-   Validates target, currency, shares, deadline, and terms.
-   Computes confirmed totals from the ledger, not a client-provided
    total.
-   Applies allowed state transitions in a database transaction.
-   Uses server time for deadlines.
-   Prevents contributions to terminal states.
-   Writes an audit record for every transition.

### 4.4 Contribution module

-   Creates a contribution obligation and payment attempt.
-   Tracks payment lifecycle independently of pot lifecycle.
-   Stores provider references and status history.
-   Supports retry only when a prior attempt is safely resolved or
    idempotently reused.
-   Supports future scheduled-payment obligations where a provider can
    collect a deposit first and the balance later.
-   Handles refunds as separate records/status transitions; do not
    overwrite the original payment history.

### 4.5 Payment adapter

Define a provider-neutral interface so the app's business logic does not
depend on one vendor's terminology. The adapter should support, where
available: - Create a checkout/payment intent. - Query payment status. -
Verify webhook signature and event authenticity. - Initiate or track
refunds. - Reconcile payment attempts. - Report whether scheduled
payments, early payment, payment-method update, delayed capture, and
refund operations are supported.

Use a mock adapter in local/demo environments and a sandbox adapter for
integration tests. Never allow a client request to directly set
`payment_status = confirmed`.

The product may borrow Airbnb-style scheduled payment behavior later,
but the adapter must expose provider capability flags first. If a
provider cannot support delayed collection, retry windows, cancellation
rules, or refund tracking, the API must hide those options from Flutter.

### 4.6 Webhook processor and reconciliation

-   Verify signatures before processing.
-   Persist provider event ID and payload metadata needed for audit,
    with sensitive fields removed.
-   Deduplicate on provider event ID and payment reference.
-   Handle retries and out-of-order events.
-   Process events transactionally.
-   Run a reconciliation job to compare unresolved internal attempts
    with provider status.
-   Alert on stale pending payments, unexplained mismatches, and refund
    failures.

### 4.7 Notifications

Notifications are optional for the first hackathon demo. Store
notification intent/status server-side. Never make push delivery the
only record of a deadline, payment, or cancellation event. Rate-limit
reminders and respect preferences.

------------------------------------------------------------------------

## 5. Core data model

Use UUIDs or another non-guessable identifier for public references.
Store timestamps in UTC; render in the user's local timezone. Store
money as integer minor units plus ISO currency code.

### `users`

-   `id`
-   `auth_subject` (unique external identity subject)
-   `display_name`
-   `email_or_phone` (only if needed; protect access)
-   `created_at`, `updated_at`
-   `account_status`

### `trips`

-   `id`
-   `organizer_user_id`
-   `title`
-   `destination` (nullable)
-   `start_date`, `end_date` (nullable)
-   `created_at`, `updated_at`

### `trip_members`

-   `id`
-   `trip_id`
-   `user_id`
-   `role` (`organizer`, `participant`)
-   `membership_status` (`invited`, `joined`, `declined`, `left`,
    `removed`)
-   `joined_at`
-   unique constraint on (`trip_id`, `user_id`)

### `invites`

-   `id`
-   `trip_id`
-   `token_hash` (store a hash, not the raw reusable secret)
-   `created_by`
-   `expires_at`
-   `revoked_at`
-   `max_uses`, `use_count`
-   `created_at`

### `pots`

-   `id`
-   `trip_id` (unique for MVP: one pot per trip)
-   `title`
-   `target_minor_units`
-   `currency`
-   `contribution_mode` (`equal`, `fixed`)
-   `deadline_at`
-   `terms_version`
-   `terms_text` or immutable terms reference
-   `status`
-   `created_at`, `updated_at`
-   `version` for optimistic concurrency if useful

### `contribution_obligations`

-   `id`
-   `pot_id`
-   `user_id`
-   `amount_minor_units`
-   `currency`
-   `obligation_status` (`proposed`, `accepted`, `waived`, `cancelled`)
-   `accepted_terms_version`
-   `accepted_at`
-   `created_at`, `updated_at`

### `payment_attempts`

-   `id`
-   `pot_id`
-   `contribution_obligation_id`
-   `user_id`
-   `provider`
-   `provider_payment_id` (nullable until created)
-   `idempotency_key` (unique within the relevant scope)
-   `amount_minor_units`
-   `currency`
-   `status` (`created`, `pending`, `confirmed`, `failed`, `cancelled`,
    `refund_pending`, `partially_refunded`, `refunded`, `unknown`)
-   `created_at`, `updated_at`
-   `confirmed_at` (nullable)

### `payment_schedules` (P1 / Later)

-   `id`
-   `pot_id`
-   `contribution_obligation_id`
-   `user_id`
-   `schedule_type` (`deposit_balance`, `pay_later`, `custom`)
-   `total_minor_units`
-   `currency`
-   `provider_schedule_id` (nullable)
-   `status` (`draft`, `active`, `completed`, `cancelled`, `failed`)
-   `created_at`, `updated_at`

### `payment_schedule_items` (P1 / Later)

-   `id`
-   `payment_schedule_id`
-   `sequence_number`
-   `amount_minor_units`
-   `currency`
-   `due_at`
-   `status` (`scheduled`, `due`, `attempting`, `paid`, `failed`,
    `cancelled`)
-   `payment_attempt_id` (nullable)
-   `created_at`, `updated_at`

### `provider_events`

-   `id`
-   `provider`
-   `provider_event_id`
-   `payment_attempt_id` (nullable until correlated)
-   `event_type`
-   `received_at`
-   `processed_at`
-   `processing_status`
-   unique constraint on (`provider`, `provider_event_id`)

### `refunds`

-   `id`
-   `payment_attempt_id`
-   `provider_refund_id`
-   `amount_minor_units`
-   `currency`
-   `status`
-   `requested_at`, `updated_at`, `completed_at`

### `pot_events` (audit log)

-   `id`
-   `pot_id`
-   `actor_user_id` (nullable for system/provider)
-   `event_type`
-   `old_state`, `new_state`
-   `metadata_redacted`
-   `created_at`

### Data integrity rules

-   Never use floating-point values for money.
-   Use foreign keys and appropriate unique constraints.
-   Do not treat a cached `confirmed_total` as the ledger; if stored for
    performance, recompute/verify it from payment records.
-   Refund amounts must not exceed the captured amount, subject to
    provider semantics.
-   Prevent duplicate active obligations for the same member and pot.
-   Prevent a schedule's item totals from exceeding the accepted
    obligation amount.
-   Do not create scheduled-payment records unless the selected provider
    and pot terms support the schedule.
-   Keep terms immutable by version after a member accepts; material
    changes require re-acceptance.
-   Define deletion/anonymization rules that preserve legally required
    transaction/audit records while removing unnecessary personal data.

------------------------------------------------------------------------

## 6. API surface (illustrative)

All routes require authentication except a deliberately limited
invite-preview endpoint. Enforce membership/role authorization on each
request.

  ----------------------------------------------------------------------------------------
  Method                  Endpoint                              Purpose
  ----------------------- ------------------------------------- --------------------------
  POST                    `/v1/trips`                           Create trip

  GET                     `/v1/trips`                           List trips for current
                                                                user

  GET                     `/v1/trips/{tripId}`                  Get trip and authorized
                                                                membership view

  PATCH                   `/v1/trips/{tripId}`                  Update permitted trip
                                                                metadata

  POST                    `/v1/trips/{tripId}/pot`              Create the single pot

  GET                     `/v1/pots/{potId}`                    Get pot summary and
                                                                permitted member statuses

  PATCH                   `/v1/pots/{potId}`                    Update allowed fields
                                                                while state permits

  POST                    `/v1/trips/{tripId}/invites`          Create invite

  POST                    `/v1/invites/{token}/join`            Join after token and
                                                                policy checks

  POST                    `/v1/invites/{token}/decline`         Decline invite

  POST                    `/v1/pots/{potId}/accept-share`       Accept share and terms
                                                                version

  POST                    `/v1/pots/{potId}/payment-attempts`   Create or reuse a safe
                                                                payment attempt

  GET                     `/v1/payment-attempts/{attemptId}`    Retrieve
                                                                server-authoritative
                                                                status

  POST                    `/v1/pots/{potId}/payment-schedule`   Create a provider-supported
                                                                payment schedule

  POST                    `/v1/payment-schedule-items/{itemId}/pay-early`
                                                                Pay a scheduled item before
                                                                the due date

  PATCH                   `/v1/payment-schedules/{scheduleId}/payment-method`
                                                                Update the payment method
                                                                where provider rules allow

  POST                    `/v1/pots/{potId}/cancel`             Request cancellation if
                                                                permitted

  POST                    `/v1/pots/{potId}/extend-deadline`    Extend deadline under
                                                                policy

  GET                     `/v1/pots/{potId}/events`             Read activity log

  POST                    `/v1/webhooks/{provider}`             Receive signed provider
                                                                events;
                                                                provider-authenticated,
                                                                not
                                                                user-token-authenticated
  ----------------------------------------------------------------------------------------

API conventions: - Use a consistent error envelope with a stable
machine-readable code and safe human-readable message. - Add
request/correlation IDs. - Use idempotency keys for payment initiation
and other retry-sensitive writes. - Validate request size, enums,
amounts, currency, and state transitions server-side. - Paginate event
history. - Do not expose internal provider secrets, webhook payloads, or
other members' private transaction references.

------------------------------------------------------------------------

## 7. Critical payment and state flows

### Flow A --- Create contribution

1.  Flutter requests a payment attempt using the authenticated user's
    accepted obligation.
2.  Backend verifies membership, accepted terms, amount, pot state,
    deadline, and no conflicting active attempt.
3.  Backend creates/reuses an idempotent attempt and asks the provider
    adapter for checkout details.
4.  Flutter opens the approved checkout flow.
5.  App returns from checkout and fetches attempt status from the
    backend.
6.  Backend confirms the status only through a verified provider
    query/webhook/reconciliation rule.

### Flow B --- Webhook

1.  Provider sends event.
2.  Backend verifies signature and timestamp/replay constraints.
3.  Backend persists the event idempotently.
4.  Processor correlates it to the payment attempt.
5.  A database transaction updates payment status, writes an audit
    event, and recalculates pot state.
6.  Duplicate events return safely without duplicate totals or side
    effects.
7.  Unmatched or contradictory events enter an exception/reconciliation
    queue.

### Flow C --- Target reached

-   Calculate total from confirmed, non-refunded eligible contributions.
-   When total reaches target, transition to `TARGET_REACHED` in a
    transaction.
-   Notify members if notifications are enabled.
-   Show "Funding target reached; booking is not yet confirmed."
-   Only a future verified booking-provider integration can make a
    provider-confirmed booking status authoritative.

### Flow D --- Deadline missed

-   Server-side scheduled job checks open pots past deadline.
-   If target is below target amount, transition to `TARGET_MISSED`.
-   Block new payment attempts.
-   Apply the previously disclosed cancellation/refund policy; track
    each refund independently.
-   Delayed payment confirmations after deadline go through explicit
    reconciliation. Do not silently reopen the pot.

### Flow E --- Cancellation and refund

-   Check role, state, terms, and provider capability.
-   Record cancellation request.
-   Initiate refunds only through the provider-supported process.
-   Keep each refund's status distinct from the original payment.
-   Mark the pot closed only when its business policy's required steps
    are complete; do not assume a refund is immediate.

### Flow F --- Scheduled payment

1.  Flutter asks the backend for available payment options.
2.  Backend checks pot state, accepted obligation, terms, deadline, and
    provider capability flags.
3.  Backend returns only allowed options, such as full payment, deposit
    plus balance, or pay-later.
4.  Participant selects a schedule and confirms the exact amounts and
    due dates.
5.  Backend creates schedule records transactionally and calls the
    provider adapter when the provider owns the schedule.
6.  Reminder jobs create notification records before due dates.
7.  On due date, provider webhooks or backend jobs update each schedule
    item through the normal payment-attempt ledger.
8.  Failed scheduled payments enter a retry or cancellation path defined
    by the accepted terms. Flutter must not create duplicate payment
    attempts while the backend/provider status is unresolved.

------------------------------------------------------------------------

## 8. Security and privacy controls

-   TLS for all network traffic.
-   Managed secret storage for backend/provider secrets; never embed
    them in Flutter.
-   Short-lived access tokens and secure refresh-token storage where
    applicable.
-   Server-side authorization and least-privilege database roles.
-   Signed webhook verification, replay protection, idempotency, and
    audit logging.
-   Rate limits for login, invite generation, payment initiation, and
    cancellation.
-   Invite tokens must be unguessable, revocable, bounded, and stored
    hashed where feasible.
-   Redact personal/payment data from logs and analytics.
-   Avoid SMS, contacts, and continuous location permissions; they are
    outside MVP scope.
-   Define account deletion, data export, retention, incident response,
    and support processes before production.
-   Conduct threat modeling and security testing before real-money
    rollout.

------------------------------------------------------------------------

## 9. Failure modes and recovery

  -----------------------------------------------------------------------
  Failure                             Expected behavior
  ----------------------------------- -----------------------------------
  Network drops after payment         On retry, backend returns the
  initiation                          existing attempt when the
                                      idempotency key matches.

  User closes app during checkout     On reopening, fetch current status;
                                      do not assume failure or success.

  Webhook is duplicated               Unique provider event constraint
                                      makes processing idempotent.

  Webhook arrives out of order        Apply legal state transitions and
                                      query provider if event sequence is
                                      ambiguous.

  Provider status is unknown          Show "Checking payment status";
                                      prevent unsafe duplicate attempts
                                      until reconciled or timed out by
                                      policy.

  Payment confirmed after deadline    Record the provider-confirmed
                                      event, then follow the documented
                                      exception/refund policy; do not
                                      hide the transaction.

  Two payments accidentally confirm   Keep both records, flag
                                      overpayment, and follow provider
                                      refund process.

  Organizer cancels while a payment   Freeze new attempts, reconcile
  is pending                          pending attempts, and
                                      refund/resolve according to policy.

  Two users update pot simultaneously Use database transactions, state
                                      validation, and optimistic version
                                      checks where needed.

  Invite is forwarded or revoked      Recheck expiry/revocation and
                                      membership policy on join; do not
                                      rely on client-side link checks.

  Push notification fails             The app still shows current status
                                      from API; notification is not
                                      authoritative.

  Database/job outage crosses         Use server-side timestamps and
  deadline                            idempotent jobs; process missed
                                      deadlines on recovery.
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 10. Testing strategy

### Flutter tests

-   Unit tests for money formatting, split calculations, validation, and
    UI state mapping.
-   Widget tests for create pot, join, contribution status,
    cancellation, and error states.
-   Integration tests for deep links and return-from-checkout refresh.
-   Accessibility checks for labels, text scaling, and touch targets.

### Backend tests

-   Unit tests for state-machine transition rules and split rounding.
-   API tests for authentication, membership isolation, role checks, and
    validation.
-   Database tests for uniqueness, transactions, concurrent updates, and
    idempotency.
-   Webhook tests for invalid signatures, duplicate events, out-of-order
    events, unknown payment references, and retries.
-   Reconciliation tests for mismatches and delayed confirmations.

### End-to-end scenarios required before demo

1.  Organizer creates a pot; two members join; all shares accepted;
    target reached.
2.  One member declines; the organizer sees the remaining amount
    clearly.
3.  Deadline passes below target.
4.  Payment is pending and then confirmed after the app is reopened.
5.  Duplicate webhook is received.
6.  Payment fails and a safe retry succeeds.
7.  Pot is cancelled with refunds pending and later completed.
8.  Invite expires or is revoked.
9.  A participant attempts to access another trip's pot.
10. Two payments race to push the pot over target.

------------------------------------------------------------------------

## 11. Deployment environments

-   **Local:** local API/database, mock payment adapter, seeded demo
    data.
-   **Development/staging:** managed database, test auth, provider
    sandbox, test webhook endpoint, debug logging with redaction.
-   **Production:** managed infrastructure, production auth/provider
    credentials, restricted admin access, alerts, backups, tested
    restore procedure, privacy and legal review.

Keep mock/sandbox/production modes explicit and separated by
configuration. Production should fail closed if required provider
configuration or webhook verification is missing.

------------------------------------------------------------------------

## 12. Build order for a Flutter hackathon

1.  Confirm the exact MVP scope and pot states.
2.  Build the UI flow with seeded/mock repository data.
3.  Implement typed models and split calculations with unit tests.
4.  Build backend trip, member, pot, and invite APIs.
5.  Add server-side authorization and database constraints.
6.  Add mock payment adapter and simulate pending/success/failure/refund
    events.
7.  Implement webhook idempotency and state transitions.
8.  Add loading, offline, retry, and stale-status behavior.
9.  Run the end-to-end scenarios and prepare a demo.
10. Only then investigate a real payment partner and production
    compliance.

### Demo narrative

-   Create a trip and pot for a proposed booking.
-   Invite three participants.
-   Show one accepted share, one pending, and one declined.
-   Simulate a payment pending and then provider-confirmed.
-   Reach the target and show the accurate "booking decision required"
    state.
-   Run a second pot that misses its deadline and show the
    cancellation/refund workflow.

------------------------------------------------------------------------

## 13. Decisions to make before implementation

-   Backend language/framework the team can operate reliably.
-   Authentication provider.
-   Supported currency for the first pilot (recommend one currency per
    pot).
-   Equal vs fixed shares and how the organizer covers a remainder.
-   Whether participants pay the provider directly or a
    provider-supported group collection/booking flow is possible.
-   Legal/payment-partner feasibility for India and the exact permitted
    funds flow.
-   Who bears payment fees and how they are displayed.
-   What happens to a confirmed contribution if the group misses its
    target.
-   Whether booking status is organizer-reported or partner-verified.
-   Data retention and customer-support ownership.

**Non-negotiable release gate:** no real-money launch until the payment
flow, refund process, provider contract, and applicable compliance
obligations have been reviewed and validated.
