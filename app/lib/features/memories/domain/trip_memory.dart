import '../../companion/domain/models.dart';

class TripMemory {
  const TripMemory(this.data);
  final Json data;
  String get id => data['id'] as String;
  String get owner => data['owner_id'] as String;
  String get tripId => data['trip_id'] as String;
  String get title => data['trip_title'] as String? ?? 'Trip';
  String get name => data['person_name'] as String? ?? '';
  String get note => data['note'] as String? ?? '';
  String get place => data['place'] as String? ?? '';
  String get destination => data['destination'] as String? ?? '';
  String get location =>
      [destination, place].where((s) => s.isNotEmpty).join(' · ');
  DateTime get capturedAt =>
      DateTime.parse(data['captured_at'] as String).toLocal();
  String get path => '$owner/$id.jpg';
  bool get shared => data['shared'] == true;
  bool get ready => data['ready'] == true;
  bool get deleted => data['deleted_at'] != null || data['pending'] == 'delete';
  bool get pending => data['pending'] != null;
  bool get canShare => data['can_share'] == true && ready && !pending;
}
