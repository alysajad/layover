import 'package:uuid/uuid.dart';

import 'models.dart';

const expenseCategories = [
  'Stay',
  'Transport',
  'Food',
  'Activities',
  'Shopping',
  'Other',
];

String paymentCategory(String message) {
  // ponytail: deterministic suggestions; unfamiliar merchants remain editable Other.
  for (final entry in const {
    'Stay': r'\b(hotel|hostel|resort|villa|airbnb|oyo|lodging|homestay|booking\.com)\b',
    'Transport': r'\b(uber|ola|rapido|taxi|cab|metro|railway|irctc|train|bus|flight|airlines|petrol|fuel|parking|toll)\b',
    'Food': r'\b(zomato|swiggy|restaurant|cafe|coffee|dinner|lunch|breakfast|food|pizza|bakery|starbucks|mcdonalds|groceries|blinkit|zepto)\b',
    'Activities':
        r'\b(ticket|museum|cinema|movie|tour|adventure|park|show|bookmyshow)\b',
    'Shopping':
        r'\b(amazon|flipkart|myntra|shop|store|mall|souvenir|clothing)\b',
  }.entries) {
    if (RegExp(entry.value, caseSensitive: false).hasMatch(message)) {
      return entry.key;
    }
  }
  return 'Other';
}

/// A notification is only a suggestion, never proof of a settled payment.
Json? parsePaymentMessage(
  String raw, {
  required DateTime receivedAt,
  String? sourceId,
}) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty || text.length > 4000) return null;
  if (RegExp(
    r'\b(otp|one.time.password|verification code|failed|declined|pending|processing|refund|refunded|reversed|reversal|cashback|credited|received|collect request|payment request|request money|mandate|autopay|scheduled|reminder|due|will be|pay now)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return null;
  }
  if (!RegExp(
    r'\b(paid|debited|spent|sent|payment successful|payment of|transferred|purchase of)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return null;
  }
  final amountPattern =
      r'(?:INR\s*|Rs\.?\s*|₹\s*)(\d[\d,]*(?:\.\d{1,2})?)(?![\d.])';
  // Prefer the amount next to the debit verb over an available balance.
  final outgoing =
      RegExp(
        '(?:paid|debited(?: by| for)?|spent|sent|transferred|payment of|purchase of)\\s*(?:[:=-]\\s*)?$amountPattern',
        caseSensitive: false,
      ).firstMatch(text) ??
      RegExp(
        '$amountPattern\\s*(?:(?:has been|is|was)\\s+)?(?:debited|paid|spent|sent|transferred)',
        caseSensitive: false,
      ).firstMatch(text);
  final matches = RegExp(
    amountPattern,
    caseSensitive: false,
  ).allMatches(text).toList();
  final match = outgoing ?? (matches.length == 1 ? matches.single : null);
  if (match == null) return null;
  int amount;
  try {
    amount = parseMoney(match.group(1)!);
  } on FormatException {
    return null;
  }
  if (amount > 99999999999) return null;
  final merchantMatch = RegExp(
    r'\b(?:to|at)\s+(.+?)(?=\s+(?:on|using|via|from|with|ref|upi|txn|transaction|avl|available|balance)\b|[;\n]|$)',
    caseSensitive: false,
  ).firstMatch(text);
  final merchant = merchantMatch
      ?.group(1)
      ?.replaceAll(RegExp(r'[.!,]+$'), '')
      .trim();
  final reference = RegExp(
    r'\b(?:UPI\s*(?:Ref(?:erence)?\s*(?:No)?|transaction\s*(?:ID)?)|UTR|Ref(?:erence)?\s*(?:No|ID)?|Txn\s*(?:ID|No)?)\s*[.:#-]?\s*([A-Z0-9]{6,40})\b',
    caseSensitive: false,
  ).firstMatch(text)?.group(1)?.toUpperCase();
  final day = receivedAt.toLocal().toIso8601String().substring(0, 10);
  final fingerprint = reference == null
      ? '${sourceId ?? day}|${text.toLowerCase()}'
      : '$amount|$reference';
  return {
    'capture_id': const Uuid().v5(
      Namespace.url.value,
      'layover-payment:$fingerprint',
    ),
    'title': merchant == null || merchant.isEmpty
        ? 'Payment'
        : merchant.substring(0, merchant.length.clamp(0, 240)),
    'amount_minor': amount,
    'category': paymentCategory(text),
    'expense_date': day,
    'received_at': receivedAt.toUtc().toIso8601String(),
  };
}
