import 'dart:typed_data';

import 'package:image/image.dart' as img;

Uint8List normalizeMemoryPhoto(Uint8List bytes) {
  var source = img.decodeImage(bytes);
  if (source == null) {
    throw const FormatException('Could not read this photo. Please retake it.');
  }
  source = img.bakeOrientation(source);
  if (source.width > 1600 || source.height > 1600) {
    source = img.copyResize(
      source,
      width: source.width >= source.height ? 1600 : null,
      height: source.height > source.width ? 1600 : null,
    );
  }
  // Copy pixels into a clean image: EXIF, GPS and other metadata never leave the phone.
  final clean = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 3,
  );
  img.compositeImage(clean, source);
  final result = img.encodeJpg(clean, quality: 85);
  if (result.length > 10 * 1024 * 1024) {
    throw const FormatException('This photo is too large. Please retake it.');
  }
  return result;
}
