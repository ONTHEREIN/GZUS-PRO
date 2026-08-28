import 'dart:typed_data';

class PickedAttachment {
  const PickedAttachment({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

const leaveAttachmentMaximumCount = 5;
const leaveAttachmentMaximumBytes = 7 * 1024 * 1024;

int leaveAttachmentTotalBytes(List<PickedAttachment> attachments) =>
    attachments.fold(0, (total, attachment) => total + attachment.bytes.length);

String? validateLeaveAttachments(List<PickedAttachment> attachments) {
  if (attachments.isEmpty) return '请至少选择一张图片';
  if (attachments.length > leaveAttachmentMaximumCount) {
    return '最多选择 $leaveAttachmentMaximumCount 张图片';
  }
  if (leaveAttachmentTotalBytes(attachments) > leaveAttachmentMaximumBytes) {
    return '图片总大小不能超过 7 MB';
  }
  return null;
}
