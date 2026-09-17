import 'dart:typed_data';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> downloadShiplyExport(Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag()..type = 'application/zip',
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = 'gzus_public_content.zip'
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
