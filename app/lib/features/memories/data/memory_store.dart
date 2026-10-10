import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../companion/domain/models.dart';
import '../domain/trip_memory.dart';
import 'memory_disk.dart';
import 'photo_processing.dart';

class MemoryStore extends ChangeNotifier {
  MemoryStore({this.client, MemoryDisk? disk, this.persistence = true})
    : disk = disk ?? MemoryDisk();
  final SupabaseClient? client;
  final MemoryDisk disk;
  final bool persistence;
  String account = '';
  bool demo = false;
  bool _syncBusy = false;
  bool _saving = false;
  bool _changing = false;
  bool get busy => _syncBusy || _saving || _changing;
  bool loaded = false;
  bool _disposed = false;
  bool _foreground = true;
  int _epoch = 0;
  Timer? _timer;
  String? error;
  List<TripMemory> memories = [];
  final Map<String, Uint8List> _demoPhotos = {};
  Future<void>? _binding;
  Future<void>? _syncing;
  static const _uuid = Uuid();
  bool get canCapture =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool _current(int epoch, String owner) =>
      !_disposed && epoch == _epoch && account == owner;
  bool _authorized(int epoch, String owner) =>
      _current(epoch, owner) && !demo && client?.auth.currentUser?.id == owner;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _replace(Json data) {
    memories.removeWhere((m) => m.id == data['id']);
    memories.add(TripMemory(data));
    memories.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  }

  Future<void> _persist(String owner) async {
    if (!persistence || kIsWeb || demo || owner != account) return;
    final data = memories
        .where((m) => m.owner == owner)
        .map((m) => m.data)
        .toList();
    await disk.write(owner, 'index.json', utf8.encode(jsonEncode(data)));
  }

  Future<void> bind(String owner, {bool isDemo = false}) {
    if (account == owner && demo == isDemo) return _binding ?? Future.value();
    final epoch = ++_epoch;
    _timer?.cancel();
    account = owner;
    demo = isDemo;
    _syncBusy = false;
    _saving = false;
    _changing = false;
    loaded = false;
    error = null;
    memories = [];
    _demoPhotos.clear();
    _syncing = null;
    _notify();
    final future = _load(epoch, owner);
    _binding = future;
    return future;
  }

  Future<void> _load(int epoch, String owner) async {
    if (owner.isEmpty) return;
    try {
      if (persistence && !demo && !kIsWeb) {
        final bytes = await disk.read(owner, 'index.json');
        if (!_current(epoch, owner)) return;
        if (bytes != null) {
          memories = rows(jsonDecode(utf8.decode(bytes)))
              .where((m) => m['owner_id'] == owner)
              .map(TripMemory.new)
              .toList();
        }
      }
      if (!_current(epoch, owner)) return;
      loaded = true;
      _notify();
      unawaited(refresh());
    } catch (_) {
      if (_current(epoch, owner)) {
        error = 'Could not open saved memories. Restart the app before taking another photo.';
        _notify();
      }
    }
  }

  void setForeground(bool value) {
    _foreground = value;
    _timer?.cancel();
    if (!value) {
      // Peers' photos and metadata never become an offline library.
      memories.removeWhere((m) => m.owner != account);
      _notify();
    } else {
      unawaited(refresh());
    }
  }

  Future<void> refresh() {
    if (_syncing != null) return _syncing!;
    if (_saving ||
        _changing ||
        !loaded ||
        account.isEmpty ||
        demo ||
        client == null ||
        !_foreground) {
      return Future.value();
    }
    final epoch = _epoch;
    final owner = account;
    final future = _sync(epoch, owner);
    _syncing = future;
    return future.whenComplete(() {
      if (_current(epoch, owner)) {
        _syncing = null;
        _timer?.cancel();
        if (_foreground) {
          _timer = Timer(
            const Duration(seconds: 30),
            () => unawaited(refresh()),
          );
        }
      }
    });
  }

  Future<Json> _command(String action, Json data, String request) async =>
      Map<String, dynamic>.from(
        await client!
                .rpc(
                  'memory_command',
                  params: {
                    'p_action': action,
                    'p_data': data,
                    'p_request_id': request,
                  },
                )
                .timeout(const Duration(seconds: 20))
            as Map,
      );

  Future<void> _sync(int epoch, String owner) async {
    if (!_authorized(epoch, owner)) return;
    _syncBusy = true;
    error = null;
    _notify();
    try {
      for (final memory in List<TripMemory>.from(
        memories.where((m) => m.owner == owner && m.pending),
      )) {
        if (!_authorized(epoch, owner)) return;
        try {
          if (memory.data['pending'] == 'delete') {
            // Even a registration whose response was lost must be deleted remotely.
            Json? deleted;
            try {
              deleted = await _command('delete', {
                'id': memory.id,
              }, memory.data['request_id'] as String);
            } on PostgrestException catch (e) {
              if (!e.message.contains('Memory unavailable')) rethrow;
            }
            if (!_authorized(epoch, owner)) return;
            if (deleted != null) {
              await client!.storage
                  .from('trip-memories')
                  .remove([memory.path])
                  .timeout(const Duration(seconds: 20));
            }
            if (!_current(epoch, owner)) return;
            if (persistence) await disk.remove(owner, '${memory.id}.jpg');
            if (!_current(epoch, owner)) return;
            memories.removeWhere((m) => m.id == memory.id);
            await _persist(owner);
            continue;
          }
          var record = memory.data;
          if (record['pending'] == 'save') {
            final saved = await _command('save', {
              'id': memory.id,
              'trip_id': memory.tripId,
              'person_name': memory.name,
              'note': memory.note,
              'place': memory.place,
              'captured_at': memory.data['captured_at'],
            }, record['request_id'] as String);
            if (!_authorized(epoch, owner)) return;
            record = {
              ...saved,
              if (saved['ready'] != true) 'pending': 'upload',
            };
            _replace(record);
            await _persist(owner);
          }
          if (!_authorized(epoch, owner)) return;
          if (record['ready'] != true) {
            final bytes =
                _demoPhotos[memory.id] ??
                await disk.read(owner, '${memory.id}.jpg');
            if (!_authorized(epoch, owner)) return;
            if (bytes == null) {
              throw const FormatException('Photo is missing on this phone.');
            }
            try {
              await client!.storage
                  .from('trip-memories')
                  .uploadBinary(
                    memory.path,
                    bytes,
                    fileOptions: const FileOptions(
                      contentType: 'image/jpeg',
                      cacheControl: '0',
                    ),
                  )
                  .timeout(const Duration(seconds: 20));
            } on StorageException catch (e) {
              // A previous attempt may have uploaded successfully before disconnection.
              if (e.statusCode != '409' && e.error != 'Duplicate') rethrow;
            }
            if (!_authorized(epoch, owner)) return;
            record = await _command(
              'ready',
              {'id': memory.id},
              _uuid.v5(
                Namespace.url.value,
                'layover-memory-ready/${memory.id}',
              ),
            );
            if (!_current(epoch, owner)) return;
            _replace(record);
            await _persist(owner);
          }
        } catch (e) {
          if (!_current(epoch, owner)) return;
          error = _message(e);
          // Keep the record and stable request ID for a later retry.
        }
      }
      if (!_authorized(epoch, owner)) return;
      final remote = rows(
        await client!
            .rpc('memory_snapshot')
            .timeout(const Duration(seconds: 20)),
      );
      if (!_current(epoch, owner)) return;
      final deletedIds = remote
          .where((m) => m['deleted_at'] != null)
          .map((m) => m['id'])
          .toSet();
      final pending = {
        for (final m in memories.where(
          (m) => m.pending && !deletedIds.contains(m.id),
        ))
          m.id: m,
      };
      final cleaned = memories
          .where((m) => m.data['cleaned'] == true)
          .map((m) => m.id)
          .toSet();
      memories = [
        for (final m in remote)
          if (!pending.containsKey(m['id']) &&
              (_foreground || m['owner_id'] == owner))
            TripMemory({...m, if (cleaned.contains(m['id'])) 'cleaned': true}),
        ...pending.values,
      ];
      // Tombstones also clean up interrupted deletions on another device.
      for (final m in List<TripMemory>.from(
        memories.where(
          (m) =>
              m.owner == owner &&
              m.deleted &&
              !m.pending &&
              m.data['cleaned'] != true,
        ),
      )) {
        if (!_authorized(epoch, owner)) return;
        await client!.storage
            .from('trip-memories')
            .remove([m.path])
            .timeout(const Duration(seconds: 20));
        if (!_current(epoch, owner)) return;
        if (persistence && !kIsWeb) await disk.remove(owner, '${m.id}.jpg');
        if (!_current(epoch, owner)) return;
        _replace({...m.data, 'cleaned': true});
      }
      if (!_current(epoch, owner)) return;
      await _persist(owner);
    } catch (e) {
      if (!_current(epoch, owner)) return;
      memories.removeWhere((m) => m.owner != owner);
      error = _message(e);
    } finally {
      if (_current(epoch, owner)) {
        _syncBusy = false;
        _notify();
      }
    }
  }

  String _message(Object e) {
    if (e is PostgrestException) {
      if (e.code == 'PGRST202' || e.code == '42P01') {
        return 'Photo backup is not set up yet. Saved photos stay on this phone.';
      }
      return e.message;
    }
    if (e is FormatException) return e.message;
    return 'Could not sync memories. Your saved photos stay on this phone. Tap retry when connected.';
  }

  Future<void> save({
    required Trip trip,
    required Uint8List photo,
    required DateTime capturedAt,
    String name = '',
    String note = '',
    String place = '',
  }) async {
    final owner = account;
    final epoch = _epoch;
    await _binding;
    if (!_current(epoch, owner) || !loaded || owner.isEmpty || trip.archived) {
      throw const FormatException('Open an active trip before taking a photo.');
    }
    if (!canCapture) {
      throw const FormatException('Take photos in the Android app.');
    }
    if (_saving) throw const FormatException('A photo is already being saved.');
    _saving = true;
    _notify();
    final id = _uuid.v4();
    try {
      final bytes = await compute(normalizeMemoryPhoto, photo);
      if (!_current(epoch, owner)) {
        throw const FormatException('Account changed.');
      }
      if (demo || !persistence) {
        _demoPhotos[id] = bytes;
      } else {
        await disk.write(owner, '$id.jpg', bytes);
      }
      if (!_current(epoch, owner)) {
        throw const FormatException('Account changed.');
      }
      _replace({
        'id': id,
        'trip_id': trip.id,
        'owner_id': owner,
        'trip_title': trip.title,
        'destination': trip.destination,
        'person_name': name.trim(),
        'note': note.trim(),
        'place': place.trim(),
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'shared': false,
        'ready': false,
        'pending': 'save',
        'request_id': _uuid.v4(),
      });
      try {
        await _persist(owner);
      } catch (_) {
        if (_current(epoch, owner)) memories.removeWhere((m) => m.id == id);
        rethrow;
      }
    } finally {
      if (_current(epoch, owner)) {
        _saving = false;
        _notify();
        unawaited(refresh());
      }
    }
  }

  Future<void> edit(
    TripMemory memory, {
    required String name,
    required String note,
    required String place,
  }) async {
    final owner = account;
    final epoch = _epoch;
    await _syncing;
    if (!_current(epoch, owner)) {
      throw const FormatException('Account changed. Reopen this memory.');
    }
    if (_changing || _saving) {
      throw const FormatException(
        'A memory is being saved. Try again in a moment.',
      );
    }
    _changing = true;
    _notify();
    try {
      if (!_current(epoch, owner) || memory.owner != owner) {
        throw const FormatException('Only the owner can edit.');
      }
      final latest = memories.where((m) => m.id == memory.id).firstOrNull;
      if (latest == null || latest.deleted) {
        throw const FormatException('Memory is unavailable.');
      }
      final data = {
        ...latest.data,
        'person_name': name.trim(),
        'note': note.trim(),
        'place': place.trim(),
      };
      if (kIsWeb) {
        final result = await _command('save', {
          'id': memory.id,
          'trip_id': memory.tripId,
          'captured_at': memory.data['captured_at'],
          'person_name': name.trim(),
          'note': note.trim(),
          'place': place.trim(),
        }, _uuid.v4());
        if (_current(epoch, owner)) _replace(result);
      } else {
        _replace({...data, 'pending': 'save', 'request_id': _uuid.v4()});
        await _persist(owner);
      }
    } finally {
      if (_current(epoch, owner)) {
        _changing = false;
        _notify();
        unawaited(refresh());
      }
    }
  }

  Future<void> visibility(TripMemory memory, bool shared) async {
    final owner = account;
    final epoch = _epoch;
    await _syncing;
    if (!_current(epoch, owner)) {
      throw const FormatException('Account changed. Reopen this memory.');
    }
    if (_changing || _saving) {
      throw const FormatException(
        'A memory is being saved. Try again in a moment.',
      );
    }
    _changing = true;
    _notify();
    try {
      if (!_authorized(epoch, owner) || memory.owner != owner) {
        throw const FormatException('Connect your account to change sharing.');
      }
      final latest = memories.where((m) => m.id == memory.id).firstOrNull;
      if (latest == null || latest.pending) {
        throw const FormatException('Finish backing up this memory first.');
      }
      final result = await _command('visibility', {
        'id': memory.id,
        'shared': shared,
        'version': latest.data['version'],
      }, _uuid.v4());
      if (!_current(epoch, owner)) return;
      _replace(result);
      await _persist(owner);
    } finally {
      if (_current(epoch, owner)) {
        _changing = false;
        _notify();
        unawaited(refresh());
      }
    }
  }

  Future<void> delete(TripMemory memory) async {
    final owner = account;
    final epoch = _epoch;
    await _syncing;
    if (!_current(epoch, owner)) {
      throw const FormatException('Account changed. Reopen this memory.');
    }
    if (_changing || _saving) {
      throw const FormatException(
        'A memory is being saved. Try again in a moment.',
      );
    }
    _changing = true;
    _notify();
    try {
      if (!_current(epoch, owner) || memory.owner != owner) {
        throw const FormatException('Only the owner can delete.');
      }
      if (kIsWeb) {
        final result = await _command('delete', {'id': memory.id}, _uuid.v4());
        if (!_current(epoch, owner)) return;
        _replace(result);
      } else {
        _replace({
          ...memory.data,
          'pending': 'delete',
          'request_id': _uuid.v4(),
        });
        await _persist(owner);
      }
    } finally {
      if (_current(epoch, owner)) {
        _changing = false;
        _notify();
        unawaited(refresh());
      }
    }
  }

  Future<Uint8List> photo(TripMemory memory) async {
    if (memory.deleted) throw const FormatException('This memory was deleted.');
    final owner = account;
    final epoch = _epoch;
    if (memory.owner == owner) {
      final local =
          _demoPhotos[memory.id] ??
          (persistence && !kIsWeb
              ? await disk.read(owner, '${memory.id}.jpg')
              : null);
      if (!_current(epoch, owner)) {
        throw const FormatException('Account changed.');
      }
      if (local != null) return local;
    }
    if (!_authorized(epoch, owner) || memory.deleted) {
      throw const FormatException('Photo is unavailable.');
    }
    // Authenticated download applies current RLS on every request; no reusable public URL.
    final bytes = await client!.storage
        .from('trip-memories')
        .download(memory.path)
        .timeout(const Duration(seconds: 20));
    if (!_current(epoch, owner)) {
      throw const FormatException('Account changed.');
    }
    if (memories.any((m) => m.id == memory.id && m.deleted)) {
      throw const FormatException('This memory was deleted.');
    }
    if (memory.owner == owner && persistence && !kIsWeb) {
      await disk.write(owner, '${memory.id}.jpg', bytes);
    }
    return bytes;
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }
}
