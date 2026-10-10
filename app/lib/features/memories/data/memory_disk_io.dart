import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class MemoryDisk {
  MemoryDisk({this.root});
  final String? root;
  Future<void> _writes = Future.value();
  Future<File> _file(String account, String name) async {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(account) ||
        !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(name)) {
      throw const FormatException('Invalid memory path');
    }
    final base = root ?? (await getApplicationSupportDirectory()).path;
    final directory = Directory('$base/memories/$account');
    await directory.create(recursive: true);
    return File('${directory.path}/$name');
  }

  Future<Uint8List?> read(String account, String name) async {
    await _writes;
    final file = await _file(account, name);
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> write(String account, String name, List<int> bytes) {
    final operation = _writes.then((_) async {
      final file = await _file(account, name);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> remove(String account, String name) async {
    await _writes;
    final file = await _file(account, name);
    if (await file.exists()) await file.delete();
  }
}
