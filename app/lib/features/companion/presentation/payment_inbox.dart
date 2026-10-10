import 'package:flutter/material.dart';

import '../data/payment_capture.dart';
import '../data/trip_store.dart';
import '../domain/models.dart';
import 'forms.dart';

class PaymentInbox extends StatefulWidget {
  const PaymentInbox({super.key, required this.store, required this.onReview});
  final TripStore store;
  final Future<void> Function(Json initial) onReview;
  @override
  State<PaymentInbox> createState() => _PaymentInboxState();
}

class _PaymentInboxState extends State<PaymentInbox> {
  bool busy = false;
  String? error;

  Future<void> perform(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> enable() async {
    final store = widget.store;
    final trip = store.trip!;
    final user = store.userId;
    final selected = Set<String>.from(
      store.payments.status['sources'] as List? ?? paymentSources.keys.take(4),
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Capture payments for ${trip.title}'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Allow notification access in Android settings. Layover checks new notifications from the apps you select during this trip’s dates. Choose the apps you pay with, or your SMS app for bank alerts.',
                  ),
                  const SizedBox(height: 12),
                  for (final source in paymentSources.entries)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(source.value),
                      value: selected.contains(source.key),
                      onChanged: (v) => setState(() {
                        v!
                            ? selected.add(source.key)
                            : selected.remove(source.key);
                      }),
                    ),
                  const Text(
                    'Message text stays on this device and is removed after processing. Only expenses you review and save are synced. You decide whether each payment is shared or personal. You can stop capture anytime.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Enable capture'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && store.userId == user && !trip.archived) {
      await store.payments.configure(trip, selected);
    }
  }

  Future<void> paste() async {
    final store = widget.store;
    final tripId = store.selectedTrip!;
    final user = store.userId;
    final data = await showFields(context, 'Import payment message', {
      'body': 'Payment notification or bank message',
    });
    if (data == null || user != store.userId) return;
    requireFormTrip(store, user, tripId);
    final added = await store.payments.importMessage(
      data['body'] as String,
      tripId,
    );
    if (!added && mounted) {
      setState(() => error = 'This payment has already been captured.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final capture = store.payments;
    final pending = capture.pending(store.selectedTrip!, store.snapshot);
    final enabled =
        capture.status['enabled'] == true &&
        capture.status['trip_id'] == store.selectedTrip;
    final permission = capture.status['permission'] == true;
    final editable = !store.trip!.archived && !busy && !store.busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_active_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Payment inbox',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (pending.isNotEmpty)
                  Chip(label: Text('${pending.length} to review')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              capture.supported
                  ? enabled
                        ? permission
                              ? 'Capture is on for this trip’s dates. Review payments below.'
                              : 'Allow Layover notification access in Android settings to start capturing.'
                        : 'Capture new payment alerts during your trip, then choose who shares each expense.'
                  : 'Paste a payment message to fill in the amount and suggest a tag. Automatic capture is available in the Android app.',
            ),
            Wrap(
              spacing: 8,
              children: [
                if (capture.supported)
                  TextButton.icon(
                    onPressed: editable ? () => perform(enable) : null,
                    icon: const Icon(Icons.notification_add_outlined),
                    label: Text(
                      enabled
                          ? permission
                                ? 'Capture settings'
                                : 'Allow notification access'
                          : 'Set up capture',
                    ),
                  ),
                if (enabled)
                  TextButton(
                    onPressed: busy ? null : () => perform(capture.stop),
                    child: const Text('Stop capture'),
                  ),
                TextButton.icon(
                  onPressed: editable ? () => perform(paste) : null,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste payment message'),
                ),
              ],
            ),
            if (error != null || capture.error != null)
              Text(
                error ?? capture.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            for (final payment in pending) ...[
              const Divider(),
              Text(
                payment['title'] as String,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '${money(payment['amount_minor'] as int)} · ${payment['category']} · ${payment['expense_date']}',
              ),
              const Text('Suggested tag · check before saving'),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: editable
                        ? () => perform(
                            () => widget.onReview({
                              ...payment,
                              'amount': ((payment['amount_minor'] as int) / 100)
                                  .toStringAsFixed(2),
                            }),
                          )
                        : null,
                    child: const Text('Review expense'),
                  ),
                  TextButton(
                    onPressed: editable
                        ? () => perform(
                            () => capture.dismiss(
                              payment['capture_id'] as String,
                            ),
                          )
                        : null,
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            ],
            if (pending.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No payments waiting for review.'),
              ),
          ],
        ),
      ),
    );
  }
}
