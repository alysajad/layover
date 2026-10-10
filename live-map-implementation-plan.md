# Implementation status (11 October 2026)

The P0 integration is implemented in migration 0003 and `app/lib/features/live_map`.
The original plan below remains as the design record. Current setup, constraints,
verification commands, and outstanding deployment gates are documented in
[Live Map operations](docs/live-map-operations.md).

Implementation adjustments: Mapbox 3.0.0 uses GeoJSON sources/layers for shared
Android/web rendering because point annotations lack a web implementation.
The unused connectivity package was removed to resolve its Linux DBus conflict
with geolocator. A scoped Android Gradle workaround applies Kotlin to Mapbox in
Flutter’s built-in-Kotlin-disabled mode. Consents also retain the last publication time, so changing
consent cannot bypass the five-second publication limit.

# Live Group Map --- Implementation Plan

**Project:** Existing Flutter group-travel app\
**Feature:** Private Live Map / Regroup\
**Date:** 11 October 2026

## 1. Product goal

Add a prominent, private live city map to the existing Flutter app.
Friends travelling together can explicitly share their current location,
see consenting group members move on a shared map, understand location
freshness, and choose a common regroup destination.

This is inspired by live activity broadcasting such as [Kailo
Live](https://kailo.fit/products/live-stream), but the goal is group
coordination, not public creator streaming.

## 2. Scope

### P0 --- first release

-   Prominent Live Map entry point on the existing home screen.
-   Create/join a private session, optionally linked to an existing
    trip.
-   Invite authorized trip members.
-   Per-member, per-session explicit location consent.
-   Shared map with member markers, name/avatar, and
    last-updated/freshness status.
-   2D map first; supported 3D buildings/terrain as a progressive
    enhancement.
-   Choose a regroup destination from a map tap; place search can follow
    if a provider is already available.
-   Show destination pin and approximate distance to current consenting
    members.
-   Start/stop sharing, leave session, and organizer end-session
    controls.
-   Session expiry, permission-denied, GPS-inaccurate, offline, stale
    and map-error states.
-   Server-side access control, consent enforcement and session
    lifecycle.
-   Tests for consent, authorization, stale positions, revocation and
    expiry.

### P1 --- only after P0 works

-   Turn-by-turn route lines through a selected routing provider.
-   Nearby place search.
-   Low-power update mode and optional delayed sharing.
-   Push notifications for session changes.

### Explicitly out of scope

No video/audio streaming, public broadcasts, followers, chat, replays,
Strava, health stats, historical route playback, custom 3D city engine,
expense automation, booking-engine changes, or Trip Pot redesign. Do not
add these to the first implementation.

## 3. Key UX

1.  **Home:** prominent "Live Map" / "Find your group" card; preserve
    existing home features.
2.  **Session setup:** name, linked trip if applicable, invite members,
    expiry.
3.  **Consent sheet:** explain who can see location, for how long, and
    how to stop.
4.  **Live map:** map is the main canvas; member chips/list and regroup
    action in a compact bottom sheet.
5.  **Member detail:** last updated, sharing/stale state, distance to
    destination.
6.  **Destination picker:** tap map to set a shared meeting point.
7.  **Controls:** stop/pause sharing, leave, end session.
8.  **Fallbacks:** permission denied, poor GPS, offline, stale, expired,
    map unavailable.

## 4. State model

Session: `created`, `active`, `ended`, `expired`, `cancelled`.

Membership: `invited`, `joined`, `left`, `removed`.

Sharing: `not_sharing`, `sharing`, `paused`, `stopped`, `stale`.

`stale` is a freshness condition, not proof that the person
intentionally stopped. A stopped or expired member's exact location
should disappear by default; don't show an old point as live.

## 5. Architecture principles

-   Inspect the repository first; reuse existing authentication,
    user/trip models, routing, state management, theme, API client,
    backend and realtime transport.
-   Do not duplicate users/trips or add a second auth system.
-   Isolate map SDK details behind a small map-provider adapter.
-   Isolate device location acquisition from session/realtime transport.
-   Server rules are authoritative; hiding a button in Flutter is not
    security.
-   Derive the publishing user from verified authentication, never trust
    a client-supplied user ID.
-   Use a private, authorization-checked realtime channel.
-   Store only the latest location per session/member; no location trail
    in MVP.
-   Validate coordinates, accuracy, timestamp, sequence, rate and active
    consent.
-   Use server receive time for freshness.
-   Session end/expiry and consent revocation must promptly stop
    publishing and access.

## 6. Mapping strategy

Check the existing package and Flutter/Dart versions before adding
dependencies. If no map SDK exists, evaluate the official [Mapbox
Flutter SDK](https://docs.mapbox.com/flutter/maps/guides/), which
supports customizable maps and 3D terrain/building-style features.
Confirm SDK compatibility, pricing, token configuration, attribution and
provider terms first. Do not blindly upgrade Flutter or major
dependencies.

Start with a useful 2D map, then add supported 3D buildings/terrain.
Fall back to 2D on low-performance devices or SDK failure. Do not build
a custom 3D city from scratch.

Nearby places and route lines require a selected provider. If routing
isn't integrated, show a destination pin and clearly labelled
approximate straight-line distance; never invent an ETA.

## 7. Suggested data model

Reuse existing `users`, `trips`, and trip-membership entities.

-   `live_sessions`: id, linked_trip_id nullable, created_by, name,
    status, created_at, expires_at, ended_at.
-   `live_session_members`: id, session_id, user_id, role,
    membership_status, joined_at, removed_at. Unique
    `(session_id, user_id)`.
-   `location_sharing_consents`: id, session_id, user_id,
    consent_version, granted_at, revoked_at, sharing_status.
-   `live_locations`: session_id, user_id, latitude, longitude,
    accuracy_m, heading, speed_mps, client_timestamp, received_at,
    sequence_number. Unique `(session_id, user_id)` and overwrite the
    latest row.
-   `regroup_destinations`: id, session_id unique/current,
    set_by_user_id, name, latitude, longitude, provider_place_id
    nullable, updated_at.
-   `live_session_events`: id, session_id, actor_user_id nullable,
    event_type, redacted_metadata, created_at. Never store raw
    coordinates in the event log.

## 8. Edge cases

  -----------------------------------------------------------------------
  Scenario                            Required behavior
  ----------------------------------- -----------------------------------
  Permission denied                   Explain the reason; allow map use
                                      without sharing.

  Approximate GPS                     Display accuracy limitation; don't
                                      imply street-level precision.

  GPS jumps                           Detect implausible jumps and poor
                                      accuracy; don't falsely snap to a
                                      street.

  Network loss                        Mark stale after a configured
                                      threshold; don't pretend location
                                      is live.

  App backgrounded/killed             Reflect actual platform behavior;
                                      do not promise background tracking
                                      unless implemented and permitted.

  Member stops/leaves                 Hide exact location and revoke
                                      subscription promptly.

  Session expires                     Stop ingestion and subscriptions.

  Invite forwarded/revoked            Validate membership, token, expiry
                                      and revocation on the server.

  Out-of-order update                 Ignore older update.

  3D rendering slow                   Fall back to 2D.

  Map provider fails                  Show recoverable error and preserve
                                      session controls if possible.

  Multiple markers overlap            Cluster/fan markers and focus
                                      selected member.
  -----------------------------------------------------------------------

## 9. Privacy and security (P0)

-   Private by default; no public streams or public live-location links.
-   Joining a trip does not grant location consent.
-   Visible "Sharing live location" indicator and accessible one-tap
    stop control.
-   Session expiry and automatic stop.
-   Only current authorized session members can read consenting members'
    locations.
-   Revoke access immediately on stop, leave, removal or session end.
-   No coordinate history by default; define deletion/retention behavior
    for database backups and realtime logs.
-   TLS, server-side authorization, rate limits, restricted map tokens,
    secret management and redacted logs.
-   Request background location only if a separately approved
    requirement needs it.
-   No raw coordinates in analytics or general application logs.

## 10. Acceptance criteria

1.  Feature is prominent on the existing home screen.
2.  Existing screens, Trip Pot, authentication and navigation still
    work.
3.  At least two authorized clients can see live updates without manual
    refresh.
4.  A user's exact location is hidden until that user consents.
5.  Non-members cannot read session data or publish locations.
6.  Last-updated and stale states are obvious.
7.  Users can stop sharing; exact location access is promptly revoked.
8.  Session end/expiry stops updates.
9.  Regroup destination updates across clients.
10. 3D has a 2D fallback.
11. Permission, GPS, network, background and map-provider failures are
    tested.
12. No location trail is retained by default.

## 11. Delivery phases

**Phase 0 --- reconnaissance:** inspect app architecture, versions,
auth, trips, backend, realtime provider, map packages, home screen,
tests and uncommitted changes. Report extension points and files to
change before editing.

**Phase 1 --- vertical slice:** home entry, session creation/join,
consent, foreground location, 2D map, realtime markers, stop-sharing,
expiry and authorization tests.

**Phase 2 --- regroup + 3D:** destination pin, distance display,
supported 3D buildings/terrain, 2D fallback.

**Phase 3 --- hardening:** stale/GPS/network/background behavior,
battery/data usage, access revocation, performance and security tests.

**Phase 4 --- optional later:** place search, routes, delayed sharing or
video only after P0 acceptance criteria pass.

## 12. Integration guardrails

Do not rewrite the app, rename unrelated models, replace the home
screen, duplicate infrastructure, or make Trip Pot depend on Live Map.
Do not add video, public broadcasting or fitness features. If a required
architecture decision cannot be grounded in the repository, document the
uncertainty and ask before making a large change.
