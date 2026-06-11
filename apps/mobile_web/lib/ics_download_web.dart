import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

Future<void> downloadIcs(String content, String filename) async {
  final bytes = Uint8List.fromList(utf8.encode(content));
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag()..type = 'text/calendar;charset=utf-8',
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  // Must be in DOM to trigger download on modern browsers
  web.document.body!.appendChild(anchor);
  anchor.click();
  // Delay revocation so browser can start the download
  await Future.delayed(const Duration(milliseconds: 150));
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
