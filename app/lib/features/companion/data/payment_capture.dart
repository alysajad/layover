import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import '../domain/payment_message.dart';

const paymentSources = {
  'com.google.android.apps.nbu.paisa.user': 'Google Pay',
  'com.phonepe.app': 'PhonePe',
  'net.one97.paytm': 'Paytm',
  'in.org.npci.upiapp': 'BHIM',
  'com.google.android.apps.messaging': 'Google Messages',
  'com.samsung.android.messaging': 'Samsung Messages',
};

class PaymentCapture extends ChangeNotifier {
  static const channel = MethodChannel('layover/payment_capture');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  SharedPreferences? _prefs;
  String _account = '';
  bool _disposed = false;
  bool _reading = false;
  bool _readAgain = false;
  bool _listening = false;
  List<Json> records = [];
  Json status = {};
  String? error;

  void initialize(SharedPreferences? prefs) {
    _prefs = prefs;
    if (supported) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'paymentsAvailable') await refresh();
      });
      _listening = true;
    }
  }

  Future<void> bindAccount(String account) async {
    if (account == _account) return;
    _account = account;
    records = [];
    status = {};
    error = null;
    try {
      records = rows(
        jsonDecode(_prefs?.getString('layover.payments.$account') ?? '[]'),
      );
      if (supported) {
        await channel.invokeMethod<void>('bindAccount', {'account': account});
      }
      if (_account == account) await refresh();
    } catch (_) {
      error =
          'Payment capture is unavailable. You can paste a payment message.';
    }
    _notify();
  }

  List<Json> pending(String tripId, TripSnapshot snapshot) {
    final recorded = {
      ...rows(snapshot.data['expenses']),
      ...rows(snapshot.data['personal_expenses']),
    }.map((e) => e['capture_id']).whereType<String>().toSet();
    return records
        .where(
          (e) =>
              e['trip_id'] == tripId &&
              e['dismissed'] != true &&
              !recorded.contains(e['capture_id']),
        )
        .toList();
  }

  Future<void> _save(String account) async {
    if (_account != account) return;
    if (_prefs != null &&
        !await _prefs!.setString(
          'layover.payments.$account',
          jsonEncode(records),
        )) {
      throw StateError('Could not save the payment inbox on this device.');
    }
    _notify();
  }

  Future<bool> importMessage(
    String text,
    String tripId, {
    DateTime? receivedAt,
  }) async {
    final parsed = parsePaymentMessage(
      text,
      receivedAt: receivedAt ?? DateTime.now(),
    );
    if (parsed == null) {
      throw const FormatException(
        'No completed INR payment found. Paste a debit or successful payment message, or add the expense manually.',
      );
    }
    if (records.any((e) => e['capture_id'] == parsed['capture_id'])) {
      return false;
    }
    records.insert(0, {...parsed, 'trip_id': tripId});
    await _save(_account);
    return true;
  }

  Future<void> dismiss(String id) async {
    for (final e in records.where((e) => e['capture_id'] == id)) {
      e['dismissed'] = true;
    }
    await _save(_account);
  }

  Future<void> refresh() async {
    if (!supported || _account.isEmpty || _disposed) return;
    if (_reading) {
      _readAgain = true;
      return;
    }
    final account = _account;
    _reading = true;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('read', {
        'account': account,
      });
      if (_account != account || _disposed || result == null) return;
      status = Map<String, dynamic>.from(result['status'] as Map);
      final items = rows(result['items']);
      for (final item in items) {
        final parsed = parsePaymentMessage(
          item['text'] as String,
          receivedAt: DateTime.fromMillisecondsSinceEpoch(
            item['posted_at'] as int,
          ),
          sourceId: item['id'] as String,
        );
        if (parsed != null &&
            !records.any((e) => e['capture_id'] == parsed['capture_id'])) {
          records.insert(0, {
            ...parsed,
            'trip_id': item['trip_id'],
            'source': item['source'],
          });
        }
      }
      await _save(account);
      if (_account != account || _disposed) return;
      // Acknowledge only after local persistence so an interrupted read can retry.
      await channel.invokeMethod<void>('acknowledge', {
        'account': account,
        'ids': items.map((e) => e['id']).toList(),
      });
      error = null;
    } catch (_) {
      error =
          'Could not read payment notifications. Try again or paste a message.';
    } finally {
      _reading = false;
      _notify();
      if (_readAgain) {
        _readAgain = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> configure(Trip trip, Set<String> sources) async {
    if (!supported || _account.isEmpty) return;
    final start = DateTime.tryParse(trip.start);
    final end = DateTime.tryParse(trip.end);
    if (start == null ||
        end == null ||
        end.isBefore(start) ||
        sources.isEmpty) {
      throw const FormatException(
        'Set the trip start and end dates and select at least one payment app.',
      );
    }
    final until = DateTime(end.year, end.month, end.day + 1);
    if (!until.isAfter(DateTime.now())) {
      throw const FormatException(
        'This trip has ended. Update its dates to enable capture.',
      );
    }
    await channel.invokeMethod<void>('configure', {
      'account': _account,
      'trip_id': trip.id,
      'start': start.millisecondsSinceEpoch,
      'end': until.millisecondsSinceEpoch,
      'sources': sources.toList(),
    });
    await refresh();
    if (status['permission'] != true) {
      await channel.invokeMethod<void>('openSettings');
    }
  }

  Future<void> stop() async {
    if (supported) {
      await channel.invokeMethod<void>('stop', {'account': _account});
    }
    await refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_listening) channel.setMethodCallHandler(null);
    super.dispose();
  }
}
