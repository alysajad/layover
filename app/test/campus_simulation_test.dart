import 'package:flutter_test/flutter_test.dart';
import 'package:layover/features/live_map/data/campus_simulation.dart';
import 'package:layover/features/live_map/domain/models.dart';

void main() {
  test(
    'campus runners move, expire offline, and reset without publishing GPS',
    () async {
      var now = DateTime.utc(2026, 10, 11);
      final api = CampusSimulation(adminId: 'admin', clock: () => now);
      const id = CampusSimulation.sessionId;
      const data = {'session_id': id};
      expect(api.simulated, isTrue);
      expect(api.client, isNull);
      final before = await api.snapshot(id);
      final original = (before['locations'] as List).first as Json;
      now = now.add(const Duration(seconds: 10));
      api.tick(const Duration(seconds: 10));
      final moved = await api.snapshot(id);
      expect(
        distanceMetres(original, (moved['locations'] as List).first as Json),
        greaterThan(10),
      );

      api.setMode('sim-runner-0', 'offline');
      now = now.add(const Duration(seconds: 31));
      api.tick(const Duration(seconds: 31));
      expect((await api.snapshot(id))['locations'], hasLength(2));
      await api.command('consent', data);
      expect((await api.snapshot(id))['locations'], hasLength(3));
      await api.command('stop', data);
      expect((await api.snapshot(id))['locations'], hasLength(2));
      await expectLater(api.publish(id, 1, 1, {}), throwsFormatException);

      await api.command('end', data);
      await expectLater(api.snapshot(id), throwsFormatException);
      api.reset();
      final reset = await api.snapshot(id);
      expect(reset['members'], hasLength(4));
      expect(reset['locations'], hasLength(3));
      expect(api.adminSharing, isFalse);
    },
  );
}
