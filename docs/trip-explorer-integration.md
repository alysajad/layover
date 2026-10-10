# Trip Explorer integration report

## Inspection (11 October 2026)

- Runtime: Flutter 3.47.7, Dart 3.13.5. Repository targets Android and web.
- State/navigation: Riverpod owns `TripStore`; screens use ChangeNotifier and
  Material routes. Use the existing Material 3 theme in `app/app/theme.dart`.
- Authentication: Supabase email OTP, `profiles`, `trips`, and joined
  `trip_members`. Reuse `is_trip_member` and organizer ownership checks.
- Money: companion domain provides integer minor-unit parsing and stable
  allocation. Trip Pot, obligations, expenses and transfers stay separate.
- Backend: migrations 0001–0003, checked RPC writes, RLS reads; PGlite tests.
- Maps: Mapbox 3.0.0 and a public build token. No existing places, routing, or
  fare client. Geolocator/Live Map are not dependencies of this feature.
- Entry point: existing trip Overview. Joined members can view shared versions;
  organizers create drafts and share them.
- Existing dirty files include PLAN.md, architecture.md, app README, Android
  configuration, Live Map code/tests/migration/tools. Preserve those changes.

## Provider decision

Use Geoapify Places and Routing through an authenticated Supabase Edge Function.
Reuse the existing Mapbox SDK for map rendering. No dependency upgrade is needed.
Geoapify's [Places API](https://www.geoapify.com/places-api/) permits storage with
Geoapify/OpenStreetMap attribution. Query a bounded circle or polygon bounding
box, then apply exact zone containment in the app. Limit each search to 40 places.

The [Routing API](https://apidocs.geoapify.com/docs/routing/) provides legs and
geometry for walking, cycling and driving. Compare balanced and short paths
with identical waypoints; suppress duplicate paths. These are distinct from
planner-generated stop sequences. No cab quotes or ticket prices are supplied.
Geoapify also [permits storing routing results](https://www.geoapify.com/routing-api/),
so saved plan snapshots can retain route geometry with attribution.
Do not treat bus-road routing as a public-transit timetable. P0 omits transit.

The [pricing page](https://www.geoapify.com/pricing/) currently lists 3,000 daily
credits and 5 requests/second for the free tier. Billing depends on API inputs;
confirm the selected account's limits before deployment. Use sequential requests,
bounded generation, a short session cache, and server request throttling. An API
key/account and a Mapbox public token are deployment inputs, not source secrets.
No live coverage or fare verification has occurred. Target-city coverage remains
a deployment check. Unconfigured connected builds report provider unavailability;
demo builds use explicitly labelled synthetic fixtures.

## Physical mapping of the logical ERD

`exploration_plans` stores one immutable row per saved version. `plan_id` links
versions; `parent_id` records the source version. Typed columns hold trip, author,
currency, budget, group size, time window, version and sharing state. A bounded
JSON snapshot holds zone, selected places, itineraries, stops, route legs, fare
and activity cost items, category caps and versioned calculation assumptions.
Place provider IDs and cost IDs remain stable inside the snapshot. This avoids
mutable shared provider records changing historical recommendations.

Use existing trip membership instead of the ERD's undeclared PLAN_MEMBERS table.
`exploration_plan_events` records redacted save/share events. Allocations stay as
estimates; no Trip Pot export is included because it is optional and the current
contract concerns actual obligations. No second trips/users/budget system.

## Minimal change plan and risks

Add `features/trip_explorer/{domain,data,presentation}`, feature tests, migration
0004, a provider Edge Function, and operation notes. Add one Overview entry.
Format the plan and append implementation/verification status.

Tests must cover cost basis/ranges/unknowns/rounding, geometry, bounded candidate
generation, provider failures, immutable saves, account changes and permissions.
Run existing Flutter and database suites plus web compilation. Risks include
provider coverage and rate limits, false budget certainty, stale async responses,
cross-trip disclosure, map token/platform failures and inadvertent financial
writes. Use explicit unavailable states, generation invalidation, RLS/RPC checks,
and a feature-specific snapshot contract to address them.
