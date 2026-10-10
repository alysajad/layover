# Codex Prompt --- Implement Budget-Aware Trip Explorer in Existing Flutter App

You are working in an existing, partially built Flutter group-travel
app. Add one focused module: **Budget-Aware Trip Explorer**. Do not
rewrite the app or refactor unrelated features.

Read `budget-aware-trip-explorer-plan.md` and
`budget-aware-trip-explorer-erd.md` before making changes.

## Mandatory phase 0: inspect first, do not edit yet

Inspect and report: 1. Flutter/Dart versions, target platforms, current
architecture, state management, routing and design system. 2. Existing
authentication, users, trips, membership, budget, Trip Pot, and
expense-related models/APIs/tables. 3. Current map SDK, places search,
routing, geospatial and realtime dependencies. 4. Existing
backend/database, provider integrations, configuration and tests. 5.
Home/trip detail screens and the best entry point. 6. Existing
uncommitted changes and files that must not be overwritten.

Produce an integration report, provider feasibility questions, a minimal
file-change plan, and regression risks. Do not create duplicate
user/trip/budget systems. Do not modify files until this report is
ready. If a critical decision cannot be grounded in the repository, ask
before proceeding.

## Product goal

For an existing trip, allow the organizer to define a group budget and
geographic exploration zone, discover places, generate multiple
itinerary alternatives that may visit different stops, compare transport
modes and cost estimates, and save/share a recommended plan that fits
the budget.

## P0 scope

1.  Enter the feature from an existing trip: "Explore within budget".
2.  Set total budget, currency, group size, trip dates/time window, and
    optional category caps.
3.  Select a geographic area using a polygon or radius on the map.
4.  Discover places using a supported places provider, with provider
    IDs, source/freshness and category metadata.
5.  Let users select must-visit and optional places.
6.  Generate a small, diverse set of alternatives where data allows:
    -   Budget-first
    -   Time-first
    -   Explore-more within budget/time constraints
7.  Compare routes and transport modes supported by the chosen provider.
    Distinguish provider-provided alternative paths between the same
    endpoints from planner-generated itineraries with extra
    waypoints/stops.
8.  Calculate leg distances/durations, transport fare estimates when
    supported, known attraction costs, configurable allowances and
    contingency.
9.  Show group total and per-person total, itemized by category, with
    missing/uncertain prices clearly labelled.
10. Allow manual cost overrides and label them as user-entered with
    timestamp/author.
11. Save, edit and compare plan versions.
12. Share a plan within the existing trip using current
    membership/access controls.
13. Keep proposed allocations distinct from actual payments or Trip Pot
    contributions.
14. Add unit, integration and regression tests.

## Explicit non-goals

Do not implement booking checkout, ticket purchase, cab booking, pooled
money, a general-purpose scraper, scraping that bypasses
login/CAPTCHA/access controls, expense SMS reading, post-trip
settlement, Live Map, video streaming, public social feeds, or a new AI
itinerary platform. Do not redesign Trip Pot. Do not add unrelated
features.

## Provider/data-source rules

Before selecting a provider, inspect existing integrations and
evaluate: - City/transport-mode coverage - Places search and
polygon/radius query support - Alternative route and waypoint support -
Public transit/cab fare availability - API pricing, rate limits,
attribution, caching and commercial-use terms - Flutter compatibility,
token handling and platform support

Prefer official/licensed APIs, official fare tables/open data where
reuse is permitted, then manual user-entered prices. Do not build
scraping as the default price source. Never fabricate precise fare
prices or imply estimates are guaranteed. If a price is unavailable,
show "not available" or a clearly labelled range/assumption with source
and checked-at timestamp.

## Routing requirements

Use two separate mechanisms: 1. Provider-supported alternative routes
between the same origin and destination. 2. Planner-generated candidate
itineraries that add selected attractions as waypoints.

For P0, use a bounded candidate-generation strategy rather than trying
every permutation. Score candidates using budget fit, total duration,
relevance/diversity, required stops and backtracking. Return a small set
of meaningfully different plans and explain the trade-offs. Do not claim
global optimality.

## Calculation and data constraints

-   Store money as integer minor units and one base currency per plan
    for MVP.
-   Keep group costs distinct from per-person costs.
-   Model cost basis: per person, per vehicle, per group, per ticket or
    flat.
-   Unknown price is not zero.
-   Use low/high ranges when data is uncertain.
-   Avoid double-counting a whole-route fare and its component leg
    fares.
-   Show contingency separately.
-   Preserve source, checked-at time, estimate status and confidence.
-   Do not make route/price provider calls directly from widgets; use
    repository/provider adapters and caching within provider terms.

## Integration and architecture constraints

-   Follow existing folder structure, state management, navigation, UI
    theme and backend conventions.
-   Reuse existing authentication, trips, membership, budget primitives
    and currency utilities.
-   Associate plans with existing trip IDs; do not create a second Trips
    or Users table.
-   Add a provider adapter for places, routing and fare sources only as
    needed.
-   Keep the map UI separate from cost calculation and
    itinerary-generation logic.
-   Use deterministic/testable domain logic for budget arithmetic and
    scoring.
-   If exporting proposed allocations into existing Trip Pot/budget
    flows, require explicit user confirmation and use a documented
    adapter/contract. Never silently modify payment obligations.
-   Do not make this feature depend on Live Map.
-   Do not upgrade major dependencies without a clear compatibility
    reason.
-   Preserve existing functionality and uncommitted changes.

## Acceptance criteria

-   Existing app navigation and Trip Pot/budget behavior still work.
-   Organizer can define budget constraints and an exploration zone.
-   Places within/near the zone can be browsed and selected, with source
    metadata.
-   App presents multiple distinct itinerary candidates when provider
    data supports them.
-   Itineraries show stop sequence, route legs, distance/duration and
    available transport modes.
-   Known, estimated, manual and unknown costs are visibly
    distinguished.
-   Group and per-person totals are correct for shared and individual
    cost bases.
-   Budget overrun and missing prices are clearly shown.
-   User can edit and save a plan without silently mutating another
    saved version.
-   Provider failures, rate limits, missing fares and empty search
    results have graceful states.
-   Tests cover money rounding, cost-basis logic, missing data, route
    scoring, zone geometry, permissions and regressions.
-   No unauthorized scraping, secrets in source, or unrelated feature
    changes.

## Execution workflow

1.  Inspect repository and report findings; do not edit yet.
2.  Propose provider choices with evidence from the repository and
    documented trade-offs.
3.  Implement a small vertical slice: trip entry → budget/zone → places
    → save selection.
4.  Add route alternatives and bounded itinerary generation.
5.  Add cost breakdown, source/freshness labels and budget validation.
6.  Add saving/sharing and optional confirmed integration with the
    existing budget module.
7.  Run formatter, analyzer/linter and relevant tests after each stage.
8.  Test representative failure cases and verify existing features
    remain functional.
9.  Report files changed, provider configuration, migrations, tests
    actually run, known limitations and remaining decisions.
10. Do not claim that prices/routes are live or verified unless the
    provider actually supplies them.
11. Do not proceed to P1 until P0 acceptance criteria pass.

Begin with repository reconnaissance. Do not immediately generate or
modify a large set of files.
