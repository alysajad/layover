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
   `supabase/migrations/0001_init.sql`, then `0002_companion.sql`, then `0003_live_map.sql` in that order.
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

Database checks run all three migrations against isolated PostgreSQL (PGlite), with
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
