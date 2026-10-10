import 'package:flutter/material.dart';

import '../../companion/data/trip_store.dart';
import '../domain/models.dart';

Future<bool> liveConfirm(
  BuildContext context,
  String title,
  String body, {
  String label = 'Confirm',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(label),
          ),
        ],
      ),
    ) ??
    false;

Future<Json?> createLiveSessionForm(
  BuildContext context,
  TripStore trip,
) async {
  final name = TextEditingController(text: 'Find your group');
  String? linked = trip.trip?.archived == false ? trip.selectedTrip : null;
  var hours = 2;
  final result = await showDialog<Json>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('Create Live Map'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Session name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: linked ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Link to trip'),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Unlinked · trip contacts'),
                  ),
                  for (final t in trip.snapshot.trips.where((t) => !t.archived))
                    DropdownMenuItem(value: t.id, child: Text(t.title)),
                ],
                onChanged: (v) => setState(() => linked = v == '' ? null : v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: hours,
                decoration: const InputDecoration(labelText: 'Expires after'),
                items: [
                  for (final h in [1, 2, 4, 8])
                    DropdownMenuItem(value: h, child: Text('$h hours')),
                ],
                onChanged: (v) => setState(() => hours = v!),
              ),
              const SizedBox(height: 12),
              const Text(
                'Private invitations for existing trip contacts. Joining never turns on location sharing.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) {
                Navigator.pop(c, {
                  'name': name.text.trim(),
                  'linked_trip_id': linked,
                  'duration_hours': hours,
                });
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
  // Dialog animations can outlive its returned future; let the field unmount first.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  name.dispose();
  return result;
}
