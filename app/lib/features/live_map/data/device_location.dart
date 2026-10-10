import 'package:geolocator/geolocator.dart';

import '../domain/models.dart';

class DeviceLocation {
  Future<void> requestPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const FormatException(
        'Location services are off. Enable them in device settings; you can still view the group.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied)
      permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.deniedForever) {
      throw const FormatException(
        'Location permission is blocked. Enable it in app or browser settings; you can still view the group.',
      );
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      throw const FormatException(
        'Location permission was not granted. You can still view the group.',
      );
    }
  }

  Stream<Json> fixes() =>
      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      ).map(
        (p) => {
          'latitude': p.latitude,
          'longitude': p.longitude,
          'accuracy_m': p.accuracy,
          'heading': p.heading >= 0 && p.heading < 360 ? p.heading : null,
          'speed_mps': p.speed >= 0 && p.speed <= 100 ? p.speed : null,
          'client_timestamp': p.timestamp.toUtc().toIso8601String(),
        },
      );
}
