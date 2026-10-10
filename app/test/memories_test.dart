import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/domain/models.dart';
import 'package:layover/features/memories/data/memory_disk.dart';
import 'package:layover/features/memories/data/memory_store.dart';
import 'package:layover/features/memories/data/photo_processing.dart';
import 'package:layover/features/memories/presentation/memories_screen.dart';

class ClientMock extends Mock implements SupabaseClient {}

class AuthMock extends Mock implements GoTrueClient {}

class StorageMock extends Mock implements SupabaseStorageClient {}

class FilesMock extends Mock implements StorageFileApi {}

class RpcResult extends Fake implements PostgrestFilterBuilder<dynamic> {
  RpcResult(this.result);
  final Future<dynamic> result;
  @override
  Future<dynamic> timeout(
    Duration timeLimit, {
    FutureOr<dynamic> Function()? onTimeout,
  }) => result;
}

final trip = Trip({
  'id': 'trip-one',
  'title': 'Coastal trip',
  'destination': 'Kochi',
  'organizer_user_id': 'alice',
});
final tinyPhoto = img.encodeJpg(img.Image(width: 12, height: 16));

class MemoryFixture {
  MemoryFixture(this.directory) {
    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenAnswer(
      (_) => User(
        id: user,
        appMetadata: {},
        userMetadata: {},
        aud: 'authenticated',
        createdAt: '2026-01-01',
      ),
    );
    when(() => client.storage).thenReturn(storage);
    when(() => storage.from('trip-memories')).thenReturn(files);
    when(() => client.rpc<dynamic>(any(), params: any(named: 'params')))
        .thenAnswer((call) {
          final function = call.positionalArguments.first;
          final params = call.namedArguments[#params] as Map?;
          return RpcResult(
            Future.sync(() async {
              if (!online) throw const SocketException('offline');
              if (function == 'memory_snapshot') return remote.values.toList();
              final data = Map<String, dynamic>.from(params!['p_data'] as Map);
              final id = data['id'] as String,
                  request = params['p_request_id'] as String;
              requests.add(request);
              if (receipts.containsKey(request)) {
                return receipts[request];
              }
              final action = params['p_action'];
              Json record;
              if (action == 'save') {
                record = {
                  ...?remote[id],
                  ...data,
                  'owner_id': user,
                  'trip_title': trip.title,
                  'destination': trip.destination,
                  'ready': remote[id]?['ready'] ?? false,
                  'shared': remote[id]?['shared'] ?? false,
                  'version': 1,
                  'photo_path': '$user/$id.jpg',
                };
              } else if (action == 'ready') {
                record = {...remote[id]!, 'ready': true, 'can_share': true};
              } else if (action == 'delete') {
                if (!remote.containsKey(id)) {
                  throw const PostgrestException(message: 'Memory unavailable');
                }
                record = {
                  ...remote[id]!,
                  'deleted_at': DateTime.now().toIso8601String(),
                  'shared': false,
                };
              } else {
                record = {...remote[id]!, 'shared': data['shared']};
              }
              remote[id] = record;
              receipts[request] = record;
              if (loseSaveResponse && action == 'save') {
                loseSaveResponse = false;
                throw const SocketException('response lost');
              }
              return record;
            }),
          );
        });
    when(
      () => files.uploadBinary(
        any(),
        any(),
        fileOptions: any(named: 'fileOptions'),
      ),
    ).thenAnswer((call) async {
      uploads++;
      final path = call.positionalArguments[0] as String;
      if (photos.containsKey(path)) {
        throw const StorageException('exists', statusCode: '409');
      }
      photos[path] = call.positionalArguments[1] as Uint8List;
      if (loseUploadResponse) {
        loseUploadResponse = false;
        throw const SocketException('uploaded, response lost');
      }
      return path;
    });
    when(() => files.download(any()))
        .thenAnswer((call) async => photos[call.positionalArguments[0]]!);
    when(() => files.remove(any())).thenAnswer((call) async {
      for (final path in call.positionalArguments[0] as List<String>) {
        photos.remove(path);
      }
      return [];
    });
  }
  final Directory directory;
  final client = ClientMock();
  final auth = AuthMock();
  final storage = StorageMock();
  final files = FilesMock();
  String user = 'alice';
  bool online = false, loseSaveResponse = false, loseUploadResponse = false;
  int uploads = 0;
  final remote = <String, Json>{};
  final receipts = <String, Json>{};
  final photos = <String, Uint8List>{};
  final requests = <String>[];
  MemoryStore create() => MemoryStore(
    client: client,
    disk: MemoryDisk(root: directory.path),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(const FileOptions());
  });
  test('photo processing rotates, resizes and removes metadata', () {
    final source = img.Image(width: 1800, height: 1000);
    source.exif.imageIfd.orientation = 6;
    source.exif.gpsIfd.gpsLatitudeRef = 'N';
    source.exif.gpsIfd.gpsLatitude = 10.04;
    final normalized = img.decodeJpg(
      normalizeMemoryPhoto(img.encodeJpg(source)),
    )!;
    expect(normalized.height, 1600);
    expect(normalized.width, lessThan(1600));
    expect(normalized.exif.gpsIfd.isEmpty, isTrue);
    expect(normalized.exif.imageIfd.orientation, isNot(6));
  });
  test(
    'offline restart, account isolation, duplicate-safe backup and deletion',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'layover-memory-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fixture = MemoryFixture(directory);
      var store = fixture.create();
      await store.bind('alice');
      await store.refresh();
      await store.save(
        trip: trip,
        photo: tinyPhoto,
        capturedAt: DateTime(2026, 10, 11, 12),
        name: 'Nila',
        place: 'Tea stall',
      );
      await store.refresh();
      final id = store.memories.single.id;
      expect(store.memories.single.pending, isTrue);
      expect(await store.photo(store.memories.single), isNotEmpty);
      store.dispose();
      store = fixture.create();
      addTearDown(() => store.dispose());
      await store.bind('alice');
      await store.refresh();
      expect(store.memories.single.name, 'Nila');
      fixture.user = 'bob';
      await store.bind('bob');
      await store.refresh();
      expect(store.memories, isEmpty);
      fixture.user = 'alice';
      await store.bind('alice');
      await store.refresh();
      expect(store.memories.single.id, id);
      fixture.online = true;
      fixture.loseSaveResponse = true;
      fixture.loseUploadResponse = true;
      await store.refresh();
      expect(store.memories.single.pending, isTrue);
      await store.refresh();
      expect(store.memories.single.pending, isTrue);
      await store.refresh();
      expect(store.memories.single.ready, isTrue);
      expect(store.memories.single.pending, isFalse);
      expect(fixture.remote, hasLength(1));
      expect(fixture.photos, hasLength(1));
      expect(fixture.requests[0], fixture.requests[1]);
      final uploads = fixture.uploads;
      await store.refresh();
      expect(fixture.uploads, uploads);
      await store.visibility(store.memories.single, true);
      await store.refresh();
      expect(store.memories.single.shared, isTrue);
      await store.visibility(store.memories.single, false);
      await store.refresh();
      expect(store.memories.single.shared, isFalse);
      await store.delete(store.memories.single);
      await store.refresh();
      expect(store.memories.where((m) => !m.deleted), isEmpty);
      expect(fixture.photos, isEmpty);
    },
  );
  test('capture saves immediately while cloud refresh is blocked', () async {
    final directory = await Directory.systemTemp.createTemp(
      'layover-memory-fast-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final fixture = MemoryFixture(directory);
    final store = fixture.create();
    addTearDown(store.dispose);
    await store.bind('alice');
    await store.refresh();
    final remote = Completer<dynamic>();
    when(() => fixture.client.rpc<dynamic>('memory_snapshot'))
        .thenAnswer((_) => RpcResult(remote.future));
    final refresh = store.refresh();
    await store.save(trip: trip, photo: tinyPhoto, capturedAt: DateTime.now());
    expect(store.memories, hasLength(1));
    remote.complete([]);
    await refresh;
    expect(store.memories.single.pending, isTrue);
  });
  for (final width in [360.0, 1200.0]) {
    testWidgets('private timeline and editable memory fit at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final trips = TripStore(persistence: false);
      await trips.initialize();
      addTearDown(trips.dispose);
      await tester.runAsync(
        () => trips.memories.save(
          trip: trips.trip!,
          photo: tinyPhoto,
          capturedAt: DateTime(2026, 10, 11, 12),
          name: 'Nila',
          note: 'Helped us find the café',
          place: 'Tea stall',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLayoverTheme(),
          home: MemoriesScreen(tripStore: trips, trip: trips.trip),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('People I met'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Nila'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Nila'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Edit memory'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Private · only you'), findsOneWidget);
      await tester.tap(find.text('Edit memory'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Their name'),
        'Nila from the café',
      );
      await tester.scrollUntilVisible(
        find.text('Save changes'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(trips.memories.memories.single.name, 'Nila from the café');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
