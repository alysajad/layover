import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trip_store.dart';

class PushNotifications {
  static StreamSubscription<String>? _tokens;
  static StreamSubscription<RemoteMessage>? _messages;
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static Future<void> initialize() async {
    if (_appId.isEmpty ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
          appId: _appId,
          messagingSenderId: String.fromEnvironment('FIREBASE_SENDER_ID'),
          projectId: String.fromEnvironment('FIREBASE_PROJECT_ID'),
        ),
      );
    }
  }

  static Future<void> restore(TripStore store) async {
    if (_appId.isEmpty || store.demo || !store.signedIn) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('layover.push.${store.userId}') == true) {
      try {
        await enable(store);
      } catch (_) {
        /* A failed registration must not prevent sign-in. */
      }
    }
  }

  static Future<void> enable(TripStore store) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const FormatException(
        'Push notifications are available in the Android app.',
      );
    }
    if (store.demo || store.offline) {
      throw const FormatException(
        'Sign in online to enable push notifications.',
      );
    }
    if (_appId.isEmpty) {
      throw const FormatException(
        'Push notifications are not configured for this build.',
      );
    }
    await initialize();
    final settings = await FirebaseMessaging.instance.requestPermission();
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      throw const FormatException(
        'Notifications are disabled in device settings.',
      );
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) {
      throw const FormatException('Could not register this device. Try again.');
    }
    final result = await store.command('device_token', {'token': token});
    if (result == null) {
      throw FormatException(
        store.error ?? 'Could not register push notifications.',
      );
    }
    await _tokens?.cancel();
    await _messages?.cancel();
    _tokens = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      if (store.signedIn && !store.demo) {
        store.command('device_token', {'token': token});
      }
    });
    _messages = FirebaseMessaging.onMessage.listen((_) {
      if (store.signedIn && !store.demo) store.refresh(silent: true);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('layover.push.${store.userId}', true);
  }

  static Future<bool> unregister(TripStore store) async {
    await _tokens?.cancel();
    await _messages?.cancel();
    if (Firebase.apps.isEmpty) return true;
    var revoked = false;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        revoked =
            await store.command('device_token', {
              'token': token,
              'remove': true,
            }) !=
            null;
      }
    } catch (_) {
      /* Sign-out must work during a network failure. */
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
      revoked = true;
    } catch (_) {
      /* The caller decides whether to continue signing out. */
    }
    return revoked;
  }

  static Future<void> disable(TripStore store) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('layover.push.${store.userId}');
    if (!await unregister(store)) {
      throw const FormatException(
        'Reconnect to finish disabling push notifications on this device.',
      );
    }
  }
}
