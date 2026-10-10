import 'dart:typed_data';

// Web only manages backed-up memories. Never persist photos in browser storage.
class MemoryDisk {
  MemoryDisk({String? root});
  Future<Uint8List?> read(String account, String name) async => null;
  Future<void> write(String account, String name, List<int> bytes) async {}
  Future<void> remove(String account, String name) async {}
}
