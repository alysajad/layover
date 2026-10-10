# Navigation and synchronization verification

Audit date: 11 October 2026. Scope: Overview, Plan, Money, Bookings and Group,
including their shared store and the Live Map/Explorer entry points. This report
separates local implementation checks from hosted rollout evidence.

## Tab coverage

| Tab | Working repository flows | Verification |
| --- | --- | --- |
| Overview | Trip selection/create/edit/join, announcements, summaries, Live Map and Explorer entry points | Responsive navigation tests; database trip/invite tests; demo browser checks |
| Plan | Polls/voting, shortlists and organizer choice, itinerary, comments | Widget poll flow; checked database commands; automatic two-client updates |
| Money | Pot terms and individual shares, acceptance, expenses and splits, external-payment reports, acknowledgment/dispute/correction, balances and CSV | Accounting, store and SQL tests; widget expense flow; two-client settlement |
| Bookings | Create/edit/remove booking records, reference/details, comments, private attachment upload | Widget CRUD/comment flow; SQL ownership/version/access checks; attachment input validation |
| Group | Tasks, meetings and arrival check-in, contacts, announcements, members/invites, archive/restore | Widget actions and role controls; SQL permission tests; two-client removal |

Payments remain records of money sent outside Layover. The app does not charge a
card or transfer funds. Private storage access is checked by Supabase; a live
upload/download on the hosted project still needs an authenticated device check.

## Fixes

- Poll every five seconds while foregrounded, refresh on tab changes/resume and
  after a committed mutation. Coalesce reads and prevent an older in-flight read
  from replacing a newly committed update. Back off failures to sixty seconds.
- Clear account state immediately and discard old-account asynchronous responses.
  Keep uncertain mutations tied to their original account/request ID. Explicit
  retries reuse that ID, preventing duplicate expense/payment records.
- Keep offline summaries free of financial records. Authorization denial clears
  cached summaries; backgrounding stops the recurring poll.
- Bind open forms to their original trip, account and version. Preserve unequal
  pot allocations during revision, reject removed-trip/member submissions, and
  handle a payment's removed recipient without a dropdown assertion.
- Check the original account/trip again after reading an attachment and before
  uploading. Dismiss open routes when the connected account changes.
- Preserve tab scroll positions per account/trip, show last sync time, and keep
  controls usable at 320 px with enlarged text.

## Executed checks

- Flutter analyzer: passed, no issues.
- Flutter tests: **56 passed**, including all five tabs at phone/desktop widths,
  compact enlarged-text layout, form races, foreground polling, account changes,
  retry receipts, accounting, Google OAuth, Live Map and Trip Explorer.
- Isolated PostgreSQL/PGlite suites: companion, reminders, Live Map, Explorer and
  Explorer provider contract tests passed. These use fixtures, not hosted data.
- `app/tool/companion_two_clients.cjs`: passed with two authenticated simulated
  clients polling every five seconds. It proves automatic visibility of all eight
  entry types, responses/comments, expenses, payment acknowledgments, archive,
  restore and member removal; outsider and stale-version writes are rejected.
  Retrying a payment with the same ID creates one record. This exercises the real
  migrations with local auth-role contexts, not Google or hosted HTTP transport.

Reproduce the multi-client check from the repository root:

```sh
NODE_PATH=/tmp/layover-check/node_modules node app/tool/companion_two_clients.cjs
```

- Android debug APK and web release built successfully using the local public
  configuration. Existing Firebase/Mapbox plugins emit a Kotlin migration warning;
  it does not block the current build.
- Chromium navigation and Live Map consent/start/stop checks passed at **390 px
  and 1440 px**, with no page errors. These use the explicitly labeled demo.
- Explorer browser discovery, selection, comparison, save and share passed at
  both widths using demo fixtures.
- The APK was installed over the existing app on the connected Android phone
  (`adb install -r` returned `Success`). Launch reached the connected no-trip home;
  an updating last-sync timestamp confirms successful foreground refresh. The
  Google account chooser/consent exchange itself was not exercised in this run.

## Hosted checks and remaining deployment work

Public, read-only checks against the configured Supabase project established:

- `/auth/v1/settings` returns Google enabled.
- `companion_snapshot` and `live_map_sessions` reject an anonymous caller with
  permission denied. Their presence is verified; authenticated hosted behavior
  has not been validated by this check.
- `trip-explorer` and `trip-reminders` Edge Function URLs return **404 NOT_FOUND**.
  Their local source/tests pass, but these services are not deployed there.

Complete these before calling the app production-ready:

1. Verify a fresh Google login on the phone and web, then exercise two independent
   accounts through invite/join, shared edits, acknowledgment, removal and private
   attachments. The provided public client key cannot deploy backend resources.
2. Apply migration 0004 if not already applied, deploy the Explorer function and
   set its server-side Geoapify key. See [Explorer operations](trip-explorer-operations.md).
3. Deploy the reminder worker and scheduler; configure Firebase only if Android
   push is wanted. In-app trip changes do not require Firebase. See the
   [app README](../app/README.md#push-and-scheduled-reminders).
4. Verify Live Map cleanup scheduling, managed backup/log retention, GPS and
   actual Android permission/background behavior. See
   [Live Map operations](live-map-operations.md).

No server/admin credentials were available for those deployments. This update
does not silently substitute demo data for an unavailable connected service.
