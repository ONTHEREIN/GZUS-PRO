import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/leave_attachment_models.dart';
import 'package:gzus_pro_mobile_web/leave_attachment_upload.dart';

void main() {
  const metadata = (
    docUnid: 'doc-1',
    processId: 'process-1',
    nodeName: '申请人',
    localStore: '0',
  );

  PickedAttachment attachment(String name) => PickedAttachment(
        name: name,
        bytes: Uint8List.fromList([1]),
      );

  test('解析当前表单的附件上传字段', () {
    final parsed = parseLeaveFormAttachmentMetadata(
      '{"docUnid":"doc-1","processId":"process-1","nodeName":"申请人","localStore":"0"}',
    );

    expect(parsed, metadata);
  });

  test('学校新建请假单省略 localStore 时使用当前表单存储', () {
    final parsed = parseLeaveFormAttachmentMetadata(
      '{"docUnid":"doc-1","processId":"process-1","nodeName":"申请人"}',
    );

    expect(parsed, metadata);
  });

  test('缺少当前表单附件字段时失败', () {
    expect(
      () => parseLeaveFormAttachmentMetadata('{"docUnid":"doc-1"}'),
      throwsA(isA<StateError>()),
    );
  });

  test('等待学校页面生成当前请假单的附件上传字段', () async {
    var attempts = 0;
    final waits = <Duration>[];

    final result = await waitForLeaveFormAttachmentMetadata(
      maximumAttempts: 4,
      retryInterval: const Duration(milliseconds: 500),
      readMetadata: () async {
        attempts++;
        if (attempts < 3) {
          throw StateError('当前请假单尚未生成');
        }
        return metadata;
      },
      wait: (duration) async => waits.add(duration),
    );

    expect(result, metadata);
    expect(attempts, 3);
    expect(waits,
        const [Duration(milliseconds: 500), Duration(milliseconds: 500)]);
  });

  test('学校页面始终未生成草稿时明确失败', () async {
    await expectLater(
      waitForLeaveFormAttachmentMetadata(
        maximumAttempts: 2,
        retryInterval: const Duration(milliseconds: 500),
        readMetadata: () async => throw StateError('当前请假单尚未生成'),
        wait: (duration) async {},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('尚未生成当前请假单草稿'),
        ),
      ),
    );
  });

  test('附件按顺序上传，失败时停止后续上传', () async {
    final uploadedNames = <String>[];

    await expectLater(
      uploadLeaveAttachments(
        [
          attachment('first.jpg'),
          attachment('failed.jpg'),
          attachment('last.jpg')
        ],
        metadata,
        (currentMetadata, currentAttachment) async {
          expect(currentMetadata, metadata);
          uploadedNames.add(currentAttachment.name);
          return currentAttachment.name != 'failed.jpg';
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(uploadedNames, ['first.jpg', 'failed.jpg']);
  });
}
