# Live Group Map --- ERD and Data Contracts

This schema is a logical proposal. Reconcile it with the existing app's
user, trip, membership, and database models before creating migrations.
Reuse existing entities rather than duplicating them.

## 1. ERD

``` mermaid
erDiagram
    USERS ||--o{ TRIP_MEMBERS : belongs_to
    TRIPS ||--o{ TRIP_MEMBERS : contains
    TRIPS ||--o{ LIVE_SESSIONS : may_link_to
    USERS ||--o{ LIVE_SESSIONS : creates
    LIVE_SESSIONS ||--o{ LIVE_SESSION_MEMBERS : contains
    USERS ||--o{ LIVE_SESSION_MEMBERS : participates
    LIVE_SESSION_MEMBERS ||--o{ LOCATION_SHARING_CONSENTS : has
    LIVE_SESSIONS ||--o{ LIVE_LOCATIONS : holds_latest
    USERS ||--o{ LIVE_LOCATIONS : owns_latest
    LIVE_SESSIONS ||--o| REGROUP_DESTINATIONS : has_current
    LIVE_SESSIONS ||--o{ LIVE_SESSION_EVENTS : records

    USERS {
      uuid id PK
      string display_name
    }
    TRIPS {
      uuid id PK
      uuid organizer_user_id FK
      string title
    }
    TRIP_MEMBERS {
      uuid id PK
      uuid trip_id FK
      uuid user_id FK
      string role
      string membership_status
    }
    LIVE_SESSIONS {
      uuid id PK
      uuid linked_trip_id FK
      uuid created_by FK
      string name
      string status
      datetime created_at
      datetime expires_at
      datetime ended_at
    }
    LIVE_SESSION_MEMBERS {
      uuid id PK
      uuid session_id FK
      uuid user_id FK
      string role
      string membership_status
      datetime joined_at
      datetime removed_at
    }
    LOCATION_SHARING_CONSENTS {
      uuid id PK
      uuid session_id FK
      uuid user_id FK
      string consent_version
      datetime granted_at
      datetime revoked_at
      string sharing_status
    }
    LIVE_LOCATIONS {
      uuid session_id PK,FK
      uuid user_id PK,FK
      decimal latitude
      decimal longitude
      decimal accuracy_m
      decimal heading
      decimal speed_mps
      datetime client_timestamp
      datetime received_at
      bigint sequence_number
    }
    REGROUP_DESTINATIONS {
      uuid id PK
      uuid session_id FK
      uuid set_by_user_id FK
      string name
      decimal latitude
      decimal longitude
      string provider_place_id
      datetime updated_at
    }
    LIVE_SESSION_EVENTS {
      uuid id PK
      uuid session_id FK
      uuid actor_user_id FK
      string event_type
      json metadata_redacted
      datetime created_at
    }
```

## 2. Entities and constraints

### LiveSession

-   Private session with optional link to an existing trip.
-   States: `created`, `active`, `ended`, `expired`, `cancelled`.
-   `expires_at` is required; apply a configurable maximum duration.
-   Ending/expiring invalidates location updates and realtime
    subscriptions.

### LiveSessionMember

-   Unique `(session_id, user_id)`.
-   Roles: `organizer`, `member`.
-   Membership: `invited`, `joined`, `left`, `removed`.
-   Membership does not imply consent to share location.

### LocationSharingConsent

-   Record consent per user/session and the consent version.
-   Only the user can grant/revoke their own consent.
-   Organizer cannot activate another member's location on their behalf.

### LiveLocation

-   One latest row per `(session_id, user_id)`; overwrite rather than
    append.
-   Validate latitude \[-90, 90\], longitude \[-180, 180\], non-negative
    accuracy, timestamp/sequence, and update rate.
-   `received_at` is server-generated.
-   No historical coordinate trail in MVP. Verify database backups and
    realtime change logs do not retain location history unexpectedly.

### RegroupDestination

-   At most one current destination per session in MVP; enforce
    uniqueness/upsert on `session_id`.
-   Decide whether only the organizer or any member can change it; keep
    UI and server policy consistent.
-   Store provider place ID only when returned by a supported provider.

### LiveSessionEvent

-   Record lifecycle events such as session created, member joined,
    consent granted/revoked, destination changed, member removed and
    session ended.
-   Never put raw coordinates, invite tokens, or sensitive payloads in
    event metadata.

## 3. Realtime location payload

Illustrative only:

``` json
{
  "session_id": "server-issued-id",
  "latitude": 13.7563,
  "longitude": 100.5018,
  "accuracy_m": 12.0,
  "heading": 165.0,
  "speed_mps": 1.2,
  "client_timestamp": "2026-10-11T00:00:00Z",
  "sequence_number": 184
}
```

The server must derive the user ID from the authenticated identity, not
trust a client-supplied ID. Validate membership, active session,
explicit consent, coordinate ranges, rate limits, sequence/timestamp and
payload size. Set `received_at` server-side. Broadcast only to current
authorized members of the same active session.

## 4. API sketch

Adapt these to existing API conventions; they are not a mandate to
create a parallel REST API.

-   `POST /v1/live-sessions` --- create session.
-   `GET /v1/live-sessions/{id}` --- authorized session details.
-   `POST /v1/live-sessions/{id}/invites` --- invite eligible trip
    members.
-   `POST /v1/live-sessions/{id}/join` --- join session.
-   `POST /v1/live-sessions/{id}/consent` --- grant explicit consent.
-   `DELETE /v1/live-sessions/{id}/consent` --- revoke consent / stop
    sharing.
-   `POST /v1/live-sessions/{id}/locations` --- publish a location, or
    use the existing realtime provider's authenticated write channel.
-   `GET /v1/live-sessions/{id}/members` --- authorized member states
    and current consented locations.
-   `PUT /v1/live-sessions/{id}/destination` --- set regroup
    destination.
-   `POST /v1/live-sessions/{id}/leave` --- leave session.
-   `POST /v1/live-sessions/{id}/end` --- organizer ends session.
-   `GET /v1/live-sessions/{id}/events` --- permitted lifecycle events.

## 5. Authorization matrix

  -----------------------------------------------------------------------
  Action            Organizer         Joined member     Non-member
  ----------------- ----------------- ----------------- -----------------
  View session      Yes               Yes               No

  View a consenting Yes, if a session Yes, if a session No
  member's latest   member            member            
  location                                              

  Publish own       Only after own    Only after own    No
  location          consent           consent           

  Grant/revoke own  Yes               Yes               No
  consent                                               

  Invite members    Yes, subject to   No by default     No
                    policy                              

  Change            Policy-defined    Policy-defined    No
  destination                                           

  Remove member/end Yes, subject to   No                No
  session           policy                              
  -----------------------------------------------------------------------

Organizer privileges never grant the right to secretly enable another
person's location sharing.

## 6. Retention

-   Delete/invalidate exact live positions at session end/expiry or
    retain only for the minimum cleanup period.
-   No replay/history feature in MVP.
-   Keep only minimal non-location audit events for support/safety
    according to policy.
-   Document and test deletion behavior, including provider logs/backups
    where configurable.
