import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/core/date_field.dart';
import 'package:layover/features/companion/data/payment_capture.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/domain/models.dart';
import 'package:layover/features/companion/domain/payment_message.dart';
import 'package:layover/features/companion/presentation/companion_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final received = DateTime(2026, 10, 11, 12);

  test(
    'extracts debit amounts, merchants, tags, and transaction identities',
    () {
      final payment = parsePaymentMessage(
        'Paid ₹1,250.50 to Blue Cafe on 11 Oct. UPI Ref 123456789012',
        receivedAt: received,
      )!;
      expect(payment['amount_minor'], 125050);
      expect(payment['title'], 'Blue Cafe');
      expect(payment['category'], 'Food');
      expect(payment['expense_date'], '2026-10-11');
      final bank = parsePaymentMessage(
        'A/c XX123 debited by INR 1,250.50 at Blue Cafe. Ref 123456789012 Avl balance INR 9,000',
        receivedAt: received,
      )!;
      expect(bank['amount_minor'], 125050);
      expect(bank['capture_id'], payment['capture_id']);
      expect(paymentCategory('Paid Rs. 120 to Uber'), 'Transport');
      expect(paymentCategory('Paid Rs. 2500 to Palm Resort'), 'Stay');
      expect(paymentCategory('Paid Rs. 200 to City Museum'), 'Activities');
      expect(paymentCategory('Paid Rs. 100 to Unknown Person'), 'Other');
      final first = parsePaymentMessage(
        'Paid INR 100 to Cafe',
        receivedAt: received,
        sourceId: 'notification-1',
      );
      final second = parsePaymentMessage(
        'Paid INR 100 to Cafe',
        receivedAt: received,
        sourceId: 'notification-2',
      );
      expect(first!['capture_id'], isNot(second!['capture_id']));
      for (final message in [
        'OTP 123456 for payment of INR 500',
        'Payment of Rs 500 failed',
        'Received ₹500 from Sam',
        'INR 500 credited to account',
        'Refund for paid INR 500',
        'Payment of INR 500 pending',
        'Payment of INR 500 is due',
        'Autopay payment of INR 500 scheduled',
        'Payment request: INR 500',
        'Payment successful USD 50',
        'Paid INR 0 to Uber',
        'Paid INR 9999999999 to Uber',
        'Balance INR 500',
      ]) {
        expect(
          parsePaymentMessage(message, receivedAt: received),
          isNull,
          reason: message,
        );
      }
    },
  );

  test('native queue persists before acknowledgment, deduplicates, and isolates accounts', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final capture = PaymentCapture()..initialize(prefs);
    addTearDown(capture.dispose);
    var acknowledged = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PaymentCapture.channel, (call) async {
          if (call.method == 'read') {
            return {
              'status': {'permission': true},
              'items': [
                {
                  'id': 'native-1',
                  'trip_id': 'trip-a',
                  'source': 'com.phonepe.app',
                  'posted_at': received.millisecondsSinceEpoch,
                  'text': 'Paid INR 200 to Cafe. UPI Ref 12345678',
                },
              ],
            };
          }
          if (call.method == 'acknowledge') {
            expect(
              prefs.getString('layover.payments.user-a'),
              contains('Cafe'),
            );
            expect(
              prefs.getString('layover.payments.user-a'),
              isNot(contains('Paid INR')),
            );
            acknowledged++;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PaymentCapture.channel, null),
    );
    await capture.bindAccount('user-a');
    await capture.refresh();
    expect(acknowledged, 2);
    expect(capture.pending('trip-a', TripSnapshot.empty()), hasLength(1));
    expect(capture.pending('trip-b', TripSnapshot.empty()), isEmpty);
    final id = capture.records.single['capture_id'] as String;
    expect(
      capture.pending(
        'trip-a',
        TripSnapshot({
          'expenses': [
            {'capture_id': id},
          ],
        }),
      ),
      isEmpty,
    );
    await capture.dismiss(id);
    await capture.refresh();
    expect(capture.pending('trip-a', TripSnapshot.empty()), isEmpty);
    await capture.bindAccount('');
    expect(capture.records, isEmpty);
  });

  for (final width in [360.0, 1200.0]) {
    testWidgets('review captured shared and personal payments at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = TripStore(persistence: false);
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLayoverTheme(),
          home: CompanionScreen(store: store),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tap(find.text('Money').last);
      await tap(find.text('Expenses'));
      await tap(find.text('Paste payment message'));
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'Payment notification or bank message',
        ),
        'Paid INR 900 to Sunset Cafe. UPI Ref 123456789012',
      );
      await tap(find.text('Continue'));
      expect(find.text('1 to review'), findsOneWidget);
      final previousBalance = balances(
        store.snapshot.expenses('demo-goa'),
        store.snapshot.transfers('demo-goa'),
      );
      await tap(find.text('Review expense'));
      expect(find.text('Food'), findsOneWidget);
      expect(find.text('900.00'), findsOneWidget);
      await tap(find.text('Split with trip'));
      await tap(find.text('Personal · only me').last);
      await tap(find.text('Review'));
      await tap(find.text('Confirm'));
      expect(
        rows(store.snapshot.data['personal_expenses']).single['category'],
        'Food',
      );
      expect(
        balances(
          store.snapshot.expenses('demo-goa'),
          store.snapshot.transfers('demo-goa'),
        ),
        previousBalance,
      );
      expect(store.payments.pending('demo-goa', store.snapshot), isEmpty);
      await store.payments.importMessage(
        'Paid Rs. 300 to Uber. Ref 87654321',
        'demo-goa',
      );
      await tester.pumpAndSettle();
      await tap(find.text('Review expense'));
      expect(find.text('Transport'), findsOneWidget);
      await tap(find.text('Review'));
      await tap(find.text('Confirm'));
      final expense = store.snapshot.expenses('demo-goa').first;
      expect(expense.title, 'Uber');
      expect(expense.amount, 30000);
      expect(
        expense.splits.values.fold<int>(0, (sum, value) => sum + value),
        30000,
      );
      expect(expense.data['expense_date'], isNotNull);
      expect(store.payments.pending('demo-goa', store.snapshot), isEmpty);
      store.switchDemoUser('demo-rahul');
      await tester.pumpAndSettle();
      expect(find.text('Personal expenses · only you'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'calendar and time picker retain local values and support clearing',
    (tester) async {
      final controller = TextEditingController(text: '2026-10-11T09:30:00');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DateField(
              controller: controller,
              label: 'Reminder',
              optional: true,
              kind: DateFieldKind.dateTime,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      final date = DateTime.parse(controller.text).toLocal();
      expect(date, DateTime(2026, 10, 11, 9, 30));
      await tester.tap(find.byTooltip('Clear Reminder'));
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
    },
  );
}
