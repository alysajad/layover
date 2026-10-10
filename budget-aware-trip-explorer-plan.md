# Budget-Aware Trip Explorer: Product and Implementation Plan

| Item | Decision |
| --- | --- |
| Target | Existing Flutter group-travel application |
| Module | Additive feature attached to an existing trip |
| Release target | P0 |
| Status | Implemented locally; deployment and live-provider checks pending |

This plan turns [the implementation prompt](codex-budget-aware-trip-explorer-prompt.md) into an
implementation sequence. [The logical ERD](budget-aware-trip-explorer-erd.md) defines the
logical entities and relationships. Before coding, map every entity to the
repository's existing naming, migrations, authentication, membership,
money, navigation, and testing conventions.

Read the [integration report](docs/trip-explorer-integration.md) for the repository
inspection, provider evidence and physical schema mapping. The
[operations guide](docs/trip-explorer-operations.md) records configuration,
verification and current limits.

## 1. Outcome

An organizer opens an existing trip, defines a budget and exploration zone,
selects places, generates a small set of distinct itinerary candidates,
compares route and cost trade-offs, then saves and shares a plan with trip
members. The feature presents proposed costs and allocations. It does not
create payments, Trip Pot contributions, bookings, or settlement records.

The organizer should be able to answer four questions from the saved plan:

1. What places will the group visit, and in what order?
2. How long will the plan take, and which transport modes are available?
3. What will the group and each person likely pay?
4. Which figures are sourced, estimated, manual, stale, or unknown?

## 2. Scope boundary

### P0 deliverables

- Entry from an existing trip through **Explore within budget**.
- Budget, currency, group size, dates, time window, and optional category caps.
- One polygon or radius exploration zone, stored as validated WGS84/GeoJSON.
- Provider-backed place discovery with source, provider ID, category, and
  freshness metadata.
- Must-visit, optional, and excluded place selection.
- Bounded generation of distinct `Budget-first`, `Time-first`, and
  `Explore-more` candidates when provider data supports them.
- Provider route alternatives for the same endpoints, kept distinct from
  planner-generated waypoint itineraries.
- Supported transport modes, route legs, distances, durations, and fare
  estimates where available.
- Known activity costs, configured allowances, contingency, low/high ranges,
  cost basis, source, checked-at time, status, and confidence.
- Group and per-person totals with itemized categories and visible unknowns.
- Manual cost overrides labelled with author and timestamp.
- Immutable generated candidates; edits create a new saved plan version.
- Share access through the existing trip membership and authorization rules.
- Unit, integration, and regression tests.

### Explicitly out of scope

Booking, checkout, ticket purchase, cab booking, pooled money, expense
settlement, SMS expense reading, Live Map, video, public feeds, a general
scraper, CAPTCHA/login bypass, a new users/trips system, and a new AI
itinerary platform are not part of this module. Do not redesign Trip Pot.

## 3. Mandatory phase 0: repository reconnaissance

Do not edit application code or migrations until this report exists.

Inspect and record:

- Flutter and Dart versions; supported platforms; build flavors.
- Folder/module structure, state management, routing, dependency injection,
  design tokens, localization, error handling, and analytics conventions.
- Existing user, trip, membership, budget, Trip Pot, expense, currency, and
  permission models/APIs/tables.
- Existing map SDK, places search, route, geospatial, caching, and realtime
  dependencies.
- Backend/database conventions, migration process, provider configuration,
  secret handling, and test fixtures.
- Home and trip-detail screens; the smallest consistent entry point.
- Uncommitted changes and files that the feature must not overwrite.

The report must include:

1. Findings with file/module references.
2. Provider feasibility questions and evidence still needed.
3. A minimal file-change plan.
4. Integration and regression risks.
5. Decisions that require product or engineering approval.

If the repository cannot answer a critical provider, authorization, or data
ownership question, stop before implementation and ask for that decision.

## 4. Integration decisions

Reuse existing primitives in this order:

1. Existing trip ID, user ID, membership, and organizer checks.
2. Existing money and currency utilities.
3. Existing map, place, routing, HTTP, caching, and configuration layers.
4. Existing navigation, state, loading, empty, error, and attribution UI.
5. Existing database migration, row-level authorization, audit, and test
   helpers.

Do not add duplicate `users` or `trips` tables. Associate every
`ExplorationPlan` with an existing `trip_id`. Keep the map surface,
provider adapters, cost engine, planner, persistence, and widgets separate.
Widgets must not call route, places, or fare providers directly.

If the existing budget or Trip Pot module accepts proposed allocations, add
an explicit adapter with a user-confirmed export action. The adapter must
carry stable plan/version IDs and must not silently create or modify payment
obligations.

## 5. Provider decision record

Before selecting or adding a provider, inspect existing integrations and
document the following for places, routing, and fares:

- City and transport-mode coverage.
- Polygon/radius search support and result limits.
- Same-endpoint alternative route support.
- Waypoint limits and route-matrix support.
- Public-transit and cab fare availability.
- Flutter/platform compatibility and token handling.
- API pricing, rate limits, caching rules, attribution, and commercial-use
  terms.
- Whether each value is a quote, published tariff, estimate, or unavailable.

Prefer official or licensed APIs, then permitted official fare tables/open
data, then manual user-entered prices. Do not make scraping the default.
Store only fields the provider terms allow the app to cache.

The decision record must name:

- Place provider and adapter contract.
- Routing provider and adapter contract.
- Fare source(s), including unsupported modes/cities.
- Cache and refresh policy.
- Attribution placement.
- Fallback behavior when a provider fails, rate-limits, lacks coverage, or
  returns no price.

## 6. Data model implementation

Implement the logical ERD using project conventions. Preserve the following
semantics even if table or class names differ.

### Exploration plan and zone

`ExplorationPlan` belongs to an existing trip and stores creator, title,
base currency, integer `total_budget_minor`, group size, time window, status,
and version. Use the ERD statuses: `draft`, `generating`, `ready`, `shared`,
`approved`, and `archived`.

`ExplorationZone` stores one polygon or radius geometry with a declared
coordinate format. Validate latitude/longitude bounds, radius limits, and
polygon vertex/size limits. The zone filters discovery. It is not a live
location alert or security boundary; route legs may leave it to reach a stop
or transit hub.

### Places and selection

`Place` stores provider, provider place ID, permitted display fields,
category, coordinates, price level when available, source, and
`source_checked_at`. Use a provider identity constraint so repeated searches
reuse a known place rather than creating duplicates.

`PlanPlace` links a plan to a place and stores `selection_type`
(`must_visit`, `optional`, or `excluded`), priority, and dwell minutes.
Required stops remain distinct from recommendations. Do not call a place
“offbeat” from an unverified model guess; use disclosed source/category or
community signals.

### Itineraries and route legs

`Itinerary` belongs to a plan and records archetype, generation status,
low/high estimated total, duration, and generation time. Generated
candidates are immutable. A user edit creates a new version or candidate;
it must not mutate a previously saved recommendation.

`ItineraryStop` stores order, place, dwell assumption, and known activity
cost. `RouteLeg` connects adjacent stops or the plan start/end and stores
mode, provider route ID, distance, and duration.

Keep these concepts separate:

- Provider alternatives: different paths between the same endpoints.
- Planner alternatives: different stop sequences or added waypoints.

### Costs and audit

`FareEstimate` belongs to a route leg and stores source provider, low/high
minor-unit amounts, currency, cost basis, confidence, estimate status, and
checked-at time. `ItineraryCostItem` stores non-transport items such as
admission, activity, food allowance, tolls, local fees, and contingency.

Use the ERD cost statuses: `provider_quote`, `published_tariff`, `manual`,
`model_estimate`, and `unknown`. Use a documented confidence enum. A manual
override must preserve author and timestamp, either in the project's existing
audit model or in `PLAN_EVENTS` metadata.

`BudgetAllocation` represents proposed or approved allocation only. It is
not paid, held, committed, or a Trip Pot transaction. `PlanEvent` records
redacted plan lifecycle and sharing actions without secrets or unnecessary
personal data.

## 7. Money and calculation rules

- Use integer minor units. Never use floating point for money.
- Keep one base currency per plan for P0.
- Keep group totals and per-person totals as separate views of the same
  cost items; do not divide every item automatically.
- Model cost basis explicitly: `per_person`, `per_vehicle`, `per_group`,
  `per_ticket`, or `flat`.
- Apply each cost basis according to a documented allocation policy.
- Unknown is not zero. Keep unknown items visible and mark the total
  incomplete when they prevent a complete estimate.
- Propagate low/high bounds consistently: sum lower bounds and upper bounds
  for the same included items.
- Keep contingency as a separate category and cost item.
- Never double-count a whole-route fare with its component leg fares.
- Record estimate status, source, confidence, checked-at time, and the
  assumptions used for each material estimate.
- Record the author and timestamp for manual values.

The cost engine must be deterministic and independent of Flutter widgets or
provider clients. Unit-test rounding, group-size handling, shared versus
individual costs, ranges, unknowns, contingency, overrides, and duplicate
fare prevention.

## 8. Bounded itinerary generation

The planner must not try every permutation and must not claim global
optimality.

1. Filter discovered places by zone, selected categories, preferences, and
   available time/opening data.
2. Keep must-visit places mandatory.
3. Bound optional candidates by relevance, distance, category diversity,
   available cost data, and a configured maximum.
4. Generate a bounded set of stop sequences. Use a deterministic seed or
   stable ordering so tests and repeated runs are explainable.
5. Request/cache routes for each leg within provider limits.
6. Calculate duration, distance, known/estimated cost, missing cost,
   budget overrun, and feasibility.
7. Score with explicit weights for budget fit, duration, relevant stops,
   category diversity, must-visit coverage, and backtracking.
8. Remove near-duplicates and return a small diverse set.
9. Label each result with its trade-off and data limitations.

P0 archetypes:

- **Budget-first:** lowest estimated total while covering required stops.
- **Time-first:** shortest total travel plus dwell duration.
- **Explore-more:** most relevant/diverse stops within available budget and
  time constraints.

If provider data cannot support a candidate, show a graceful unavailable
state rather than fabricate a route, fare, or precise price.

## 9. User experience and flow

### Screens and states

1. Existing trip detail → **Explore within budget**.
2. Budget and trip constraints: total, currency, group size, dates, time
   window, category caps, contingency, and assumptions.
3. Map zone selector: polygon or radius, validation, clear boundary meaning.
4. Place discovery: search/filter, source/freshness, attribution, loading,
   empty, rate-limit, and provider-error states.
5. Place selection: must-visit, optional, excluded, priority, dwell time.
6. Candidate comparison: map, stop sequence, route legs, mode, duration,
   distance, total range, per-person range, and trade-off label.
7. Cost breakdown: transport, admission/activity, food, local fees,
   contingency, unknowns, source/status/confidence, and manual overrides.
8. Itinerary editor: reorder/remove/add supported places, edit dwell times,
   enter costs, and create a new version.
9. Save/share: version name, membership-based access, and permission errors.
10. Saved plans/version history: compare and restore by creating a new
    editable version, not by silently rewriting history.

Do not crowd the map with the full cost model. Use a compact plan panel and
an accessible detail view. Show “not available” or a labelled range when a
price is missing. Show budget overrun and incomplete-estimate warnings
before the user saves or shares.

## 10. Delivery sequence

| Phase | Deliverable | Verification |
| --- | --- | --- |
| 0 | Repository inspection and provider decision | Integration report |
| 1 | Trip entry, constraints, zone, places and saved selection | Widget and repository tests |
| 2 | Routes, bounded candidates and comparisons | Planner and provider contract tests |
| 3 | Itemized costs, overrides and budget status | Money and cost-basis tests |
| 4 | Immutable versions and trip sharing | Database authorization and regression tests |

### Phase 0: reconnaissance and decisions

Produce the integration report, provider decision record, schema mapping,
minimal file list, and risk register. Confirm authorization and migration
patterns before edits.

### Phase 1: vertical slice

Add trip entry, plan draft persistence, budget constraints, zone selection,
place adapter/repository, place discovery, selection, and save-selection
flow. Reuse existing map and design system. Add loading, empty, and failure
states. Run formatter, analyzer/linter, unit tests, and the relevant app
tests.

### Phase 2: routing and candidate generation

Add routing and fare adapter interfaces, cached provider calls, route legs,
provider alternatives, waypoint candidates, deterministic scoring, and
candidate comparison. Test provider failure, rate limits, unsupported modes,
empty results, and near-duplicate removal.

### Phase 3: cost transparency

Add the cost engine, ranges, cost basis, activity items, contingency,
unknowns, source/freshness labels, confidence, manual overrides, and budget
validation. Verify no double-counting and correct group/per-person totals.

### Phase 4: persistence and sharing

Add immutable generated candidates, user-edited versions, version comparison,
plan sharing through existing membership/access controls, audit events, and
the optional explicit allocation-export adapter if the repository supports
it. Add permission and regression tests.

Do not begin P1 work until P0 acceptance criteria pass.

## 11. Test plan

### Unit tests

- Minor-unit arithmetic and rounding.
- Cost-basis expansion for group, person, vehicle, ticket, and flat costs.
- Low/high range propagation and contingency.
- Unknown and incomplete totals.
- Manual override author/time metadata.
- Duplicate whole-route/component fare protection.
- Zone radius and polygon validation.
- Candidate scoring, deterministic ordering, budget fit, must-visit
  coverage, diversity, and backtracking penalties.
- Version immutability and new-version creation.

### Integration tests

- Existing trip entry and organizer authorization.
- Place search, provider IDs, caching, attribution, and empty/error states.
- Route modes and same-endpoint alternatives.
- Waypoint itinerary generation with bounded provider calls.
- Missing fares and manual fallback.
- Save, edit, compare, and share permissions.
- Optional confirmed export to the existing budget/Trip Pot contract.

### Regression tests

Run the existing navigation, trip detail, budget, Trip Pot, authentication,
database, and map test suites. Verify that the feature works without Live
Map and that no unrelated files or schemas changed.

## 12. Acceptance checklist

The checked items have local implementation and test coverage. Live provider
coverage and hosted/device checks remain release gates below.

- [x] Organizer enters from an existing trip.
- [x] Budget, currency, group size, dates, time window, and caps persist.
- [x] Polygon/radius zone validates and persists in the agreed coordinate
      format.
- [x] Places preserve provider ID/source/freshness and support selection states.
- [x] Candidates are distinct by stop sequence or mode and explain trade-offs.
- [x] Route alternatives and waypoint itineraries remain distinguishable.
- [x] Stop sequences include leg distance, duration, and supported modes.
- [x] Manual, assumed and unknown costs are distinct; no live fare source exists.
- [x] Shared and individual cost bases produce correct group/per-person
      totals.
- [x] Ranges, contingency, overrun, and incomplete estimates are visible.
- [x] User edits create a new saved version without mutating another.
- [x] Sharing uses existing trip membership/access controls.
- [x] Provider failures, rate limits, missing fares, and empty searches have
      graceful states.
- [x] Tests cover arithmetic, geometry, scoring, permissions, and regressions.
- [x] Feature changes contain no secrets, scraping or duplicate user/trip systems.
- [ ] Apply migration 0004 and verify permissions in hosted Supabase.
- [ ] Configure provider credentials and verify target-city coverage and quotas.
- [ ] Verify Mapbox rendering and interaction on physical Android devices.

## 13. Implementation handoff report

At completion, report:

- Files and migrations changed.
- Repository integrations reused.
- Provider configuration, attribution, pricing/limits, and cache behavior.
- Tests actually run and their results.
- Known limitations by city, mode, provider, and price source.
- Open product or provider decisions.
- Whether any proposed-allocation export was implemented and how explicit
  confirmation protects existing payment data.

Never describe prices or routes as live, verified, or guaranteed unless the
selected provider supplies that fact for the displayed result.

## 14. Implementation decisions

- Use the existing trip Overview, Material theme, TripStore authentication,
  membership checks, minor-unit parsing and equal-split helper.
- Render maps with the installed Mapbox SDK. Use a separate explorer map adapter;
  do not import the Live Map feature or request location permission.
- Query Geoapify Places and Routing through the `trip-explorer` Edge Function.
  Search at most 40 places and apply exact zone containment. Compare balanced
  and short provider paths with identical waypoints and remove duplicates.
- Generate at most six stop sequences across three modes, with at most eight
  stops per candidate. Cache successful provider responses for five minutes in
  the open screen, capped at 60 entries. Label missing or partial coverage.
- Store the ERD's children in immutable JSON version snapshots. Use typed plan
  columns, existing trip members, server-stamped manual edits and redacted audit
  events. Save retries use stable IDs; edits append a version. Sharing changes
  visibility without changing the snapshot.
- Support INR, USD, EUR, GBP, JPY and KWD with their minor-unit precision. The
  plan uses one currency; start a new plan to change it after adding costs.
- Support walking, own-bicycle and driving routes. Driving fares, admissions,
  tolls and ferries remain unknown unless entered. No transit timetable or live
  fare service is configured. No optional Trip Pot export is implemented.
- Demo mode uses synthetic places/routes and local version persistence.
  Connected mode requires migration 0004 and a configured provider function.
  Production coverage, hosted authorization and physical-device maps require
  deployment testing before release.
