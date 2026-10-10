# Codex Task Prompt --- Add Live Group Map to Existing Flutter App

You are modifying an existing, partially built Flutter group-travel app.
Implement **only the Live Group Map feature** described below. Do not
rewrite the application or refactor unrelated modules.

## Mandatory first step: repository reconnaissance

Before changing any files, inspect the repository and report: 1.
Flutter/Dart versions and target platforms. 2. App structure, state
management, router, theme/design system, dependency injection, API
client and tests. 3. Existing authentication, user, trip and
trip-membership models/tables. 4. Current backend/database and realtime
transport (Firebase, Supabase Realtime, WebSockets, REST polling, etc.).
5. Existing map/location packages and versions. 6. Existing home screen
and safest extension point for a prominent Live Map entry. 7. Current
coding conventions and any uncommitted user changes.

Do not assume file paths or stack choices. Reuse what exists. Do not
overwrite unrelated work. First produce a concise integration report and
list the files you propose to add/change. If a major architecture
decision cannot be grounded in the repository, ask before proceeding.

## Product goal

Add a private, session-based live city map for friends travelling
together. Members who explicitly opt in can share their latest location,
see other consenting members on a shared map, understand location
freshness, and choose a common regroup destination.

Inspiration: - https://kailo.fit/products/live-stream -
https://www.reddit.com/r/SideProject/comments/1v21lge/twitch-but-for-running/

These are inspiration, not a request to copy the product. This is a
private group coordination feature, not a public creator-streaming
platform.

## Implement P0 only

1.  Add a clear "Live Map" / "Find your group" entry point to the
    existing home screen using the app's current design system.
2.  Create a private live session, optionally linked to an existing
    trip.
3.  Invite/join authorized trip members using existing invite/deep-link
    patterns where possible.
4.  Require every member to explicitly opt in to sharing their own
    location for that session.
5.  Display consenting members on a map with name/avatar and
    last-updated/freshness status.
6.  Use a map-provider adapter. Inspect existing dependencies first. If
    no map SDK exists, evaluate the official Mapbox Flutter SDK for 3D
    support, but verify Flutter/Dart compatibility, billing/terms, token
    configuration and attribution before adding it.
7.  Implement useful 2D behavior first; add supported 3D
    buildings/terrain only if compatible. Keep a 2D fallback.
8.  Let authorized users set/update a regroup destination. Show its pin
    and approximate distance to current sharing members. Do not claim
    routing or ETA unless a real routing provider is integrated.
9.  Add stop sharing, leave session and organizer end-session controls.
10. Handle permission denial, approximate/inaccurate GPS, network loss,
    stale updates, app backgrounding/termination, expiry and map errors.
11. Add tests for consent, authorization, lifecycle and location update
    validation.
12. Update docs/config examples without exposing secrets.

## Explicit non-goals

Do NOT implement video/audio streaming, Twitch/YouTube broadcasting,
public streams, followers, likes, chat, replays, Strava, health data,
historical route playback, custom 3D city engine, expense automation,
booking-engine changes, or Trip Pot redesign. Do not add a second auth
provider, duplicate trip/user schema, or parallel backend/realtime stack
without a demonstrated need.

## Architecture and security constraints

-   Follow the existing project architecture, state management, routing,
    theme, dependency injection and error conventions.
-   Keep map SDK code behind a small adapter.
-   Separate device location acquisition from session/realtime data
    access.
-   Reuse existing auth, users, trips and trip memberships.
-   Server/backend rules are authoritative; Flutter UI checks alone are
    not security.
-   Derive publisher identity from verified auth, never trust a
    client-supplied user ID.
-   Accept a location only if the authenticated user is a current
    session member, session is active, and their own consent is active.
-   Use an existing realtime transport if suitable. Do not add multiple
    overlapping realtime technologies.
-   Store only the latest location per session/member; no location trail
    in MVP.
-   Validate coordinates, accuracy, timestamp, sequence and update rate;
    use server receive time for freshness.
-   Realtime channels must be private and authorization-checked.
-   Session end/expiry and consent revocation must promptly invalidate
    access.
-   Keep privileged keys out of Flutter. Use restricted client tokens
    where supported and server-only secrets for privileged operations.
-   Respect map attribution and provider terms.
-   Never make Trip Pot depend on Live Map or vice versa.

## Privacy and safety (P0)

-   Private by default; no public discovery or public live-location
    links.
-   Joining a trip/session is not consent to share location.
-   Show a clear explanation of who can see location and for how long.
-   Display a persistent "Sharing live location" indicator and an
    accessible one-tap stop control.
-   Apply session expiry and automatic stop.
-   When a member stops, leaves, is removed, or the session ends, hide
    exact location promptly.
-   No coordinate history by default; define deletion/retention behavior
    for database logs/backups.
-   Explain location permission in context. Do not request background
    location unless required, implemented and explicitly approved.
-   Do not log raw coordinates, invite secrets or sensitive payloads.
-   Test that non-members cannot read session data and members cannot
    publish for another user.

## Domain states

Session: `created`, `active`, `ended`, `expired`, `cancelled`.

Membership: `invited`, `joined`, `left`, `removed`.

Sharing: `not_sharing`, `sharing`, `paused`, `stopped`, `stale`.

`stale` means freshness has expired; it is not proof the user
intentionally stopped. UI must distinguish stale from stopped.

## Suggested model (adapt to existing conventions)

-   LiveSession: id, linkedTripId nullable, createdBy, name, status,
    createdAt, expiresAt, endedAt.
-   LiveSessionMember: id, sessionId, userId, role, membershipStatus,
    joinedAt, removedAt.
-   LocationSharingConsent: id, sessionId, userId, consentVersion,
    grantedAt, revokedAt, sharingStatus.
-   LiveLocation: sessionId, userId, latitude, longitude,
    accuracyMeters, heading nullable, speed nullable, clientTimestamp,
    serverReceivedAt, sequenceNumber. Unique sessionId + userId; latest
    point only.
-   RegroupDestination: id, sessionId unique/current, setByUserId, name,
    latitude, longitude, providerPlaceId nullable, updatedAt.
-   LiveSessionEvent: id, sessionId, actorUserId nullable, eventType,
    redactedMetadata, createdAt. Never store raw coordinates in events.

Reuse current user/trip IDs. Do not create duplicate Users or Trips
tables.

## Suggested UI

-   Existing home screen: prominent Live Map card/button.
-   Session setup/invite.
-   Consent sheet.
-   Live map with member markers, freshness labels, compact member list,
    regroup button and persistent stop-sharing control.
-   Regroup destination picker.
-   Session controls/end confirmation.
-   Permission/offline/stale/map-error states.

Keep the UI mobile-first. Map is the primary canvas; member details
belong in a compact bottom sheet/list. Do not add empty tabs for
deferred features.

## Acceptance criteria

-   Existing tests and home navigation still work.
-   Feature is accessible from the main home screen.
-   Authorized users can create/join a private session.
-   Exact location is hidden until that member explicitly consents.
-   Only authorized current session members can see consenting members'
    latest locations.
-   At least two clients can see updates without manual refresh using
    the selected realtime transport.
-   Last-update time and stale states are clear.
-   Stop sharing revokes location access promptly.
-   Session end/expiry stops updates/subscriptions.
-   Destination pin updates across clients.
-   3D has a safe 2D fallback.
-   Permission denial, inaccurate GPS, network loss, backgrounding and
    provider errors are handled.
-   No coordinate trail is retained by default.
-   Tests cover consent, authorization, invalid coordinates,
    stale/out-of-order updates, revocation, expiry and non-member
    access.
-   No unrelated feature/dependency changes are made without
    justification.

## Execution workflow

1.  Inspect repository and report findings.
2.  Propose minimal integration plan and exact files to change.
3.  Implement a small vertical slice in reviewable steps.
4.  After each step, run formatter, analyzer/linter and relevant tests
    using this repo's commands.
5.  Add migrations/security rules if required and explain how to apply
    them.
6.  Test realtime behavior on two clients or document a reproducible
    local simulation.
7.  Review privacy/security paths and regression risk.
8.  Summarize changed files, decisions, tests actually run, setup
    requirements, known limitations and manual provider configuration.
9.  Never claim a test passed if it was not run. If provider credentials
    are missing, use safe placeholders and explain setup.
10. Do not proceed to P1/video until P0 acceptance criteria pass.

Begin with repository reconnaissance. Do not immediately generate or
modify a large set of files.
