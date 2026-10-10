# Budget-Aware Trip Explorer --- ERD and Data Model

**Important:** This is a logical ERD. First inspect existing trip, user,
budget and expense schemas. Reuse those entities and adapt names/types
to project conventions. Do not create duplicate `users` or `trips`
tables.

## ERD

``` mermaid
erDiagram
    TRIPS ||--o{ EXPLORATION_PLANS : has
    USERS ||--o{ EXPLORATION_PLANS : creates
    EXPLORATION_PLANS ||--o{ PLAN_MEMBERS : includes
    USERS ||--o{ PLAN_MEMBERS : participates
    EXPLORATION_PLANS ||--o{ EXPLORATION_ZONES : defines
    EXPLORATION_PLANS ||--o{ PLAN_PLACES : selects
    PLACES ||--o{ PLAN_PLACES : selected_in
    EXPLORATION_PLANS ||--o{ ITINERARIES : generates
    ITINERARIES ||--o{ ITINERARY_STOPS : contains
    PLACES ||--o{ ITINERARY_STOPS : visited_at
    ITINERARIES ||--o{ ROUTE_LEGS : connects
    PLACES ||--o{ ROUTE_LEGS : endpoint_reference
    ROUTE_LEGS ||--o{ FARE_ESTIMATES : priced_by
    ITINERARIES ||--o{ ITINERARY_COST_ITEMS : costs
    EXPLORATION_PLANS ||--o{ BUDGET_ALLOCATIONS : proposes
    USERS ||--o{ BUDGET_ALLOCATIONS : assigned_to
    EXPLORATION_PLANS ||--o{ PLAN_EVENTS : audits

    EXPLORATION_PLANS {
      uuid id PK
      uuid trip_id FK
      uuid created_by FK
      string title
      string currency
      bigint total_budget_minor
      int group_size
      datetime start_at
      datetime end_at
      string status
      int version
    }
    EXPLORATION_ZONES {
      uuid id PK
      uuid plan_id FK
      string geometry_type
      json geometry
      datetime created_at
    }
    PLACES {
      uuid id PK
      string provider
      string provider_place_id
      string name
      string category
      decimal latitude
      decimal longitude
      string price_level
      datetime source_checked_at
    }
    PLAN_PLACES {
      uuid id PK
      uuid plan_id FK
      uuid place_id FK
      string selection_type
      int priority
      int dwell_minutes
    }
    ITINERARIES {
      uuid id PK
      uuid plan_id FK
      string archetype
      string status
      bigint estimated_total_low_minor
      bigint estimated_total_high_minor
      int estimated_duration_minutes
      datetime generated_at
    }
    ITINERARY_STOPS {
      uuid id PK
      uuid itinerary_id FK
      uuid place_id FK
      int stop_order
      int dwell_minutes
      bigint known_activity_cost_minor
    }
    ROUTE_LEGS {
      uuid id PK
      uuid itinerary_id FK
      int leg_order
      string origin_reference
      string destination_reference
      string transport_mode
      string provider_route_id
      decimal distance_m
      int duration_seconds
    }
    FARE_ESTIMATES {
      uuid id PK
      uuid route_leg_id FK
      string source_provider
      bigint low_cost_minor
      bigint high_cost_minor
      string currency
      string cost_basis
      string confidence
      string estimate_status
      datetime checked_at
    }
    ITINERARY_COST_ITEMS {
      uuid id PK
      uuid itinerary_id FK
      string category
      string description
      bigint low_cost_minor
      bigint high_cost_minor
      string currency
      string cost_basis
      string source_type
      string source_reference
    }
    BUDGET_ALLOCATIONS {
      uuid id PK
      uuid plan_id FK
      uuid user_id FK
      string category
      bigint amount_minor
      string status
      datetime approved_at
    }
    PLAN_EVENTS {
      uuid id PK
      uuid plan_id FK
      uuid actor_user_id FK
      string event_type
      json metadata_redacted
      datetime created_at
    }
```

## Model notes

### ExplorationPlan

-   Belongs to an existing trip and has an owner/creator.
-   `status`: `draft`, `generating`, `ready`, `shared`, `approved`,
    `archived`.
-   `version` supports plan edits and avoids silently overwriting member
    decisions.
-   Store one base currency per plan for MVP.
-   Budget totals use integer minor units (paise/cents), not floating
    point.

### ExplorationZone

-   Stores polygon or circle geometry in a defined coordinate reference
    (normally WGS84 / GeoJSON).
-   Validate coordinate bounds and maximum polygon size/vertex count.
-   Treat the zone as a place-discovery boundary; route paths may leave
    it to reach a stop or transit hub.
-   A geofence here is a planning boundary, not a live-location alert or
    security boundary.

### Place and PlanPlace

-   Store provider ID, source, retrieval time and only fields the
    provider terms allow caching.
-   `selection_type`: `must_visit`, `optional`, `excluded`.
-   Do not label a place "offbeat" based solely on an unverified model
    guess; derive from source/category/community signals and disclose
    provenance.

### Itinerary and ItineraryStop

-   Keep generated candidates immutable after creation or version them.
    User edits create a new version.
-   Each stop has an order and dwell-time assumption.
-   Keep required stops distinct from optional recommended stops.

### RouteLeg and FareEstimate

-   One route leg connects two adjacent itinerary stops (or the
    start/end).
-   Routing provider alternatives and waypoint itinerary alternatives
    are different concepts.
-   A fare may be missing. Missing price is not zero.
-   `cost_basis`: `per_person`, `per_vehicle`, `per_group`,
    `per_ticket`, `flat`.
-   `estimate_status`: `provider_quote`, `published_tariff`, `manual`,
    `model_estimate`, `unknown`.
-   `confidence` should be a defined enum with documented meaning.
-   Preserve provider checked-at time and terms/attribution
    requirements.

### ItineraryCostItem

-   Supports non-transport costs such as entry fees, activities, food
    allowance, tolls or local fees.
-   Record source and whether the cost is known, estimated or manually
    entered.
-   Avoid double counting route-level transport costs and leg costs.

### BudgetAllocation

-   Represents a proposed or approved allocation, not a payment
    transaction.
-   Do not treat it as paid, held, or committed funds.
-   If integrating with Trip Pot/expense module, use an explicit
    confirmed export flow and stable IDs.

## Calculation rules

-   One base currency per plan in MVP.
-   Use integer minor units.
-   Store low/high estimates if uncertain; sum bounds consistently.
-   Keep group totals separate from per-person totals.
-   Shared vehicle costs and individual ticket costs require different
    cost-basis rules.
-   Unknown costs remain unknown; never silently convert them to zero.
-   Keep contingency as a separate cost item/category.
-   Version the assumptions used to generate a recommendation.
