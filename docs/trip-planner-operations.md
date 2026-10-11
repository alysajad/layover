# Funded trip planner

The organizer sets room occupancy, departure city, preferred local transport,
food preferences and allowances from **Overview / Plan / Money → Plan from the
shared pot**. Once enough external transfers are acknowledged and everyone has
accepted current pot terms, a durable job generates up to three stay-based
options. No payment gateway or automatic reservation is involved.

The organizer reviews the daily plan and shares it once. The server atomically
creates itinerary entries, hotel/journey/ticket booking checks, packing/tasks,
an announcement and member notifications. Announcements appear in **Group** and
**Overview**. Day cards also have an external share button. Booking records say
**To book** until a confirmation reference is entered with the existing edit
form. Actual payments still use **Money → Expenses**; estimates and contributions
never automatically become expenses or mark the pot booked.

## Setup required for a connected project

1. Apply `supabase/migrations/202610110002_trip_planner.sql` after the existing
   companion migrations (0001, 0002, 0003 and 0005). This planner does not depend
   on the separate Explorer migration or function. It can be applied after the
   memories migration. Do not reapply migrations already present.
2. Create a [SerpApi account](https://serpapi.com/manage-api-key), with access to
   [Google Hotels](https://serpapi.com/google-hotels-api) and
   [Google Maps local results](https://serpapi.com/maps-local-results).
   A normal overnight generation uses four searches: hotels, sights, restaurants
   and cafes. A day trip uses three. Provider failures are visible; there is no
   fallback to invented hotel prices or ratings. Retry/search refresh is limited
   to once per minute per trip, and concurrent worker calls lease the same job.
3. Set server-only secrets in Supabase **Edge Functions → Secrets**:
   - `SERPAPI_API_KEY`: the provider key.
   - `PLANNER_SECRET`: a long randomly generated scheduler secret.
   - `OPEN_METEO_API_KEY`: for the commercial customer endpoint when required by
     your use. Without it, the noncommercial Open-Meteo endpoint is used. See
     [Open-Meteo terms](https://open-meteo.com/en/terms) and
     [forecast documentation](https://open-meteo.com/en/docs).
   Never put these in Flutter `env.json`, source control, or chat.
4. Deploy from an authenticated Supabase CLI at the repository root:

   ```sh
   npx supabase functions deploy trip-planner --project-ref sjyxntbluazapuvsdbya
   ```

5. Schedule an HTTP **POST** to
   `https://sjyxntbluazapuvsdbya.supabase.co/functions/v1/trip-planner`
   every minute with `Content-Type: application/json`,
   `x-planner-secret: <PLANNER_SECRET>`, body `{}`, and timeout **5000 ms**. The
   Dashboard HTTP form caps this at five seconds. Use Supabase Cron's HTTP
   request scheduler or your existing external scheduler. Store the secret in
   Vault/the scheduler secret store. Do not put a real secret into a committed
   SQL file. A scheduler invocation processes one trip; increase cadence or
   concurrent invocations if the queue grows. Leases prevent duplicate work.
6. The existing `trip-reminders` worker sends queued push notifications if
   Firebase is configured. The in-app notification list works without push.

Saving preferences/checking generation also invokes the worker as the signed-in
organizer. **The schedule is required for generation with the app closed.**
Scheduled requests return HTTP 200 with `status: accepted` immediately;
`EdgeRuntime.waitUntil` keeps the leased job running in the background. The HTTP
response confirms scheduler authentication, not successful plan generation.
Check the app job state and function logs for completion or failure.
Nothing in the mobile build alone configures hosted secrets, migrations or cron.
The handler validates JWT + organizer access for user requests, or the server
scheduler secret. Provider secrets are never returned to clients or logged.

## Budget and data semantics

- This version uses the app's existing INR pots, 1–14 trip days, up to 50 current
  travelers and 20 rooms (1–4 adults per room). The room allocation must cover
  every current traveler. Children/special occupancy need seller confirmation.
- The price is a Google Hotels **total stay rate** for the selected dates and
  adults per room, multiplied by room count. Response currency, dates and
  occupancy must match. Rentals, nightly-only values and unpriced listings are
  excluded. Multiple-room availability, taxes and the final seller price are
  **not guaranteed**. The UI labels this a listed estimate and retains a checked
  timestamp and source. Hotel links open the listing/provider or Google Hotels
  search; they are not checkout confirmations.
- Food/activity allowances multiply by people × inclusive trip days. Local
  transport multiplies by days for the group; return travel is a group allowance.
  Ten percent of the pot stays in reserve. Only options whose listed stay cost +
  allowances + reserve fit the pot are offered. This is an allocated budget,
  not a fully quoted package. No affordable option is an explicit empty result.
- Places use provider rating + review count and proximity (within 15 km of the
  stay). Sights are not repeated; food options can repeat if results are sparse.
  Menus/dishes are only described when the provider supplies them. Food
  preferences guide search and must be checked with the venue. Missing places
  become flexible time instead of fabricated recommendations.
- Suggested times are local wall-clock slots, not verified opening-hour or
  route schedules. Google Maps directions support public transport, walking or
  car/cab. The app does not claim live fares or validated travel durations.
- Open-Meteo forecasts cover at most 16 upcoming days. Only returned dates that
  overlap the trip affect packing; missing/far-future dates never reuse today's
  weather. Refresh options nearer departure for updated weather. Footwear,
  documents, charging and water are itinerary-based; rain/heat/cold add items.

## Consistency and recovery

- Drafts are organizer-only RPC reads. Published entries use existing trip
  membership access rules. Removed users cannot read the trip.
- The worker checks funding, pot term revision, budget, dates, destination and
  member IDs. Changed context gets a new run, and late provider results cannot
  overwrite it. Archive and funding loss block publication. Quotes older than
  24 hours require fresh options before publication.
- A three-minute lease bounds crashed workers; three lease attempts then require
  an explicit retry. Provider errors fail visibly instead of endlessly charging
  searches. A request for fresh options resets the job after a one-minute limit.
- Publishing the same run/option is idempotent. Switching a published option
  requires a fresh run. Dedicated server-controlled entry keys avoid duplicate
  slots. Generated entry versions advance so stale edit forms cannot overwrite
  a newly published suggestion. Edited/completed/confirmed/deleted entries are
  preserved; obsolete untouched suggestions are removed. A previous shared plan
  stays in normal trip tabs while new options are generated privately.

## Local checks

Install `@electric-sql/pglite` and `typescript` into a temporary test directory,
then set `NODE_PATH` to its `node_modules`:

```sh
node supabase/tests/trip_planner.cjs
node supabase/tests/trip_planner_worker.cjs
cd app
flutter analyze --no-pub
flutter test --no-pub test/trip_planner_test.dart
```

Tests use isolated PostgreSQL and provider fixtures; they do not charge an API
or book anything. The worker test holds the database claim and generation open
to verify that Cron receives its response immediately while background work
finishes and persists the result. Validate deployment afterward with a funded test trip, a
second member account, and the app closed: the scheduler should create a ready
plan and notify the leader. Share once and verify all tabs, then repeat and
confirm no duplicates. Verify a real seller quote before making a reservation.
