import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/trip_store.dart';
import '../domain/models.dart';

String money(int amount) => NumberFormat.currency(
  locale: 'en_IN',
  symbol: 'INR ',
  decimalDigits: 2,
).format(amount / 100);

void requireFormTrip(TripStore store, String user, String tripId) {
  final trip = store.snapshot.trips.where((t) => t.id == tripId).firstOrNull;
  if (store.userId != user || trip == null) {
    throw const FormatException(
      'This trip is no longer available. Close this form and refresh.',
    );
  }
  if (trip.archived) {
    throw const FormatException('This trip has been archived.');
  }
}

Future<Json?> showFields(
  BuildContext context,
  String title,
  Map<String, String> fields, {
  Map<String, String> initial = const {},
  Set<String> optional = const {},
}) => showDialog<Json>(
  context: context,
  builder: (_) => FieldsDialog(
    title: title,
    fields: fields,
    initial: initial,
    optional: optional,
  ),
);

class FieldsDialog extends StatefulWidget {
  const FieldsDialog({
    super.key,
    required this.title,
    required this.fields,
    this.initial = const {},
    this.optional = const {},
  });
  final String title;
  final Map<String, String> fields;
  final Map<String, String> initial;
  final Set<String> optional;
  @override
  State<FieldsDialog> createState() => _FieldsDialogState();
}

class _FieldsDialogState extends State<FieldsDialog> {
  final form = GlobalKey<FormState>();
  late final controllers = {
    for (final key in widget.fields.keys)
      key: TextEditingController(text: widget.initial[key]),
  };
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in widget.fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextFormField(
                    controller: controllers[f.key],
                    decoration: InputDecoration(labelText: f.value),
                    maxLines: ['body', 'notes', 'terms'].contains(f.key)
                        ? 4
                        : 1,
                    validator: (v) =>
                        !widget.optional.contains(f.key) &&
                            (v?.trim().isEmpty ?? true)
                        ? 'Required'
                        : null,
                  ),
                ),
            ],
          ),
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
          if (form.currentState!.validate()) {
            Navigator.pop(context, {
              for (final e in controllers.entries) e.key: e.value.text.trim(),
            });
          }
        },
        child: const Text('Continue'),
      ),
    ],
  );
}

Future<Json?> showEntryForm(
  BuildContext context,
  TripStore store,
  String kind, {
  TripEntry? entry,
}) => showDialog<Json>(
  context: context,
  builder: (_) => EntryForm(store: store, kind: kind, entry: entry),
);

class EntryForm extends StatefulWidget {
  const EntryForm({
    super.key,
    required this.store,
    required this.kind,
    this.entry,
  });
  final TripStore store;
  final String kind;
  final TripEntry? entry;
  @override
  State<EntryForm> createState() => _EntryFormState();
}

class _EntryFormState extends State<EntryForm> {
  late final String tripId;
  late final String accountId;
  late final Trip trip;
  late final List<Member> members;
  @override
  void initState() {
    super.initState();
    trip = widget.store.trip!;
    tripId = trip.id;
    accountId = widget.store.userId;
    members = widget.store.members.where((m) => m.active).toList();
  }

  final form = GlobalKey<FormState>();
  late final fields = <String, String>{
    'title': 'Title',
    if (widget.kind == 'poll') 'options': 'Options (one per line)',
    if (['shortlist', 'booking'].contains(widget.kind))
      'url': 'Booking or listing link',
    if (widget.kind == 'shortlist') 'price': 'Total price (INR)',
    if (['itinerary', 'meeting', 'booking'].contains(widget.kind)) ...{
      'date': 'Date (YYYY-MM-DD)',
      'time': 'Time (HH:MM)',
      'address': 'Address',
    },
    if (['booking', 'task'].contains(widget.kind))
      'remind_at': 'Reminder (YYYY-MM-DD HH:MM)',
    if (widget.kind == 'booking') ...{
      'reference': 'Confirmation reference',
      'cancellation': 'Cancellation terms',
      'payment_due': 'Payment due (YYYY-MM-DD)',
    },
    if (widget.kind == 'contact') 'phone': 'Contact phone',
    'notes': 'Notes',
  };
  late final controllers = {
    for (final key in fields.keys)
      key: TextEditingController(
        text: key == 'title'
            ? widget.entry?.title
            : key == 'options'
            ? (widget.entry?.details['options'] as List?)?.join('\n')
            : widget.entry?.text(key),
      ),
  };
  late String assignee = widget.entry?.text('assigned_to') ?? '';
  late String pollType = widget.entry?.text('poll_type').isNotEmpty == true
      ? widget.entry!.text('poll_type')
      : 'Dates';
  late String? attachment = widget.entry?.details['attachment'] as String?;
  bool uploading = false;
  String? error;
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> attach() async {
    setState(() => uploading = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg'],
      );
      if (file != null) {
        final f = file;
        if ((await f.length() ?? 10485761) > 10485760) {
          throw const FormatException('Maximum file size is 10 MB.');
        }
        final bytes = await f.readAsBytes();
        if (!mounted) return;
        requireFormTrip(widget.store, accountId, tripId);
        attachment = await widget.store.upload(tripId, f.name, bytes);
      }
    } catch (e) {
      error = friendlyError(e);
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  void submit() {
    if (!form.currentState!.validate()) return;
    try {
      requireFormTrip(widget.store, accountId, tripId);
      final details = <String, dynamic>{
        ...?widget.entry?.details,
        for (final e in controllers.entries)
          if (e.key != 'title') e.key: e.value.text.trim(),
      };
      if (widget.kind == 'poll') {
        final options = controllers['options']!.text
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
        if (options.length < 2 || options.length > 12) {
          throw const FormatException('Add 2 to 12 distinct options.');
        }
        details['options'] = options;
        details['poll_type'] = pollType;
      }
      for (final key in ['date', 'payment_due']) {
        final value = details[key] as String?;
        if (value != null && value.isNotEmpty) {
          DateFormat('yyyy-MM-dd').parseStrict(value);
        }
      }
      if ((details['time'] as String? ?? '').isNotEmpty) {
        DateFormat('HH:mm').parseStrict(details['time'] as String);
      }
      if ((details['price'] as String? ?? '').isNotEmpty) {
        parseMoney(details['price'] as String);
      }
      if ((details['url'] as String? ?? '').isNotEmpty) {
        final url = Uri.tryParse(details['url'] as String);
        if (url == null ||
            !['https', 'http'].contains(url.scheme) ||
            url.host.isEmpty) {
          throw const FormatException('Enter a valid HTTPS or HTTP link.');
        }
      }
      if ((details['remind_at'] as String? ?? '').isNotEmpty) {
        final raw = details['remind_at'] as String;
        details['remind_at'] =
            (raw.contains('T')
                    ? DateTime.parse(raw)
                    : DateFormat('yyyy-MM-dd HH:mm').parseStrict(raw))
                .toUtc()
                .toIso8601String();
      }
      if (assignee.isNotEmpty) {
        details['assigned_to'] = assignee;
      } else {
        details.remove('assigned_to');
      }
      if (attachment != null) details['attachment'] = attachment;
      Navigator.pop(context, {
        'trip_id': tripId,
        'kind': widget.kind,
        'title': controllers['title']!.text.trim(),
        'details': details,
        if (widget.entry != null) ...{
          'id': widget.entry!.id,
          'version': widget.entry!.version,
        },
      });
    } catch (e) {
      setState(
        () => error = e is FormatException
            ? e.message
            : 'Check the dates and amounts.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.entry == null ? 'Add' : 'Edit'} ${widget.kind}'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.kind == 'poll')
                DropdownButtonFormField<String>(
                  initialValue: pollType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Poll type'),
                  items: [
                    for (final type in ['Dates', 'Budget', 'Other'])
                      DropdownMenuItem(value: type, child: Text(type)),
                  ],
                  onChanged: (v) => setState(() => pollType = v!),
                ),
              for (final f in fields.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextFormField(
                    controller: controllers[f.key],
                    decoration: InputDecoration(labelText: f.value),
                    maxLength: f.key == 'title' ? 240 : null,
                    maxLines:
                        ['notes', 'options', 'cancellation'].contains(f.key)
                        ? 3
                        : 1,
                    validator: (v) =>
                        ['title', 'options'].contains(f.key) &&
                            (v?.trim().isEmpty ?? true)
                        ? 'Required'
                        : null,
                  ),
                ),
              if (['task', 'booking'].contains(widget.kind))
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue:
                        members.any((m) => m.id == assignee && m.active)
                        ? assignee
                        : '',
                    decoration: InputDecoration(
                      labelText: widget.kind == 'booking'
                          ? 'Booking owner'
                          : 'Assigned to',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Unassigned'),
                      ),
                      for (final m in members.where((m) => m.active))
                        DropdownMenuItem(value: m.id, child: Text(m.name)),
                    ],
                    onChanged: (v) => assignee = v!,
                  ),
                ),
              if (widget.kind == 'booking')
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: OutlinedButton.icon(
                    onPressed: uploading || widget.store.demo ? null : attach,
                    icon: const Icon(Icons.attach_file),
                    label: Text(
                      uploading
                          ? 'Uploading...'
                          : attachment == null
                          ? 'Attach confirmation'
                          : 'Replace attachment',
                    ),
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: uploading ? null : submit,
        child: const Text('Save'),
      ),
    ],
  );
}

Future<Json?> showMoneyForm(
  BuildContext context,
  TripStore store, {
  bool pot = false,
  Json? initial,
}) => showDialog<Json>(
  context: context,
  builder: (_) => MoneyForm(store: store, pot: pot, initial: initial),
);

class MoneyForm extends StatefulWidget {
  const MoneyForm({
    super.key,
    required this.store,
    this.pot = false,
    this.initial,
  });
  final TripStore store;
  final bool pot;
  final Json? initial;
  @override
  State<MoneyForm> createState() => _MoneyFormState();
}

class _MoneyFormState extends State<MoneyForm> {
  late final String tripId;
  late final String accountId;
  late final Trip trip;
  late final List<Member> members;
  late final int? potVersion;
  @override
  void initState() {
    super.initState();
    trip = widget.store.trip!;
    tripId = trip.id;
    accountId = widget.store.userId;
    members = widget.store.members.where((m) => m.active).toList();
    potVersion = widget.store.snapshot.pot(tripId)?['version'] as int?;
  }

  final form = GlobalKey<FormState>();
  late final title = TextEditingController(
    text: widget.initial?['title'] as String?,
  );
  late final amount = TextEditingController(
    text: widget.initial?['amount'] as String?,
  );
  late final terms = TextEditingController(
    text: widget.initial?['terms'] as String? ?? 'Payments happen outside Layover. The recipient acknowledges each transfer. The group handles booking and reimbursements under the agreed cancellation terms.',
  );
  late final deadline = TextEditingController(
    text:
        widget.initial?['deadline'] as String? ??
        DateFormat('yyyy-MM-dd')
            .format(DateTime.now().add(const Duration(days: 7))),
  );
  late final cover = TextEditingController(
    text: widget.initial?['cover'] as String? ?? '0',
  );
  late final weights = {
    for (final m in members.where((m) => m.active))
      m.id: TextEditingController(
        text: widget.initial?['shares'] is Map
            ? (((widget.initial!['shares'] as Map)[m.id] as num? ?? 0) / 100)
                  .toStringAsFixed(2)
            : '1',
      ),
  };
  late final selected = widget.initial?['shares'] is Map
      ? weights.keys
            .where((id) => (widget.initial!['shares'] as Map).containsKey(id))
            .toSet()
      : weights.keys.toSet();
  late String payer = widget.store.userId;
  late SplitMode mode = widget.initial?['shares'] is Map
      ? SplitMode.exact
      : SplitMode.equal;
  String category = 'Stay';
  String? error;
  String? receipt;
  bool uploading = false;
  @override
  void dispose() {
    for (final c in [
      title,
      amount,
      terms,
      deadline,
      cover,
      ...weights.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, int> readWeights() => {
    for (final id in selected)
      id: mode == SplitMode.equal
          ? 1
          : mode == SplitMode.weighted
          ? int.parse(weights[id]!.text)
          : RegExp(r'^0(?:\.0{1,2})?$').hasMatch(weights[id]!.text.trim())
          ? 0
          : parseMoney(weights[id]!.text),
  };
  Map<String, int>? preview() {
    try {
      return splitAmount(
        parseMoney(amount.text),
        readWeights(),
        mode: mode,
        remainderUser: widget.pot ? trip.organizer : null,
      );
    } catch (_) {
      return null;
    }
  }

  void submit() {
    if (!form.currentState!.validate()) return;
    try {
      requireFormTrip(widget.store, accountId, tripId);
      final total = parseMoney(amount.text);
      final inputs = readWeights();
      splitAmount(
        total,
        inputs,
        mode: mode,
        remainderUser: widget.pot ? trip.organizer : null,
      );
      DateTime? due;
      var covered = 0;
      if (widget.pot) {
        due = DateFormat('yyyy-MM-dd')
            .parseStrict(deadline.text)
            .add(const Duration(hours: 23, minutes: 59));
        if (due.isBefore(DateTime.now())) {
          throw const FormatException('Choose a future deadline.');
        }
        covered = cover.text.trim() == '0' ? 0 : parseMoney(cover.text);
        if (covered > total) {
          throw const FormatException('Organizer cover cannot exceed target.');
        }
      }
      Navigator.pop(context, {
        'trip_id': tripId,
        'title': title.text.trim(),
        'amount_minor': total,
        'split_mode': mode.name,
        'weights': inputs,
        if (widget.pot) ...{
          'deadline_at': due!.toUtc().toIso8601String(),
          'terms': terms.text.trim(),
          'organizer_cover_minor': covered,
          'version': potVersion,
        },
        if (!widget.pot) ...{
          'payer_id': payer,
          'category': category,
          if (receipt != null) 'receipt_path': receipt,
        },
      });
    } catch (e) {
      setState(
        () => error = e is FormatException
            ? e.message
            : 'Check shares and dates.',
      );
    }
  }

  Future<void> attach() async {
    setState(() => uploading = true);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg'],
      );
      if (picked != null) {
        final f = picked;
        if ((await f.length() ?? 10485761) > 10485760) {
          throw const FormatException('Maximum file size is 10 MB.');
        }
        final bytes = await f.readAsBytes();
        if (!mounted) return;
        requireFormTrip(widget.store, accountId, tripId);
        receipt = await widget.store.upload(tripId, f.name, bytes);
      }
    } catch (e) {
      error = friendlyError(e);
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shares = preview();
    return AlertDialog(
      title: Text(widget.pot ? 'Set trip pot' : 'Add expense'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                  maxLength: 240,
                  validator: (v) => v!.trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: amount,
                  decoration: InputDecoration(
                    labelText: widget.pot ? 'Target (INR)' : 'Amount (INR)',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    try {
                      parseMoney(v!);
                      return null;
                    } catch (_) {
                      return 'Enter a valid amount';
                    }
                  },
                ),
                if (!widget.pot) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: payer,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Paid by'),
                    items: [
                      for (final m in members.where((m) => m.active))
                        DropdownMenuItem(value: m.id, child: Text(m.name)),
                    ],
                    onChanged: (v) => payer = v!,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      for (final c in [
                        'Stay',
                        'Transport',
                        'Food',
                        'Activities',
                        'Other',
                      ])
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) => category = v!,
                  ),
                ],
                const SizedBox(height: 20),
                DropdownButtonFormField<SplitMode>(
                  isExpanded: true,
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: 'Split'),
                  items: [
                    for (final m in SplitMode.values)
                      DropdownMenuItem(
                        value: m,
                        child: Text(switch (m) {
                          SplitMode.equal => 'Equally',
                          SplitMode.exact => 'Exact amounts',
                          SplitMode.percentage => 'Percentages',
                          SplitMode.weighted => 'Weights / nights',
                        }),
                      ),
                  ],
                  onChanged: (v) => setState(() => mode = v!),
                ),
                const SizedBox(height: 12),
                for (final m in members.where((m) => m.active))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: selected.contains(m.id),
                              onChanged: (v) => setState(
                                () => v!
                                    ? selected.add(m.id)
                                    : selected.remove(m.id),
                              ),
                            ),
                            Expanded(child: Text(m.name)),
                            if (mode == SplitMode.equal)
                              Flexible(
                                child: Text(
                                  shares == null
                                      ? ''
                                      : money(shares[m.id] ?? 0),
                                  textAlign: TextAlign.end,
                                ),
                              ),
                          ],
                        ),
                        if (mode != SplitMode.equal)
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: weights[m.id],
                                  enabled: selected.contains(m.id),
                                  decoration: InputDecoration(
                                    labelText: mode == SplitMode.percentage
                                        ? '%'
                                        : mode == SplitMode.exact
                                        ? 'INR'
                                        : 'Weight',
                                  ),
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  shares == null
                                      ? ''
                                      : money(shares[m.id] ?? 0),
                                  textAlign: TextAlign.end,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                if (widget.pot) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: cover,
                    decoration: const InputDecoration(
                      labelText: 'Organizer covers from own funds (INR)',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: deadline,
                    decoration: const InputDecoration(
                      labelText: 'Deadline (YYYY-MM-DD)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: terms,
                    decoration: const InputDecoration(
                      labelText: 'Terms and cancellation agreement',
                    ),
                    maxLines: 4,
                    validator: (v) =>
                        v!.trim().isEmpty ? 'Terms are required' : null,
                  ),
                ] else if (!widget.store.offline)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: OutlinedButton.icon(
                      onPressed: uploading || widget.store.demo ? null : attach,
                      icon: const Icon(Icons.receipt_long),
                      label: Text(
                        uploading
                            ? 'Uploading...'
                            : receipt == null
                            ? 'Attach receipt'
                            : 'Receipt attached',
                      ),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: uploading ? null : submit,
          child: Text(widget.store.offline ? 'Save draft' : 'Review'),
        ),
      ],
    );
  }
}

Future<Json?> showTransferForm(
  BuildContext context,
  TripStore store, {
  Json? initial,
  Json? pot,
  Transfer? correction,
}) => showDialog<Json>(
  context: context,
  builder: (_) => TransferForm(
    store: store,
    initial: initial,
    pot: pot,
    correction: correction,
  ),
);

class TransferForm extends StatefulWidget {
  const TransferForm({
    super.key,
    required this.store,
    this.initial,
    this.pot,
    this.correction,
  });
  final TripStore store;
  final Json? initial;
  final Json? pot;
  final Transfer? correction;
  @override
  State<TransferForm> createState() => _TransferFormState();
}

class _TransferFormState extends State<TransferForm> {
  late final String tripId;
  late final String accountId;
  late final Trip trip;
  late final List<Member> members;
  @override
  void initState() {
    super.initState();
    trip = widget.store.trip!;
    tripId = trip.id;
    accountId = widget.store.userId;
    members = widget.store.members.where((m) => m.active).toList();
  }

  late final amount = TextEditingController(
    text: widget.initial?['amount_minor'] != null
        ? ((widget.initial!['amount_minor'] as num) / 100).toStringAsFixed(2)
        : widget.correction != null
        ? (widget.correction!.amount / 100).toStringAsFixed(2)
        : '',
  );
  final note = TextEditingController();
  late String? recipient =
      widget.correction?.recipient ??
      widget.initial?['recipient_id'] as String? ??
      (widget.pot != null
          ? trip.organizer
          : members.where((m) => m.id != accountId).firstOrNull?.id);
  String? error;
  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.correction == null
          ? 'Report external payment'
          : 'Correct transfer',
    ),
    content: SizedBox(
      width: 430,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: recipient,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Recipient'),
              items: [
                for (final m in members.where((m) => m.id != accountId))
                  DropdownMenuItem(value: m.id, child: Text(m.name)),
                if (recipient != null &&
                    !members.any((m) => m.id == recipient && m.id != accountId))
                  DropdownMenuItem(
                    value: recipient,
                    enabled: false,
                    child: const Text('Recipient no longer available'),
                  ),
              ],
              onChanged: widget.pot != null || widget.correction != null
                  ? null
                  : (v) => recipient = v,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount (INR)'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: note,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
              maxLength: 1000,
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
            requireFormTrip(widget.store, accountId, tripId);
            if (!widget.store.snapshot
                .members(tripId)
                .any((m) => m.id == recipient && m.active)) {
              throw const FormatException('Recipient is no longer a member.');
            }
            if (recipient == null || recipient == widget.store.userId) {
              throw const FormatException('Choose another recipient.');
            }
            Navigator.pop(context, {
              'trip_id': tripId,
              'recipient_id': recipient,
              'amount_minor': parseMoney(amount.text),
              'note': note.text.trim(),
              if (widget.pot != null) 'pot_id': widget.pot!['id'],
              if (widget.correction != null) ...{
                'replaces_id': widget.correction!.id,
                if (widget.correction!.potId != null)
                  'pot_id': widget.correction!.potId,
              },
            });
          } catch (e) {
            setState(() => error = friendlyError(e));
          }
        },
        child: const Text('Report payment'),
      ),
    ],
  );
}
