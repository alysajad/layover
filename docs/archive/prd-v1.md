# Archived Product Requirements Document (Version 1)

Historical trip-pot-only scope. The current product requirements are in
`../../prd.md`.

## Group Travel Trip Pot --- MVP

**Version:** 1.0\
**Date:** 10 October 2026\
**Status:** Draft for hackathon implementation\
**Platform:** Flutter mobile app (Android first; iOS-compatible
architecture)\
**Product decision:** Build one excellent product: a group trip pot that
collects/coordinates commitment before a booking. Do not bundle expense
tracking, live location sharing, or arrival coordination into the MVP.

------------------------------------------------------------------------

## 1. Executive summary

Group trips often stall because one person has to pay upfront, chase
friends for money, and risk being left with the bill if someone backs
out. Existing expense-splitting apps generally help people record and
settle expenses after spending; accommodation-specific split-payment
flows do not cover an entire mixed itinerary.

The MVP lets an organizer create a trip, define one funding goal tied to
a proposed booking, invite participants, show each person's required
contribution and commitment status, and move the group through a clear
funding decision. The app should **not custody user funds**. Real
collection or reservation of funds must be delivered through a vetted,
compliant payment partner after the payment model has been validated.

### One-liner

**A group trip pot that shows whether everyone has committed before the
organizer risks paying for the booking.**

### Product promise

**"Know whether the group is financially ready before you commit to the
booking."**

### MVP success criteria

-   An organizer can create a trip pot and invite a group in under 3
    minutes.
-   Each invited member can understand the total, their share, deadline,
    and what happens if the target is not reached.
-   The organizer can see paid/confirmed/pending states without manually
    chasing a spreadsheet.
-   The app never represents a payment as successful unless confirmed by
    the trusted payment provider/server.
-   No money is held in the app's own bank account or wallet.
-   Failure, cancellation, refund, and late-payment states are explicit
    and auditable.

------------------------------------------------------------------------

## 2. Problem and opportunity

### User problem

For a group booking, the organizer may need to pay the whole amount
before everyone has committed. Informal UPI transfers and chat messages
create ambiguity: - Who has agreed to join? - How much does each person
owe? - Who has actually paid? - What happens if the minimum group total
is not reached by the deadline? - If the plan is cancelled, who is
responsible for refunds?

### Target users

1.  **Trip organizer (primary):** plans a group trip and currently
    fronts money or tracks payments manually.
2.  **Participant (secondary):** wants a clear amount, deadline,
    purpose, and trustworthy payment status.
3.  **Future partner/operator (not an MVP user):** a booking provider or
    licensed payment provider integrated later.

### Jobs to be done

-   Organizer: "Before I make a non-refundable commitment, help me know
    whether the group has committed enough money."
-   Participant: "Show me exactly what I am agreeing to pay, by when,
    and what happens if the plan is cancelled."
-   Group: "Give us one shared source of truth instead of scattered chat
    messages and screenshots."

### Market reference: Airbnb-style payment coordination

Airbnb gives useful product clues for this app, even though our product
starts before a booking is made. Airbnb currently exposes scheduled
payment options such as **Pay Part Now, Part Later** and **Reserve Now,
Pay Later** for eligible reservations. The checkout tells the guest the
payment amount, currency, schedule, due date, and cancellation
consequences before the reservation is confirmed. Airbnb also sends
reminders before upcoming charges and warns that failed scheduled
payments can lead to reservation cancellation. Source:
<https://www.airbnb.com/help/article/2143>.

Airbnb's public help also supports booking for someone else and gives
different reservation capabilities to the booker and the guest. The
booker can manage the reservation, invite guests, message the group,
request changes, and cancel; the guest can see reservation details,
message the group, invite others, leave reviews, and cancel where
allowed. Source: <https://www.airbnb.com/help/article/4134>.

Airbnb announced group split payments in 2018 as a way for friends or
family to share the cost of travel, and later expanded flexible payment
options with Pay Less Up Front. Because current Airbnb help centers the
scheduled-payment model, treat group split payment as a historical
market signal, not as a feature we can assume is still available
unchanged. Source:
<https://news.airbnb.com/airbnb-launches-pay-less-up-front-a-new-flexible-payment-option-for-travelers/>.

### How this applies to this app

-   Show the exact share, due date, currency, fees, refund policy, and
    consequence of non-payment before a participant accepts.
-   Keep organizer and participant permissions distinct, similar to
    booker and guest roles.
-   Send reminders before deadlines, but keep the backend status as the
    source of truth.
-   Let users pay early, retry safely, or update a payment method only
    when the provider and policy allow it.
-   Use clear labels for "funding target reached" and "booking
    confirmed" so users do not confuse money readiness with inventory
    reservation.
-   Keep cancellation and refund outcomes tied to the original accepted
    terms.
-   Start with mock/sandbox payments. Real-money collection, delayed
    capture, escrow-like language, or booking guarantees need provider
    and legal approval first.

------------------------------------------------------------------------

## 3. Product scope and focus

### In scope for MVP

-   Account sign-in and basic profile.
-   Create a trip and a single trip pot.
-   Define a booking/funding target, currency, participant cap,
    per-person contribution rule, deadline, and cancellation/refund
    policy text.
-   Invite participants with a deep link or invite code.
-   Participant acceptance/decline and explicit acknowledgement of the
    pot terms.
-   Contribution status tracking.
-   Payment-provider integration behind a payment abstraction, initially
    using a sandbox/mock adapter for the hackathon.
-   Server-verified payment webhooks and idempotent payment updates.
-   Progress view, deadline status, activity/audit history, and
    notifications.
-   Organizer actions to cancel a pot or mark a booking outcome, subject
    to the pot's state and provider rules.
-   Basic accessibility, loading, empty, error, and offline states.

### Explicitly out of scope for MVP

-   Automatic SMS reading or inbox scraping.
-   General-purpose expense splitting or post-trip settlement.
-   Live location sharing / regroup mode.
-   Flight or train tracking / arrival sync.
-   Booking inventory search or ticket issuance across third-party
    providers.
-   Holding user funds in an app-controlled wallet or bank account.
-   Lending, credit, investment, yield, or interest on pooled funds.
-   Complex multi-currency pooled balances.
-   Public trip discovery, social feeds, chat, or AI itinerary
    generation.
-   Guaranteed refunds or guaranteed booking availability.

### Product boundary

This is a **pre-booking commitment and payment-status product**, not a
travel super-app. Keep the home screen and data model centered on trips
and their pot. Do not add another feature merely because it is
technically possible.

------------------------------------------------------------------------

## 4. MVP user journeys

### Journey A --- Organizer creates a pot

1.  Sign in.
2.  Create a trip with a name, destination (optional), date range
    (optional), and currency.
3.  Add one proposed booking/funding goal: title, total target,
    participant limit, contribution method, deadline, and cancellation
    terms.
4.  Choose equal shares or fixed per-person amounts. The total of
    defined shares must reconcile with the target, or the UI must
    clearly show any organizer-covered remainder.
5.  Review a plain-language summary of amount, fees (if known),
    deadline, payment provider, and what happens if the target is
    missed.
6.  Create the pot and invite members.

### Journey B --- Participant joins

1.  Open an invite link/code.
2.  Sign in or create an account.
3.  Review organizer, trip, target, their share, deadline,
    cancellation/refund terms, and whether payment is refundable.
4.  Accept or decline. Acceptance records the exact terms version
    acknowledged.
5.  If payment is enabled, continue to the provider's approved checkout
    flow.
6.  Return to the app and see "Processing", "Confirmed", or a clear
    failure/retry state. A client-side success screen alone must never
    mark a payment as paid.

### Journey C --- Organizer monitors readiness

1.  View the total target, confirmed amount, remaining amount, deadline,
    and each member's status.
2.  Send a reminder to pending members (manual action in MVP; avoid
    spam).
3.  When the target is met, see "Funding target reached --- booking
    decision required" unless a verified booking integration exists.
4.  Record the booking outcome: booked, cancelled, or not booked. This
    is a recorded organizer action, not proof from a booking provider.
5.  If the deadline passes below target, the pot becomes "Target
    missed"; block new contributions unless the organizer explicitly
    extends the deadline and the policy allows it.

### Journey D --- Payment fails or is delayed

1.  Show a non-final state while the provider confirms.
2.  Allow a safe retry only after checking the existing payment attempt.
3.  Deduplicate webhook retries using provider event IDs and idempotency
    keys.
4.  Display support/reference details for unresolved transactions.
5.  Never tell the participant to pay again while an earlier attempt may
    still settle.

------------------------------------------------------------------------

## 5. Functional requirements

Priority: **P0** required for MVP; **P1** desirable if time permits;
**Later** explicitly deferred.

  ----------------------------------------------------------------------------------
  ID                Priority          Requirement       Acceptance criteria
  ----------------- ----------------- ----------------- ----------------------------
  FR-01             P0                Authentication    Users can sign in using a
                                                        supported method; private
                                                        trip data is not exposed to
                                                        unauthenticated users.

  FR-02             P0                Create trip       Organizer can create, edit
                                                        permitted fields, and view a
                                                        trip.

  FR-03             P0                Create one pot    Pot has target, currency,
                                      per MVP trip      share rule, deadline, terms,
                                                        and status. Multiple pots
                                                        per trip are deferred.

  FR-04             P0                Invite            Invite link/code is
                                      participants      revocable, expires or is
                                                        bounded by policy, and does
                                                        not expose sensitive data
                                                        before authentication.

  FR-05             P0                Join/decline      Participant explicitly
                                                        accepts or declines;
                                                        accepted terms version and
                                                        timestamp are recorded.

  FR-06             P0                Contribution      Every contribution/payment
                                      ledger            attempt has a unique ID,
                                                        amount, currency, provider
                                                        reference, and status
                                                        history.

  FR-07             P0                Trusted payment   Only server-verified
                                      status            provider events can mark a
                                                        payment
                                                        confirmed/refunded/failed.

  FR-08             P0                Progress          Confirmed funds only count
                                      calculation       toward the displayed
                                                        confirmed total; pending
                                                        amounts are separate.

  FR-09             P0                Deadline and      Pot transitions predictably
                                      target states     when target is reached or
                                                        deadline passes. State
                                                        changes are server-side.

  FR-10             P0                Cancellation flow Organizer can initiate
                                                        cancellation where allowed;
                                                        UI explains refund status
                                                        and does not promise instant
                                                        refunds.

  FR-11             P0                Audit/activity    Important actions and state
                                      log               transitions are recorded
                                                        with actor, time, and
                                                        reference.

  FR-12             P0                Permissions       Only organizer can edit
                                                        organizer-only
                                                        fields/cancel; participants
                                                        can see only trips they
                                                        belong to.

  FR-13             P0                Error and offline App distinguishes
                                      states            unavailable network,
                                                        provider processing,
                                                        failure, and confirmed
                                                        status.

  FR-14             P0                Privacy controls  Users can leave a trip where
                                                        policy allows, revoke
                                                        invites, and request
                                                        account/data deletion
                                                        according to policy.

  FR-15             P1                Notifications     Opt-in push/email reminders
                                                        for invite, deadline,
                                                        payment status, and
                                                        cancellation.

  FR-16             P1                Organizer         Extension is recorded and
                                      deadline          notified to all
                                      extension         participants; not allowed
                                                        after terminal state.

  FR-17             P1                Export/share      Share a read-only pot
                                      summary           summary without exposing
                                                        other participants' payment
                                                        details.

  FR-18             Later             Real booking      Only after a specific
                                      integration       booking partner and reliable
                                                        booking confirmation API are
                                                        selected.
  ----------------------------------------------------------------------------------

### Contribution rules

-   Store money as integer minor units (e.g., paise), never
    floating-point currency values.
-   One currency per pot in MVP.
-   Equal split: define how rounding remainders are assigned, and show
    the exact amount each person owes before acceptance.
-   Fixed shares: organizer-defined contributions must be validated
    against the target.
-   Organizer contribution is a participant contribution with the same
    audit rules.
-   Fees must be disclosed before payment when provided by the payment
    partner.
-   "Confirmed" means the provider/server confirms the transaction; it
    does not mean the booking is confirmed.

------------------------------------------------------------------------

## 6. Pot state model

Suggested state machine: - `DRAFT`: organizer is editing; not visible to
invitees. - `OPEN`: invitations accepted and contributions can be
initiated. - `FUNDING`: at least one valid payment attempt exists;
confirmed and pending totals shown separately. - `TARGET_REACHED`:
confirmed total meets target; booking decision is still required. -
`BOOKED`: organizer recorded booking, or a trusted booking partner
confirmed it in a future version. - `TARGET_MISSED`: deadline passed and
target was not met. - `CANCEL_REQUESTED`: cancellation/refund workflow
has started. - `CANCELLED`: no further contributions; final outcome
recorded. - `CLOSED`: final state after the booking/cancellation
workflow is complete.

Rules: - State transitions happen on the server, not solely in
Flutter. - Terminal states reject new payment attempts. - A delayed
provider webhook must not reopen a cancelled pot automatically;
reconcile it through an explicit exception/refund path. - If a deadline
is extended, record who extended it, the old/new deadline, and notify
participants. - "Target reached" must not imply funds are available to
spend or a booking is guaranteed.

------------------------------------------------------------------------

## 7. Non-functional requirements

### Security and privacy

-   Enforce authorization on every server endpoint and database query.
-   Never store raw card details, UPI PINs, OTPs, or payment
    credentials.
-   Use the payment provider's hosted/approved payment flow.
-   Validate webhook signatures; protect against replay; make webhook
    processing idempotent.
-   Encrypt data in transit and use managed encryption at rest.
-   Keep secrets out of the Flutter app and source repository.
-   Minimize personal data. Do not read SMS or contacts by default.
-   Do not expose a participant's private payment method or transaction
    details to other members.
-   Maintain a clear privacy notice, consent for notifications, and
    retention/deletion policy.

### Reliability

-   Payment and pot state changes must be retry-safe.
-   All critical write operations use idempotency keys.
-   Use server time as the authority for deadlines.
-   Provide safe recovery after app closure or network interruption.
-   Log provider event IDs and internal references without logging
    sensitive payment data.

### Performance and usability

-   Typical trip and pot screens should load within 2 seconds under
    normal network conditions, excluding third-party provider latency.
-   Use pagination for activity history if needed.
-   Make payment state and deadlines visually unambiguous.
-   Meet baseline Flutter accessibility requirements: semantic labels,
    scalable text, contrast, and touch target sizes.

### Observability

-   Track crashes, API error rate, webhook failures, payment-state
    mismatches, duplicate events, and pot state-transition errors.
-   Add alerts for repeated webhook verification failures or
    unreconciled payments.
-   Provide a support reference ID on payment issues.

------------------------------------------------------------------------

## 8. Suggested information architecture / screens

1.  **Welcome / Sign in**
2.  **Home --- My trips**: trips and status; primary action "Create
    trip"
3.  **Create trip**: trip details
4.  **Create pot**: target, currency, share rule, deadline, terms
5.  **Invite members**: share link/code, member list
6.  **Trip pot overview**: target progress, confirmed vs pending,
    deadline, member statuses
7.  **Contribution details**: personal share, terms, payment
    initiation/status
8.  **Activity**: auditable timeline
9.  **Cancellation / outcome**: clear consequences and current refund
    state
10. **Profile / privacy / notification settings**

Avoid tabs for features that do not exist. A small app with a clear flow
is better than a dashboard full of empty modules.

### Feature expansion backlog

These features can extend the product after the MVP proves that groups
will use a pot before booking. Keep them behind evidence and compliance
checks.

#### Strong next features

-   **Smart reminders:** deadline nudges by push, email, or WhatsApp
    deep link, with rate limits and opt-outs.
-   **Payment schedule:** allow deposits, staged due dates, or "pay part
    now, part later" when a provider supports it.
-   **Payment method update:** let a participant replace a failed
    payment method without creating a duplicate attempt.
-   **Pay early:** let a participant complete a scheduled payment before
    the due date.
-   **Organizer-covered remainder:** show when the organizer chooses to
    cover rounding, empty seats, or a discount gap.
-   **Member replacement:** allow the organizer to replace a declined or
    removed member while preserving the audit trail.
-   **Terms amendment flow:** require participants to re-accept if the
    organizer changes amount, deadline, refund terms, or participant
    count.
-   **Read-only share card:** generate a shareable summary that hides
    private transaction references.
-   **Support reference center:** show payment attempt ID, provider
    reference, latest status, and next step for unresolved payments.
-   **Organizer checklist:** guide the organizer through invite, accept,
    collect, book, cancel, and close states.

#### Booking-adjacent features

-   **Booking window:** after target reached, give the organizer a
    limited window to record the booking decision.
-   **Provider-confirmed booking:** connect to a booking partner that can
    confirm inventory and final price.
-   **Price-change handling:** ask members to approve a higher amount if
    the booking price changes before purchase.
-   **Availability warning:** show that funding readiness does not hold
    inventory unless a partner confirms a reservation.
-   **Deposit-only pot:** collect or coordinate a smaller commitment
    amount first, then schedule the balance.
-   **Booking-for-someone roles:** support a payer who is not traveling,
    with separate visibility and responsibility rules.

#### Group coordination features

-   **Participant notes:** let a member add private notes such as "paying
    Friday" without changing payment status.
-   **Manual commitment mode:** allow a no-money demo or low-trust pilot
    where members confirm intent before real payments exist.
-   **Waitlist:** keep extra interested members outside the pot until a
    slot opens.
-   **Group approval threshold:** mark a pot ready when a minimum number
    of seats or amount is reached, not necessarily the full group.
-   **Private member visibility:** let the organizer see detailed
    statuses while participants see only aggregate readiness.
-   **Dispute flag:** let a participant flag the amount or terms before
    accepting.

#### Finance and compliance features

-   **Fee transparency:** show provider fee, platform fee, tax, and net
    target separately.
-   **Refund tracker:** show each refund as requested, pending,
    completed, failed, or partially refunded.
-   **Overpayment handling:** flag duplicate confirmed payments and route
    them to refund/reconciliation.
-   **Payment provider switchboard:** support multiple providers behind
    the adapter after legal review.
-   **KYC/compliance hooks:** add identity or risk checks only if a
    chosen payment model requires them.
-   **Data export/deletion:** give users a policy-compliant export and
    deletion request flow.

#### Later product bets

-   **Accommodation-specific mode:** tailor pot terms for Airbnb-style
    stays, hotels, villas, or homestays.
-   **Transport pot mode:** support a separate flow for flights, trains,
    buses, or car rentals only after the one-pot model works.
-   **Multi-pot trips:** allow stay, transport, and activities as
    separate pots after users prove they need more than one funding goal.
-   **Trip template library:** save common pot structures for repeat
    organizers.
-   **Partner offers:** let booking partners offer inventory or discounts
    to groups that reached funding readiness.
-   **Post-booking expense export:** export pot data into Splitwise or
    another expense tool instead of building a full expense tracker in
    this app.

------------------------------------------------------------------------

## 9. Product and business model hypotheses

Do not optimize monetization before validating trust and completion.
Possible future models: - Transparent per-booking service fee paid by
organizer or group. - B2B fee from booking partners. - Premium organizer
tools only if repeat organizers demonstrate willingness to pay.

Airbnb's payment model suggests two business lessons: flexible payment
timing can reduce the upfront burden on travelers, and payment clarity
can increase confidence before a stay. Our app should use those lessons
without copying Airbnb's marketplace role. We do not own inventory, run
host payouts, or guarantee a reservation in the MVP.

Avoid taking an undisclosed percentage of pooled money. Never imply that
user funds are insured, escrowed, or refundable unless the actual
partner/legal arrangement supports that claim.

------------------------------------------------------------------------

## 10. Metrics

### North-star metric

**Groups that reach a valid funding decision before their booking
deadline.**

Supporting metrics: - Trip creation completion rate. - Invite-to-join
conversion. - Share acceptance rate. - Percentage of pots reaching
target before deadline. - Median time from pot creation to target
decision. - Payment initiation-to-provider-confirmation rate. - Payment
mismatch/reconciliation rate. - Cancellation/refund completion time
(measured from provider-confirmed timestamps). - Support contacts per
100 pots. - Repeat organizer rate.

Guardrails: - Zero unauthorized disclosure of trip/payment data. - Zero
app-side false "paid" confirmations. - Track duplicate charges,
unhandled refunds, and unresolved payment states. - Monitor
invite/reminder complaints and opt-outs.

------------------------------------------------------------------------

## 11. Risks, assumptions, and decisions

  -----------------------------------------------------------------------
  Risk / assumption       Why it matters          Mitigation / decision
  ----------------------- ----------------------- -----------------------
  Users may not trust a   A group pot creates     Use a recognized
  new app with group      high trust expectations payment provider;
  payments                                        transparent terms; no
                                                  app-held funds.

  Payment regulations and "Hold until everyone    Obtain India-specific
  provider capabilities   commits" may require a  legal/payment-partner
  vary                    regulated product or    review before
                          specific rail           real-money launch.
                                                  Prototype with
                                                  sandbox/mock payments.

  Booking may sell out    Funding does not        Label the state
  after target is reached reserve inventory       accurately; add a
                                                  short, disclosed
                                                  booking window only if
                                                  supported by the
                                                  provider.

  Partial funding creates Members may pay while   Define
  refund complexity       the target is missed    cancellation/refund
                                                  policy before payment;
                                                  model each refund
                                                  separately.

  Webhooks can be late,   Incorrect totals can    Idempotency, signed
  duplicated, or out of   damage trust            webhooks, event ledger,
  order                                           reconciliation job.

  Organizer could         Users may confuse       Label manually recorded
  misrepresent booking    organizer updates with  outcomes as
  status                  provider proof          organizer-reported
                                                  until partner
                                                  verification exists.

  Unequal shares and      Disputes about who owes Freeze and show exact
  rounding are confusing  what                    shares before
                                                  acceptance; log all
                                                  amendments.

  Group members may       Membership changes      Freeze a participant's
  change plans            affect target math      accepted share; changes
                                                  require explicit
                                                  re-acceptance and audit
                                                  trail.

  Refund timing is        App cannot guarantee    Show provider status
  controlled by           settlement speed        and expected ranges
  provider/bank                                   only when sourced from
                                                  provider.

  Legal obligations       Can block launch        Get professional review
  around payments/data                            before processing real
  are unclear                                     money; do not market as
                                                  escrow without
                                                  authorization.
  -----------------------------------------------------------------------

### Assumptions to validate with 5--10 target users

-   Organizers currently front meaningful costs or spend time chasing
    transfers.
-   Participants will accept a new flow before a booking is made.
-   A pot for one booking goal is enough to deliver value.
-   Users understand the distinction between reaching a funding target
    and securing a booking.
-   Groups will tolerate a clear deadline and cancellation policy.

------------------------------------------------------------------------

## 12. Delivery plan

### Phase 0 --- Validate before building real payments

-   Interview 5--10 organizers and participants.
-   Test a clickable flow and plain-language cancellation/refund terms.
-   Confirm payment-provider and legal feasibility for the intended
    India launch.
-   Decide whether the product can launch first as a commitment tracker
    with sandbox payments.

### Phase 1 --- Hackathon MVP

-   Flutter app with authentication, trip creation, one pot, invite
    flow, shares, statuses, progress, activity log.
-   Backend API and database.
-   Mock/sandbox payment provider adapter.
-   Simulated webhook events for success, pending, failure, duplicate,
    and refund.
-   Demo with one group reaching target and one missing the deadline.

### Phase 2 --- Controlled pilot

-   Integrate one approved payment provider.
-   Complete security, privacy, refund, support, and reconciliation
    review.
-   Pilot with a small group of users and low operational complexity.
-   Do not claim money is held or bookings are guaranteed unless that is
    true contractually and technically.

### Phase 3 --- Evidence-led expansion

-   Improve reminders, exports, organizer tools, and booking-provider
    integration based on pilot evidence.
-   Add Airbnb-style scheduled payment behavior only if the selected
    provider supports the flow and the terms explain failed-payment and
    cancellation consequences.
-   Consider arrival sync only after the core pot has reliable usage and
    retention.
-   Keep expense auto-capture and regroup mode outside the core product
    unless research proves a strong need.

------------------------------------------------------------------------

## 13. Release acceptance checklist

-   [ ] User can create a trip and exactly one MVP pot.
-   [ ] Invite link is permission-checked and revocable.
-   [ ] Each participant sees and acknowledges their exact share and
    terms.
-   [ ] Confirmed totals exclude pending/failed/refunded transactions.
-   [ ] Duplicate/out-of-order webhook events do not double-count
    payments.
-   [ ] Target reached and deadline missed transitions are
    server-authoritative.
-   [ ] Cancellation and refund states are visible and truthful.
-   [ ] No sensitive payment credentials or secrets are stored in the
    app.
-   [ ] All important changes appear in the activity log.
-   [ ] Loading, offline, empty, and provider-error states are tested.
-   [ ] Real-money mode is disabled until provider, compliance, and
    refund flows are approved.
