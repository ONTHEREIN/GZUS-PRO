import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/leave_attachment.dart';

void main() {
  PickedAttachment attachment(String name, int byteLength) => PickedAttachment(
        name: name,
        bytes: Uint8List(byteLength),
      );

  test('请假附件限制数量与总大小', () {
    final accepted = List.generate(
      leaveAttachmentMaximumCount,
      (index) => attachment('proof-$index.jpg', 1),
    );

    expect(validateLeaveAttachments(accepted), isNull);
    expect(
      validateLeaveAttachments([...accepted, attachment('extra.jpg', 1)]),
      '最多选择 5 张图片',
    );
    expect(
      validateLeaveAttachments(
        [attachment('large.jpg', leaveAttachmentMaximumBytes + 1)],
      ),
      '图片总大小不能超过 7 MB',
    );
  });
}
