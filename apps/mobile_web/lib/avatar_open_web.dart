import 'package:web/web.dart' as web;

Future<void> openAvatarInNewTab(String dataUrl, String name) async {
  final window = web.window.open('', '_blank');
  if (window == null) return;
  final doc = window.document;
  doc.title = '$name - \u5934\u50cf';
  final img = doc.createElement('img') as web.HTMLImageElement;
  img.src = dataUrl;
  img.style
    ..setProperty('max-width', '100%')
    ..setProperty('max-height', '100%')
    ..setProperty('display', 'block')
    ..setProperty('margin', 'auto');
  final body = doc.body!;
  body.style
    ..setProperty('display', 'flex')
    ..setProperty('align-items', 'center')
    ..setProperty('justify-content', 'center')
    ..setProperty('height', '100vh')
    ..setProperty('margin', '0')
    ..setProperty('background', '#f5f5f5');
  body.append(img);
}
