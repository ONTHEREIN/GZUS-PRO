// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

class PickedAttachment {
  const PickedAttachment({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

Future<PickedAttachment?> pickLeaveAttachment() async {
  final picker = ImagePicker();
  final pickedFile = await picker.pickImage(source: ImageSource.gallery);
  if (pickedFile == null) return null;

  final bytes = await pickedFile.readAsBytes();
  return PickedAttachment(name: pickedFile.name, bytes: bytes);
}
