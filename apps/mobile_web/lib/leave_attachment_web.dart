// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'package:image_picker/image_picker.dart';

import 'leave_attachment_models.dart';

export 'leave_attachment_models.dart';

Future<List<PickedAttachment>> pickLeaveAttachments() async {
  final picker = ImagePicker();
  final pickedFiles = await picker.pickMultiImage();
  return Future.wait(
    pickedFiles.map(
      (pickedFile) async => PickedAttachment(
        name: pickedFile.name,
        bytes: await pickedFile.readAsBytes(),
      ),
    ),
  );
}
