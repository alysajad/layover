# Budget-aware Trip Explorer

Open a trip's **Overview → Explore within budget**. Organizers set the currency,
group budget, dates, time window, category caps and discovery area. A radius uses
the start point as its center. For a polygon, tap vertices or enter coordinates.
Routes may leave the discovery zone.

Find places, select must-visit or optional stops, enter dwell times and admission
costs, then generate alternatives. Compare costs, stops, walking/cycling/driving
and provider paths. Save a new version and share it with current trip members.
Members can open shared versions from the same entry point. Editing an older
version creates another version in its history. No payment records change.

## Deployment

1. Apply `supabase/migrations/0004_trip_explorer.sql` after migrations 0001–0003.
2. Deploy `supabase/functions/trip-explorer`. Its handler authenticates the JWT
   and checks organizer access through `explorer_provider_access`.
3. Set server secret `GEOAPIFY_API_KEY` in the Supabase project. The runtime also
   uses its existing `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Do not place the
   Geoapify secret or service-role credentials in Flutter build configuration.
4. Set the existing `MAPBOX_PUBLIC_TOKEN` build value for geographic map rendering.
   Keep the provider's default logo, attribution and telemetry controls visible.
5. Test a real trip with organizer/member/removed accounts and confirm target-city
   coverage, account quotas, saved geometry and attribution before release.

No hosted migration or deployment runs as part of local implementation. Without
the provider function/key, connected mode reports service unavailability. It does
not replace real results with demo fixtures. Without a Mapbox token, numeric area
entry, lists and cost controls remain available.

## Data and calculations

`exploration_plans` stores immutable snapshots with lineage and source-version IDs.
Each snapshot holds zone, places, itinerary stops, legs, cost items, assumptions
and the selected recommendation. The server authorizes and validates saves, stamps
new manual costs with actor/time, and records save/share events. Row-level policies
allow joined members to read shared plans; the organizer also sees drafts.

Zone coordinates use WGS84 longitude/latitude. A circle stores center and radius
in metres; a polygon stores an ordered vertex array with implicit closure. The
map adapter constructs GeoJSON from these values. P0 uses draft, ready and shared
states; approval workflows and plan archiving are outside this implementation.

Money uses integer minor units. Per-person costs multiply by group size and
quantity; vehicle, ticket, group and flat costs multiply by explicit quantity.
Enter the number of vehicles or tickets needed. Equal per-person summaries use
the existing stable remainder allocation. The app rejects amounts whose expanded
total would exceed JavaScript's exact integer range.

Unknown prices contribute an unknown count, never a free price. A displayed range
with unknowns is a subtotal. Walking assumes no paid transfers; cycling assumes
the travelers own bicycles. Any provider-reported toll/ferry adds an unknown fee.
A whole-route fare replaces its covered leg fares. Contingency stays separate.

Confidence values are `unknown`, `assumption`, and `user_supplied`; none denotes
a verified quote. The schema retains provider-quote/published-tariff statuses for
sources that actually supply them; this integration supplies route metrics, not
fare quotes. User-entered prices carry their source, actor and checked-at time.

## Provider use and limits

Geoapify supplies places and route metrics. See the
[provider decision and source links](trip-explorer-integration.md#provider-decision).
Search returns up to 40 places. Polygon searches use a bounding rectangle followed
by exact client containment; the bounded result set is not an exhaustive survey.
Circle radii are 100–30,000 m; polygons have 3–20 vertices within a one-degree
extent. Polar and antimeridian areas are outside this P0 geometry contract.

Generation uses at most six candidate sequences, three modes and two path
optimizations, with up to eight stops. The app picks up to three distinct
stop-sequence/mode results. It shows duplicate-free provider paths separately.
Must-visit stops remain mandatory. Ranking prefers feasible, fully priced plans,
then budget, duration or stop relevance/diversity, with excess route distance as
a tie-breaker. For budget-first candidates, fewer unknown costs rank ahead of a
smaller subtotal. Missing prices cannot make an option appear cheaper by omission.

The repository caches successful responses for five minutes, at most 60 entries,
and discards its cache on route disposal. Saved snapshots retain provider timestamps.
The server limits each organizer to 60 proxy requests/minute. Provider-wide quotas
still apply across users. Rate limits, empty results, unavailable alternative paths
and failed modes produce visible states. No automatic paid account upgrade occurs.

The app does not validate opening hours, timetable departures, cab availability
or actual ticket prices. Adjust dwell times and manually check opening hours.
Proposed allocations never create Trip Pot contributions or payment obligations.

## Local verification

From `app/`:

```sh
flutter analyze
flutter test
flutter build web --release
```

From the repository root, using the existing isolated test dependencies:

```sh
NODE_PATH=/tmp/layover-check/node_modules node supabase/tests/trip_explorer.cjs
NODE_PATH=/tmp/layover-check/node_modules node supabase/tests/trip_explorer_provider.cjs
NODE_PATH=/tmp/layover-check/node_modules node supabase/tests/companion.cjs
NODE_PATH=/tmp/layover-check/node_modules node supabase/tests/reminders.cjs
NODE_PATH=/tmp/layover-check/node_modules node supabase/tests/live_map.cjs
```

The explorer database suite applies all four migrations in isolated PGlite. It
checks retries, immutable versions, manual provenance, sharing, access removal,
archive behavior, request quotas and absence of financial writes. Flutter tests
exercise money, geometry, planner bounds, permissions and the full demo flow at
360 px and 1200 px. Provider contract tests use fixtures and do not prove live
coverage. Hosted behavior and physical-device map rendering remain separate checks.

## Verification results

Local checks on 11 October 2026:

| Check | Result |
| --- | --- |
| Flutter analyzer | Passed |
| Flutter tests | 41 passed, including 8 explorer tests |
| Web release build | Passed |
| Android debug APK | Passed; existing Firebase/Mapbox plugins emit Kotlin migration warnings |
| Explorer database suite | Passed against all four migrations in PGlite |
| Provider tests | Passed request/response mapping, auth, quotas, failures and CORS |
| Existing database suites | Companion, reminders and Live Map passed |
| Browser workflow | Discover → select → compare → save → share passed at 390 px and 1440 px |

Run `app/tool/trip_explorer_browser.cjs` with the existing Playwright installation
and a local preview at port 5174 (override with `PREVIEW_URL`). Set `CHROMIUM_PATH`
when using an installed Chromium binary. It writes screenshots to
`/tmp/layover-explorer-390.png` and `/tmp/layover-explorer-1440.png`.
