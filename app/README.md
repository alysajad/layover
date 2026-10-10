# Layover

Flutter group-trip companion, backed by Supabase. Payments happen outside the
app and are acknowledged manually by their recipient.

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
   `supabase/migrations/0001_init.sql`, then `0002_companion.sql` in that order.
   These migrations create a private `trip-files` storage bucket as well.
2. Enable email authentication. Configure the sign-in email template to include
   `{{ .Token }}` so users can enter the OTP in the app; verify SMTP delivery.
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

Database checks run both migrations against isolated PostgreSQL (PGlite), with
test auth/storage schemas. They never connect to a hosted database:

```sh
npm install --prefix /tmp/layover-check @electric-sql/pglite playwright typescript@5.9.3
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/companion.cjs
NODE_PATH=/tmp/layover-check/node_modules node ../supabase/tests/reminders.cjs
```

With the preview server running, browser checks capture phone and desktop
screenshots in `/tmp`. Set `CHROMIUM_PATH` for an existing Chromium binary:

```sh
NODE_PATH=/tmp/layover-check/node_modules node tool/browser_check.cjs
```

## Pilot Gates

Hosted OTP, Storage policies, scheduled delivery, Firebase configuration,
signed Android distribution, retention/deletion handling, and physical-device
behavior need verification in the actual deployment. The account-deletion
control records a request for review; it does not immediately erase shared
financial history. Assign a support owner to these requests.

Observe five groups first, then expand to twenty. Local tests and demo mode do
not substitute for deployment and user checks.
