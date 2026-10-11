# Live Map operations

## Deploy

Apply `0001_init.sql`, `0002_companion.sql`, then `0003_live_map.sql` to a development
Supabase project. Apply `0007_live_trails.sql` after the intervening migrations
before shipping the updated live map. Keep the existing email OTP and trip membership configuration.
Live Map uses the same client and auth session. No public invitation token grants
map access: `?live_session=<uuid>` identifies a session and the server checks the
signed-in account's invitation or joined membership. Web sharing includes that
URL. Android sharing includes a session reference and directs the invited account
to its Live Map list; this app has no native app-link domain configured.

Build with `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and `MAPBOX_PUBLIC_TOKEN`
from `app/env.example.json`. Use a Mapbox `pk.` token with only the public scopes
needed for styles and tiles. Configure URL restrictions for the web deployment;
verify a separate Android token if browser restrictions prevent native requests.
Keep download secrets and Supabase service-role keys out of Flutter and source
control. Serve browser geolocation over HTTPS (localhost is suitable for testing).
The web package loads Mapbox GL JS; allow the provider's required script, style,
worker, and tile origins if you deploy a Content Security Policy.

The Android root Gradle file applies the Kotlin plugin only to Mapbox when
`android.builtInKotlin=false`. Mapbox 3.0.0 checks the AGP version but misses this
compatibility flag. Remove the workaround once Mapbox supports that combination
or the app and all plugins migrate to built-in Kotlin. See Flutter's
[migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers).

The adapter uses Mapbox Flutter 3.0.0, GeoJSON sources/layers on Android and web,
and Streets in 2D. Optional 3D uses buildings and DEM terrain, with map recreation
in 2D after a failure. Missing tokens and load timeouts show a fallback while the
session controls and member list remain usable. Keep the default logo,
attribution, and native attribution-menu telemetry opt-out visible; verify the
control on physical Android before release. Do not add the Mapbox location puck:
geolocator owns foreground acquisition and consent in this app.

Mapbox charges for usage. Its [Flutter pricing guide](https://docs.mapbox.com/flutter/maps/guides/pricing/)
describes mobile monthly active users. Confirm the web implementation's billing
and account rates in [Mapbox pricing](https://www.mapbox.com/pricing/) before
rollout; opening maps during tests can count toward usage. See the official
[package requirements](https://pub.dev/packages/mapbox_maps_flutter) and
[token guide](https://docs.mapbox.com/help/dive-deeper/access-tokens/).

## Schedule deletion

Enable Supabase Cron (`pg_cron`) before applying migration 0003. The migration
registers a minute-by-minute cleanup job if the extension exists. If you enable
Cron afterward, run this as the database owner:

```sql
select cron.schedule(
  'live-map-cleanup', '* * * * *', 'select public.live_map_cleanup()'
);
select jobname, schedule, active from cron.job where jobname = 'live-map-cleanup';
```

Alternatively call the restricted `live_map_cleanup()` RPC from a trusted
scheduler with server-only service credentials every minute. Check scheduler
failures and cleanup duration. Cleanup locks sessions in ID order; for a larger
pilot, measure lock contention before changing the locking scheme.

The server rejects expired sessions and leases even if the scheduler stops.
A snapshot omits positions 30 seconds after their last accepted fix. It labels
positions stale after 15 seconds. Cleanup deletes expired positions and removes
destinations at session expiry. Stop, pause, leave, removal, and end delete
positions in the command transaction. Session end removes the destination too.
Cleanup removes lifecycle events and command fingerprints after 30 days and
purges sessions 30 days after expiry. Trails cascade from `live_locations`, so
the same deletion paths remove all recent points. The new table is RPC-only
with RLS and no direct client grants. Each consenting publisher has at most 180
points from the last 15 minutes; publishing prunes older points and snapshots
exclude them immediately. Stale or inaccessible publishers expose no trail.

## Access and publication contract

- `live_map_sessions()` returns the caller's open sessions, minimal account
  invitations, and contacts who share a current, unarchived trip.
- `live_map_snapshot(p_session_id)` checks joined membership on each call.
  Invited accounts cannot read locations or the member sheet.
- `live_map_command(p_action,p_data,p_request_id)` handles `create`, `start`,
  `cancel`, `invite`, `revoke`, `join`, `consent`, `pause`, `stop`, `destination`,
  `leave`, `remove`, and `end`. Invite/remove targets use `target_id`.
- `live_map_publish_location` derives the publisher from `auth.uid()`. Parameters
  are session ID, consent generation, increasing sequence, latitude, longitude,
  accuracy, client timestamp, and optional heading/speed. It accepts fixes at
  most once per five seconds, including across consent changes.
- `live_map_cleanup()` permits only service-role/database-owner execution.

Each command and publication locks its session. A new consent generation
invalidates earlier requests. Joining grants no consent; use `live-map-v2` in
an explicit consent command after disclosing the recent path. Older `live-map-v1`
clients can share their latest point, but never opt into a trail. A 30-second lease starts with consent and renews
only on accepted fixes. An expired lease requires a new explicit consent.
Session duration defaults to two hours, accepts one through eight hours, and
cannot extend. Only the organizer starts, invites, removes, cancels, and ends.
Any joined member can change the regroup point. The organizer ends the session
instead of leaving it without an owner.

Trip-linked sessions require current joined trip membership and an unarchived
trip. Triggers remove linked access and positions when a trip member leaves or
is removed; archiving ends linked sessions. Standalone invitations require a
shared current trip at invitation and acceptance. After joining, standalone
session membership governs access. A removed member needs a new invitation.

Publication rejects non-finite/out-of-range coordinates, accuracy outside
0–5000 metres, heading outside 0–360 degrees (360 excluded), speed outside
0–100 m/s, stale/future timestamps, non-increasing sequence, excessive rate,
and implausible jumps. Fixes may be at most 30 seconds old or 10 seconds ahead;
server receive time determines visibility. Jump tolerance allows 100 m/s plus
the two fixes' reported accuracy. Accuracy worse than 100 metres remains visible
with an approximate-location label. Trails break at accuracy worse than 100 m,
gaps over 20 seconds, or implausible jumps. Compact colored dots interpolate
between fresh snapshots; a pin marks the meeting point. Marker symbol layers
sit above the 3D buildings. Trails represent received GPS fixes, not navigation
or a road-snapped route. Distances are straight lines, without ETA.

## Retention release requirement

**Actual hosted backup, WAL/PITR, API-log, database-log, log-drain, and Mapbox
telemetry retention: not verified in this workspace. Release remains gated on
the deployment owner's record of those settings.**

Row deletion does not erase copies in managed backups. Supabase's
[backup documentation](https://supabase.com/docs/guides/platform/backups)
describes daily backups and PITR; the project's plan, add-ons, and exported
backups determine its retention. Before release, record the project identifier,
backup type/window, PITR window, log-retention windows, export destinations,
access controls, owner, and verification date. Check request-body/SQL parameter
logging and error detail retention. Do not enable body or coordinate logging for
these RPCs, add Live Map tables to Realtime publication, or put fixes in analytics,
crash breadcrumbs, preferences, companion receipts, or retry queues.

The app keeps positions in memory. Live command receipts store a SHA-256
fingerprint plus a non-sensitive result; lifecycle events store only actor,
session, action, and time. None of the new code logs coordinates. Provider SDK
telemetry and infrastructure backups require their own configuration review.
For a backup restore, run cleanup before allowing clients to connect and review
any unexpired consent rows restored from the backup.

## Run verification

From `app`:

```sh
flutter analyze
flutter test
flutter build web --release
flutter build apk --debug
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/live_map.cjs
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/live_trails.cjs
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/companion.cjs
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/reminders.cjs
NODE_PATH=/tmp/layover-check/node_modules node tool/live_map_two_clients.cjs
```

Install PGlite and Playwright as described in `app/README.md`. The two-client
simulation takes about 50 seconds and uses synthetic positions in isolated
PostgreSQL. It runs independent authenticated clients through serialized SQL
transports (PGlite has one connection), with viewer polling every three seconds.
It verifies automatic location/destination updates, denied invited/outsider reads,
online stop by the next poll, and offline disappearance after the lease. A viewer
can observe a lease expiry up to one polling interval later; the server hides the
coordinates at 30 seconds. This simulation does not test hosted HTTP isolation.

To exercise actual HTTP RPCs, create three development accounts. A and B must
share a current trip; the third account must be outside the test session. Supply
`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `LIVE_MAP_TOKEN_A`, `LIVE_MAP_TOKEN_B`,
and `LIVE_MAP_TOKEN_OUTSIDER` as environment variables, then run:

```sh
node tool/live_map_two_clients.cjs --hosted
```

Use user access tokens from authenticated development sessions, not service-role
keys. The script creates and ends a synthetic session and prints only assertions,
without tokens or coordinates. It has no production defaults.

Start `node tool/preview.cjs` after a release build. Then run
`NODE_PATH=/tmp/layover-check/node_modules node tool/browser_check.cjs` for phone
and desktop navigation, consent, and stop checks. Screenshots go to `/tmp`.

## Physical and hosted checks before rollout

With two real Android/browser clients, verify OTP and account-bound invitations,
GPS denial, permanent denial, disabled services, approximate location, foreground
acquisition, app background/termination, screen exit, account switch, and offline
stop. Verify updates with a stationary device as well as movement: cached fixes
must not renew a lease. Confirm the second client loses location access on
removal, trip archive, end, and expiry. Exercise duplicate/concurrent HTTP updates
and a stop racing an in-flight publication against hosted PostgreSQL.

With a restricted Mapbox token, check both platforms' markers, overlap selection,
regroup taps, last-editor labels, accuracy, attribution, telemetry opt-out, 3D,
2D recovery, WebGL failure, blocked scripts, and provider downtime. Browser/GPS,
real provider rendering, and battery behavior require these runtime checks;
passing local widget tests does not establish them. Deploy to five groups first.

## Local verification record · 11 October 2026

- `flutter analyze`: passed at the Live Map checkpoint. A later full run
  reported two lint infos in concurrently added `features/trip_explorer/domain/explorer.dart`
  (braces and null-aware collection syntax). Those files are outside this change;
  scoped analysis of the seven Live Map/integration/test targets passed. The
  final targeted Flutter rerun passed all 22 Live Map and navigation tests.
- `flutter test --concurrency=1`: all 33 tests passed, including the existing
  financial/trip suite, no-trip entry, permission states, account/lifecycle
  changes, stale positions, and late consent/publication/snapshot races.
- `supabase/tests/live_map.cjs`, `companion.cjs`, and `reminders.cjs`: passed
  against isolated fixtures. The Live Map suite covers invitation expiry and
  renewal, RLS, organizer checks, malformed fixes, rate/sequence validation,
  queued simultaneous publications/withdrawal, leases, trip invalidation,
  standalone eligibility, and retention.
- `app/tool/live_map_two_clients.cjs`: passed with synthetic positions and two
  authenticated local transports, including concurrent publication rejection,
  automatic polling, regroup updates, online stop, and offline lease expiry.
- Android debug APK and web release: passed. Android reports the existing
  Kotlin compatibility-mode deprecation warning, including the scoped Mapbox
  workaround. Plan plugin migration before upgrading beyond this Flutter version.
- Chromium navigation at 390 and 1440 pixels: passed for existing tabs and Live
  Map creation, consent, stop, and return navigation. This run used the
  missing-token fallback and synthetic demo data.

No hosted migration, actual Mapbox rendering/3D/telemetry behavior, real GPS,
physical Android lifecycle, hosted HTTP race, Cron execution, or provider
retention check has been performed from this workspace. Complete the release
checks above with development credentials and devices.

## CUSAT single-phone verification · 11 October 2026

The local campus test is available from Overview or the Live Map session list.
It retains the current account as organizer and creates three synthetic runners
in memory. It does not sign out, request GPS, or publish simulated fixes to
Supabase. See the app README for its pause, speed, offline, reset, and removal
controls. Building heights and the test loop are approximate, not surveyed
campus geometry or walking directions.

- Static analysis and all 60 Flutter tests passed at the campus checkpoint.
  The additional UI tests exercise 360px and 1200px layouts, real-account admin
  identity, synthetic consent, stop, removal, regroup, reset, and GPS isolation.
- `tool/campus_browser_check.cjs` passed at 390px and 1440px with the configured
  public Mapbox token. It verified pitched 3D building layers, rendered building
  features, automatically changing runner coordinates, speed/offline controls,
  synthetic admin consent/stop, and zero backend RPC requests.
- The browser check uses the build's bundled CanvasKit binaries. For unreliable
  CDN connections, `MAPBOX_GL_PATH` may point to a local copy of the official
  Mapbox GL JS version used by the Flutter plugin. Real map tiles still load
  from Mapbox. No map data or renderer is mocked by the check.
- The configured Android debug APK built and installed successfully with
  `adb install -r`, preserving existing app data.

This verifies the single-phone simulation and browser rendering; it does not
replace the hosted multi-account, physical GPS, lifecycle, or retention checks
listed above.
