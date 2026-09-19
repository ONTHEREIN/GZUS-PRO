import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<void> downloadShiplyExport(Uint8List bytes, String filename) async {
  await Share.shareXFiles(
    [XFile.fromData(bytes, name: filename, mimeType: 'application/zip')],
    subject: filename,
  );
}
