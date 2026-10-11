import 'package:flutter/material.dart';

import '../../../core/date_field.dart';
import '../domain/explorer.dart';

Future<Json?> settingsForm(
  BuildContext context,
  Json current, {
  required bool currencyLocked,
}) async {
  final controllers = <String, TextEditingController>{
    for (final key in ['budget', 'group', 'start', 'end', ...categories])
      key: TextEditingController(),
  };
  var currency = current['currency'] as String;
  var modes = List<String>.from(current['modes']);
  controllers['budget']!.text = amountText(current['budget_minor'], currency);
  controllers['group']!.text = '${current['group_size']}';
  controllers['start']!.text = current['start_at'];
  controllers['end']!.text = current['end_at'];
  for (final category in categories) {
    final cap = current['caps'][category];
    controllers[category]!.text = cap == null ? '' : amountText(cap, currency);
  }
  String? error;
  final result = await showDialog<Json>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Budget and time'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: currency,
                  decoration: const InputDecoration(labelText: 'Currency'),
                  items: currencies.keys
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: currencyLocked
                      ? null
                      : (v) => setState(() => currency = v!),
                ),
                if (currencyLocked)
                  const Text('Start a new plan to change currency.'),
                for (final field in [
                  ('budget', 'Total group budget'),
                  ('group', 'Travelers'),
                  ('start', 'Start date and time'),
                  ('end', 'End date and time'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ['start', 'end'].contains(field.$1)
                        ? DateField(
                            controller: controllers[field.$1]!,
                            label: field.$2,
                            kind: DateFieldKind.dateTime,
                            firstDate: field.$1 == 'end'
                                ? DateTime.tryParse(controllers['start']!.text)
                                      ?.toLocal()
                                : null,
                          )
                        : field.$1 == 'group'
                        ? DropdownButtonFormField<int>(
                            initialValue: int.tryParse(
                              controllers['group']!.text,
                            ),
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Travelers',
                            ),
                            items: [
                              for (var i = 1; i <= 50; i++)
                                DropdownMenuItem(
                                  value: i,
                                  child: Text(
                                    '$i ${i == 1 ? 'traveler' : 'travelers'}',
                                  ),
                                ),
                            ],
                            onChanged: (v) => controllers['group']!.text = '$v',
                          )
                        : TextField(
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                            controller: controllers[field.$1],
                            decoration: InputDecoration(labelText: field.$2),
                          ),
                  ),
                const SizedBox(height: 12),
                const Text('Choose your area and starting point on the map.'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final mode in ['walk', 'bicycle', 'drive'])
                      FilterChip(
                        label: Text(mode),
                        selected: modes.contains(mode),
                        onSelected: (v) => setState(
                          () => v ? modes.add(mode) : modes.remove(mode),
                        ),
                      ),
                  ],
                ),
                const Text('Optional category caps (group amounts)'),
                for (final category in categories)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: TextField(
                      controller: controllers[category],
                      decoration: InputDecoration(labelText: '$category cap'),
                    ),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final result = <String, dynamic>{
                  ...current,
                  'currency': currency,
                  'budget_minor': readMoney(
                    controllers['budget']!.text,
                    currency,
                  ),
                  'group_size': int.parse(controllers['group']!.text),
                  'start_at': DateTime.parse(controllers['start']!.text)
                      .toUtc()
                      .toIso8601String(),
                  'end_at': DateTime.parse(controllers['end']!.text)
                      .toUtc()
                      .toIso8601String(),
                  'modes': modes.toSet().toList(),
                  'caps': {
                    for (final c in categories)
                      if (controllers[c]!.text.trim().isNotEmpty)
                        c: readMoney(controllers[c]!.text, currency),
                  },
                };
                validateSettings(result);
                Navigator.pop(context, result);
              } catch (e) {
                setState(
                  () => error = e is FormatException
                      ? e.message
                      : 'Check the values and date/time format.',
                );
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );
  // Dialog controllers remain alive until the closing transition has completed.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  for (final c in controllers.values) {
    c.dispose();
  }
  return result;
}

Future<Json?> costForm(
  BuildContext context,
  Json current,
  String author,
) async {
  final currency = current['currency'] as String;
  final low = TextEditingController(
    text: current['low_minor'] == null
        ? ''
        : amountText(current['low_minor'], currency),
  );
  final high = TextEditingController(
    text: current['high_minor'] == null
        ? ''
        : amountText(current['high_minor'], currency),
  );
  final quantity = TextEditingController(text: '${current['quantity']}');
  final description = TextEditingController(text: current['description']);
  var basis = current['cost_basis'] as String;
  String? error;
  final result = await showDialog<Json>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Enter a cost'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: low,
                  decoration: InputDecoration(
                    labelText: 'Low amount ($currency)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: high,
                  decoration: InputDecoration(
                    labelText: 'High amount ($currency, blank = low)',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: basis,
                  decoration: const InputDecoration(labelText: 'Cost basis'),
                  items: costBases
                      .map(
                        (b) => DropdownMenuItem(
                          value: b,
                          child: Text(b.replaceAll('_', ' ')),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => basis = v!,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: quantity,
                  decoration: const InputDecoration(
                    labelText: 'Quantity (vehicles / tickets / units)',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Per person multiplies by travelers and quantity. Other bases multiply by quantity only. Enter the required number of vehicles or tickets.',
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, {
              ...current,
              'low_minor': null,
              'high_minor': null,
              'estimate_status': 'unknown',
              'source': 'Not available',
              'confidence': 'unknown',
              'checked_at': checkedNow(),
            }),
            child: const Text('Mark unknown'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final result = {
                  ...current,
                  'description': description.text.trim(),
                  'low_minor': readMoney(low.text, currency),
                  'high_minor': readMoney(
                    high.text.trim().isEmpty ? low.text : high.text,
                    currency,
                  ),
                  'cost_basis': basis,
                  'quantity': int.parse(quantity.text),
                  'estimate_status': 'manual',
                  'source': 'User-entered',
                  'author': author,
                  'checked_at': checkedNow(),
                  'confidence': 'user_supplied',
                };
                if (description.text.trim().isEmpty) {
                  throw const FormatException('Enter a description.');
                }
                totalCosts(
                  [
                    {...result, 'covers': <String>[]},
                  ],
                  1,
                  currency,
                );
                Navigator.pop(context, result);
              } catch (e) {
                setState(
                  () => error = e is FormatException
                      ? e.message
                      : 'Check the cost and quantity.',
                );
              }
            },
            child: const Text('Use manual cost'),
          ),
        ],
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 250));
  for (final c in [low, high, quantity, description]) {
    c.dispose();
  }
  return result;
}
