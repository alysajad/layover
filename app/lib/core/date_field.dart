import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

enum DateFieldKind { date, time, dateTime }

/// Keeps the stored value machine-readable while showing a local, friendly date.
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.controller,
    required this.label,
    this.kind = DateFieldKind.date,
    this.optional = false,
    this.initialDate,
    this.firstDate,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final DateFieldKind kind;
  final bool optional;
  final DateTime? initialDate;
  final DateTime? firstDate;
  final VoidCallback? onChanged;

  DateTime? parse(String value) => kind == DateFieldKind.time
      ? DateTime.tryParse('2000-01-01T$value')
      : DateTime.tryParse(value)?.toLocal();

  Future<void> pick(BuildContext context) async {
    var value = parse(controller.text) ?? initialDate ?? DateTime.now();
    if (kind != DateFieldKind.time) {
      final first = firstDate ?? DateTime(2000);
      final last = DateTime(2100, 12, 31);
      final date = await showDatePicker(
        context: context,
        initialDate: value.isBefore(first)
            ? first
            : value.isAfter(last)
            ? last
            : value,
        firstDate: first,
        lastDate: last,
        helpText: label,
      );
      if (date == null || !context.mounted) return;
      value = DateTime(
        date.year,
        date.month,
        date.day,
        value.hour,
        value.minute,
      );
    }
    if (kind != DateFieldKind.date) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(value),
        helpText: label,
      );
      if (time == null || !context.mounted) return;
      value = DateTime(
        value.year,
        value.month,
        value.day,
        time.hour,
        time.minute,
      );
    }
    controller.text = switch (kind) {
      DateFieldKind.date => DateFormat('yyyy-MM-dd').format(value),
      DateFieldKind.time => DateFormat('HH:mm').format(value),
      DateFieldKind.dateTime => value.toUtc().toIso8601String(),
    };
    onChanged?.call();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: controller,
    builder: (context, value, _) {
      final date = parse(value.text);
      final display = date == null
          ? value.text
          : switch (kind) {
              DateFieldKind.date => DateFormat('d MMM yyyy').format(date),
              DateFieldKind.time => TimeOfDay.fromDateTime(
                date,
              ).format(context),
              DateFieldKind.dateTime =>
                '${DateFormat('d MMM yyyy').format(date)} · ${TimeOfDay.fromDateTime(date).format(context)}',
            };
      return TextFormField(
        key: ValueKey('${label}_${value.text}'),
        initialValue: display,
        readOnly: true,
        onTap: () => pick(context),
        decoration: InputDecoration(
          labelText: label,
          hintText: kind == DateFieldKind.time
              ? 'Choose a time'
              : 'Choose a date',
          prefixIcon: Icon(
            kind == DateFieldKind.time
                ? Icons.schedule
                : Icons.calendar_month_outlined,
          ),
          suffixIcon: optional && value.text.isNotEmpty
              ? IconButton(
                  tooltip: 'Clear $label',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    controller.clear();
                    onChanged?.call();
                  },
                )
              : null,
        ),
        validator: (_) {
          if (controller.text.isEmpty) return optional ? null : 'Required';
          if (date == null) return 'Choose a valid date';
          if (firstDate != null &&
              DateUtils.dateOnly(date)
                  .isBefore(DateUtils.dateOnly(firstDate!))) {
            return 'Choose ${DateFormat('d MMM yyyy').format(firstDate!)} or later';
          }
          return null;
        },
      );
    },
  );
}
