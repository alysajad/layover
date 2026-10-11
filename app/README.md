# Layover

Flutter group-trip companion, backed by Supabase. Payments happen outside the
app and are acknowledged manually by their recipient.

## Interface

The interface uses an off-white and ink palette, outlined rounded cards, pill
controls, and original travel line art. Lato fonts and the vector illustration
are bundled locally; no image or font requests are needed for the app shell.
The font license is included in `assets/fonts/LICENSE.txt`.

Overview, Plan, Money, Bookings, Group, Live Map, Trip Explorer, and sign-in
share the same theme. Use the three-dot **Trip actions** menu beside the trip
selector to create, edit, or join a trip. Phone navigation stays at the bottom;
wide screens use a navigation rail.

Connected trip data refreshes after every confirmed change, on tab selection,
on app resume, and every five seconds while foregrounded. Requests do not overlap;
failures back off to at most one attempt per minute. Financial writes require a
connection, and an uncertain write must be retried with its original request ID.
See [navigation verification](../docs/navigation-verification.md) for coverage and
remaining hosted checks.

## Run the Demo

```sh
flutter pub get
flutter run
```

Without Supabase configuration, Layover opens a local Goa trip. Profile settings
switch between Asha (organizer), Rahul, and Meera. Demo changes persist on the
device; Reset demo restores the sample. Invitations, attachments, and push need
a connected account. No demo action sends money.

For a browser preview:

```sh
flutter config --enable-web
flutter build web --release
node tool/preview.cjs
```

Open `http://127.0.0.1:5173`. Set `PORT` to use another port. The server binds only
to localhost and serves the current release build; rebuild after code changes.

## Connect Supabase

1. Create a development Supabase project. Apply
   `supabase/migrations/0001_init.sql` through `0006_invite_random_bytes.sql` in numeric order.
   These migrations create a private `trip-files` storage bucket as well.
   Apply `0004_trip_explorer.sql` and follow [Explorer deployment](../docs/trip-explorer-operations.md)
   to enable connected budget exploration.
2. Enable Google authentication using [the Google sign-in setup](../docs/google-sign-in-setup.md).
   The app uses browser OAuth with PKCE; email delivery and SMTP are not required.
3. Populate the existing `env.json` format with `SUPABASE_URL` and
   `SUPABASE_PUBLISHABLE_KEY`. Never put a service-role key in Flutter config.
4. Run `flutter run --dart-define-from-file=env.json`.
5. Create a trip, share an invite code, and join from a second account. Verify
   recipient acknowledgment, revised terms, settlement, and private attachments.

Use a development database first. The second migration extends the first and
does not delete existing financial records. Legacy provider-payment rows stay
separate from manual transfers. These files are migrations, not rerunnable seeds.

If **Add traveler** reports `function gen_random_bytes(integer) does not exist`,
apply `0006_invite_random_bytes.sql` after the previous migrations in the Supabase
SQL editor. It lets the invite function find pgcrypto in Supabase's `extensions`
schema. Tap **Add traveler** again afterward; no app rebuild is needed.

## Push and Scheduled Reminders

In-app changes work without Firebase. Time-based reminders require a scheduler.
Deploy `supabase/functions/trip-reminders` using the Supabase CLI. Set server
secrets `REMINDER_SECRET` and optionally `FIREBASE_SERVICE_ACCOUNT` (the Firebase
service account JSON, including project ID). Supabase supplies the URL and
service-role key in the Edge Function environment. The function requires the
`x-reminder-secret` header even though its `verify_jwt` option is false.

Schedule a POST to that function every five minutes with the private header
`x-reminder-secret: <REMINDER_SECRET>`. Use a hosted scheduler or Supabase Cron
with secrets stored in Vault. Do not expose that header in Flutter. The worker
always enqueues in-app reminders; without Firebase credentials it reports
`push: not_configured`.

For Android push, configure Firebase for the application's Android package and
pass these public build values along with the Supabase configuration:

```json
{
  "FIREBASE_APP_ID": "<android app id>",
  "FIREBASE_API_KEY": "<public Firebase API key>",
  "FIREBASE_SENDER_ID": "<messaging sender id>",
  "FIREBASE_PROJECT_ID": "<project id>"
}
```

Enable push in Profile settings and grant Android notification permission.
Validate foreground and background delivery on a physical device with Google
Play services. Browser and iOS push are outside this Android pilot. Delivery
uses leases and stable Android tags; network failures can cause redelivery.
In-app records remain authoritative.

## Verification

```sh
flutter analyze
flutter test
flutter build web --release
flutter build apk --debug
```

Database checks run the relevant migrations against isolated PostgreSQL (PGlite), with
test auth/storage schemas. They never connect to a hosted database:

```sh
npm install --prefix /tmp/layover-check @electric-sql/pglite playwright typescript@5.9.3
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/companion.cjs
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/reminders.cjs
NODE_PATH=/tmp/layover-check/node_modules node tool/companion_two_clients.cjs
```

With the preview server running, browser checks capture phone and desktop
screenshots in `/tmp`. Set `CHROMIUM_PATH` for an existing Chromium binary:

```sh
NODE_PATH=/tmp/layover-check/node_modules node tool/browser_check.cjs
```

## Pilot Gates

Hosted Google sign-in, Storage policies, scheduled delivery, Firebase configuration,
signed Android distribution, retention/deletion handling, and physical-device
behavior need verification in the actual deployment. The account-deletion
control records a request for review; it does not immediately erase shared
financial history. Assign a support owner to these requests.

Observe five groups first, then expand to twenty. Local tests and demo mode do
not substitute for deployment and user checks.

## Live Map

### Test with one phone at CUSAT

Open **Overview → CUSAT · 3D test run**, or **Live Map → Try CUSAT with test
runners**. The signed-in account remains the test session's admin. Three local
simulated phones move around a campus test loop; no extra accounts or phones
are needed. This is a UI simulation, not a hosted multi-device/GPS test.

- **Test controls** changes speed (1×, 5×, 10×) and sets each runner to running,
  paused, or offline. Offline fixes turn stale after 15 seconds and disappear
  after 30 seconds. Paused runners stay connected.
- Tap a traveler to follow them. Tap the map to choose a regroup point. The
  admin can remove simulated members. **Reset run** restores all three.
- **Show my test marker** puts a synthetic admin marker at the campus meetup;
  it never requests GPS. Leaving/backgrounding the screen stops the test loop.

Mapbox shows the main CUSAT campus in Kalamassery with extruded building
footprints. Heights use provider data with a minimum visual height of 9 metres
and are approximate. The runner loop is a synthetic test fixture, not verified
walking directions. The map needs the existing public Mapbox token and internet;
if it fails, member controls remain available. Simulated locations stay in memory
and never reach Supabase or the real trip's stored data.

Campus reference: [CUSAT main campus](https://www.cusat.ac.in/main-campus.php).
Map rendering: [Mapbox building extrusions](https://docs.mapbox.com/help/dive-deeper/z_add-3d-buildings-studio/).

```sh
flutter test test/campus_simulation_test.dart test/campus_run_ui_test.dart
flutter build web --release --dart-define-from-file=env.json
# With tool/preview.cjs running and Playwright installed:
NODE_PATH=/tmp/layover-check/node_modules node tool/campus_browser_check.cjs
```

Overview and the no-trip home include **Live Map · Find your group**. Create a
private session, invite existing trip contacts, and start it. Each person joins
and opts into foreground sharing for that session. The demo uses synthetic
positions in memory; it never requests GPS or saves Live Map data.

Add `MAPBOX_PUBLIC_TOKEN` to your build config for Android/web maps. Without a
token, session controls and the member list still work. Enable Supabase Cron
and verify the minute cleanup job, hosted retention, and physical-device behavior
before release. See [Live Map operations](../docs/live-map-operations.md) for RPCs,
token restrictions, billing, cleanup, privacy, and the two-client simulation.

The feature uses `mapbox_maps_flutter` 3.0.0 and `geolocator` 14.1.1. The unused
`connectivity_plus` dependency was removed because its Linux DBus requirement
conflicted with geolocator; no existing app code imported it.

## Payment capture and personal expenses

Apply `supabase/migrations/0005_payment_expenses.sql` after the existing migrations
before shipping this app version. It preserves historical expense dates, adds
private personal expenses, and keeps shared expenses on the existing accounting
RPC. Personal expenses are visible only to their author, do not create group
activity or notifications, and never enter group balances or the shared CSV.

In **Money → Expenses**, choose **Set up capture** in the Android app. Set trip
start/end dates, choose payment/SMS apps, and grant Android notification access.
Capture runs for one selected trip at a time, only for new notifications within
its date window. The listener can queue notifications while Flutter is closed;
opening the app processes that queue into the payment inbox. Stop capture in the
same panel. Signing out or switching accounts disables capture and clears the
native queue. Re-enable after changing the trip's capture dates.

Supported sources are Google Pay, PhonePe, Paytm, BHIM, Google Messages, and
Samsung Messages. Bank SMS alerts must appear as notifications from a selected
SMS app. No SMS database permission is requested. The app does not process old
notifications or notification content hidden by Android/the source app. See
[Android NotificationListenerService](https://developer.android.com/reference/android/service/notification/NotificationListenerService)
for OS and work-profile restrictions. Physical-device testing of notification
access, background capture, and each payment app remains a release check.

The parser supports completed outgoing INR payments with deterministic,
editable category suggestions. OTPs, incoming payments, refunds, failures,
pending payments, and payment requests are ignored. Unknown merchants use Other.
Notification text stays in the app-private native queue (up to 200 candidates)
and is removed after parsed details are saved locally. Transaction references
are used to deduplicate alerts across sources; without a reference, native
notification identity is used. Duplicate pasted text is detected within the same
day. Android backup is disabled to keep the queue off backup services.

On any platform, **Paste payment message** offers the same review workflow.
Review the suggested title, amount, category, and expense date; choose **Split
with trip** or **Personal · only me**. Review is required before balances change.
Only the reviewed fields are sent to Supabase. Offline reviews remain account-
bound drafts until submitted online. Captured payments use stable request IDs,
so retries cannot charge the group twice. Notification text is not proof that a
payment settled.

Date fields use native Material calendars and time pickers, including trip
setup, bookings, reminders, itinerary entries, pot deadlines, expense dates,
date poll options, and explorer start/end times. Times display locally and are
stored in UTC where the existing API expects timestamps.

## People I met

Apply `supabase/migrations/202610110001_trip_memories.sql` before enabling cloud
backup and sharing. This migration adds a separate **private** `trip-memories`
bucket, owner-only metadata commands, and membership-aware read policies. It does
not change the existing group attachment bucket.

Open **Overview → People I met → Take a photo** in Android. The embedded camera
supports front/back switching and retakes. Add an optional name, note, and a more
specific place; the trip destination and capture time are attached automatically.
No GPS is requested for memories. Photos are resized to a maximum 1600-pixel edge,
normalized for orientation, and encoded as JPEG without EXIF/location metadata.
No microphone or gallery access is needed.

**Save privately** writes the photo to app-private storage before starting backup.
The account-bound queue survives restarts and retries while the app is open or
when it resumes. The app does not promise background uploads after it is closed.
Status distinguishes a local save from a completed backup. Do not uninstall or
clear app data before pending photos have backed up. Web can view and manage
backed-up memories; capture and durable offline saving are Android-only. Demo
photos stay in the current session and never upload.

Only the owner can edit, delete, share, or make a memory private. Sharing includes
its photo, name, place, time, and note, and requires an online confirmation. Even
organizers cannot read unshared memories. Photos are downloaded with the current
session rather than reusable signed/public URLs. Other members' photos are not
stored in the offline library. Revocation removes app access, but cannot retract
screenshots or copies already made. Leaving/removal clears sharing on the server;
rejoining never automatically restores it. **Trip actions → My memories** keeps
owners' photos accessible after departure or archival. Existing memories remain
editable by their owner; new captures and shares require an active trip.

Offline deletions are queued, hidden locally, and finish when connected. The
server first revokes visibility, then the app removes storage bytes; interrupted
cleanup retries. Tombstones prevent old clients from reviving deleted memories.
Private saves and sharing do not generate group activity or notifications.

Validation: `flutter test test/memories_test.dart` covers metadata removal, offline
restart, account isolation, interrupted responses, duplicate-safe uploads,
nonblocking local saves, and mobile/desktop layouts. Run
`NODE_PATH=<test-dependencies>/node_modules node supabase/tests/memories.cjs`
with `@electric-sql/pglite` to test private metadata/storage, organizer isolation,
owner-only changes, share/unshare, removal/rejoin, archives, and deletion. Camera
permission, capture/retake, and background/resume also require an Android device.


## Funded trip planning

Organizers can open **Plan from the shared pot** from Overview, Plan or Money.
Confirmed contributions trigger private itinerary options; the leader can publish
one option to the trip's itinerary, booking checks, tasks, packing and Group
announcement. Reservations remain manual, through the provided links. Apply the
planner migration, configure provider secrets and schedule the worker using
[Planner operations](../docs/trip-planner-operations.md).

## Drawn areas and recent live paths

The explorer now supports place-name search, a one-time location fix, circle and
freehand drawing, and map-selected start/finish points. Discovery includes food,
local highlights, bus stops and services, with online source links and available
cuisine/hours/operator details. Budget suggestions reserve allowances and keep
unpublished prices marked unknown. See [Explorer operations](../docs/trip-explorer-operations.md).

Redeploy `supabase/functions/trip-explorer` with the existing `GEOAPIFY_API_KEY`.
Apply `supabase/migrations/0007_live_trails.sql` before shipping this client:
Live Map uses explicit `live-map-v2` consent for a recent path (up to 15 minutes /
180 fixes), small moving dots and a meeting-point pin. Stop/pause/end and location
expiry remove the associated trail. See [Live Map operations](../docs/live-map-operations.md).
