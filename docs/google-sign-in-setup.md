# Google sign-in setup

The app now uses **Continue with Google** on Android and web. Supabase verifies
the Google identity and creates the existing account/profile. Trip membership,
Live Map consent, and access checks still apply. No Gmail App Password, SMTP
service, or Google client secret is needed in Flutter.

## Google Cloud

1. Open https://console.cloud.google.com/ and create or select a project.
2. Open **Google Auth Platform**. Configure Branding with app name **Layover**,
   your support email, and your contact email. Choose an **External** audience.
   While the app is in Testing, add the Google accounts that will test the app
   under Audience / Test users. Use basic sign-in scopes only (openid, email,
   profile); the app does not request Gmail access.
3. In **Clients**, create an OAuth client of type **Web application** named
   **Layover Supabase**. This type is correct for both platforms because this
   implementation uses Supabase's browser OAuth flow.
4. Add this **Authorized redirect URI**:

   ```text
   https://sjyxntbluazapuvsdbya.supabase.co/auth/v1/callback
   ```

5. Copy the client ID and client secret directly into Supabase in the next step.
   Keep the secret out of chat, source files, screenshots, and `app/env.json`.

## Supabase

1. Open **Authentication → Sign In / Providers → Google**.
2. Enable Google. Paste the Web client ID and secret, and save. Leave nonce
   validation enabled. Leave the email-required check enabled.
3. In **Authentication → URL Configuration → Redirect URLs**, add:

   ```text
   com.layover.layover://login-callback/
   http://127.0.0.1:5183/**
   http://localhost:5183/**
   ```

   The localhost entries are for development only. Set the Site URL to your
   actual web deployment URL (or `http://127.0.0.1:5183/` during local testing).
   Add the deployed web root to Redirect URLs before release. If invitation
   query parameters are used, also allow the appropriate query-bearing root
   URLs; avoid a wildcard across unrelated production paths or domains.
4. No email-template changes are required for Google sign-in. Existing email
   accounts remain in Supabase; OTP methods remain in the store but the sign-in
   screen now offers Google and the isolated demo.

The native callback is declared in AndroidManifest.xml. Flutter's default deep
link handler is disabled so Supabase's app_links integration can exchange the
PKCE code. Web sign-in returns to the current page, retaining only `invite` and
`live_session` query parameters. It removes previous OAuth codes/errors from
the next redirect. Google credentials are configured only on the provider.

## Verify

Build with the existing public configuration:

```sh
flutter test test/google_sign_in_test.dart test/companion_widget_test.dart --concurrency=1
flutter build apk --debug --dart-define-from-file=env.json
flutter build web --release --dart-define-from-file=env.json
```

On Android, tap **Continue with Google**, select a test account in the browser,
and confirm that returning to Layover shows the trip home. Repeat after closing
the app while Google is open. On web, check the localhost and deployed return
URLs separately. Verify cancellation/retry, sign-out, a second account, and an
invitation link. A browser opening successfully alone is not a successful login.

Local tests cover the real SDK's Google authorization URL, PKCE challenge,
native redirect, external-browser launch, failed launch, callback stream errors,
web invitation preservation, retry UI, and existing navigation. Completing an
actual Google login requires the provider configuration above.

### Verification in this workspace

- All 45 Flutter tests passed; `flutter analyze` reported no issues.
- Android debug and web release builds passed with the local public settings.
- The Android update was installed on the connected phone. Android's intent
  resolver maps `com.layover.layover://login-callback/` to Layover's MainActivity.
- Chromium checks passed at 390px and 1440px for the sign-in UI, intercepted
  Google OAuth handoff with PKCE, and a simulated cancelled callback with retry.
  These checks did not authenticate a real Google account.
- The hosted `/auth/v1/settings` check still reports Google disabled. Real login
  remains pending until the Google Cloud client and Supabase provider/redirect
  configuration are saved.

References: [Supabase Google sign-in](https://supabase.com/docs/guides/auth/social-login/auth-google),
[Flutter OAuth](https://supabase.com/docs/reference/dart/auth-signinwithoauth),
[redirect URL allowlist](https://supabase.com/docs/guides/auth/redirect-urls).
