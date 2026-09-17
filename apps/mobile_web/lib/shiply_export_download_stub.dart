import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<void> downloadShiplyExport(Uint8List bytes) async {
  await Share.shareXFiles(
    [
      XFile.fromData(bytes,
          name: 'gzus_public_content.zip', mimeType: 'application/zip')
    ],
    subject: 'gzus_public_content.zip',
  );
}
