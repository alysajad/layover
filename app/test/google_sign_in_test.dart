import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/core/env.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/presentation/companion_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MemoryAuthStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async => values.remove(key);
}

class SignInTestStore extends TripStore {
  SignInTestStore() : super(persistence: false);
  Completer<void> pending = Completer<void>();
  int attempts = 0;
  @override
  bool get configured => true;
  @override
  Future<void> signInWithGoogle() {
    attempts++;
    return pending.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'web callback keeps invites and removes old authentication parameters',
    () {
      final result = Uri.parse(
        Env.authRedirect(
          webUri: Uri.parse(
            'https://layover.example/?invite=abc&live_session=123&code=old&error=denied#access_token=old',
          ),
        ),
      );
      expect(result.queryParameters, {'invite': 'abc', 'live_session': '123'});
      expect(result.fragment, isEmpty);
      expect(Env.authRedirect(), 'com.layover.layover://login-callback/');
      expect(
        Env.authRedirect(webUri: Uri.parse('http://127.0.0.1:5183/?code=old')),
        'http://127.0.0.1:5183/',
      );
    },
  );

  test(
    'Google launch uses PKCE and external browser; failure is retryable',
    () async {
      final client = SupabaseClient(
        'https://project.supabase.co',
        'public-test-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: MemoryAuthStorage(),
        ),
      );
      final store = TripStore(client: client, persistence: false);
      addTearDown(store.dispose);
      addTearDown(client.dispose);
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      bool launchSucceeds = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'launch');
        final args = call.arguments as Map;
        final url = Uri.parse(args['url'] as String);
        expect(url.host, 'project.supabase.co');
        expect(url.queryParameters['provider'], 'google');
        expect(url.queryParameters['redirect_to'], Env.nativeAuthRedirect);
        expect(url.queryParameters['code_challenge_method'], 's256');
        expect(url.queryParameters['code_challenge'], isNotEmpty);
        expect(url.queryParameters['prompt'], 'select_account');
        expect(args['useWebView'], false);
        expect(args['useSafariVC'], false);
        return launchSucceeds;
      });
      await store.initialize();
      await store.signInWithGoogle();
      expect(
        store.signedIn,
        false,
      ); // Launching a browser is not authentication.
      launchSucceeds = false;
      await expectLater(store.signInWithGoogle(), throwsFormatException);
      // Callback errors must reach the UI rather than escape as stream errors.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(
        const AuthException('Access denied'),
        StackTrace.current,
      );
      await Future<void>.delayed(Duration.zero);
      expect(store.authError, contains('Please try again'));
    },
  );

  for (final width in [360.0, 1200.0]) {
    testWidgets('Google sign-in shows progress and allows retry at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = SignInTestStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(MaterialApp(home: SignInScreen(store: store)));
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Continue with Google'));
      await tester.pump();
      expect(find.text('Opening Google…'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      store.pending.completeError(const FormatException('Browser unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Browser unavailable'), findsOneWidget);
      store.pending = Completer<void>();
      await tester.tap(find.text('Continue with Google'));
      store.pending.complete();
      await tester.pumpAndSettle();
      expect(store.attempts, 2);
      expect(find.textContaining('Finish signing in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
