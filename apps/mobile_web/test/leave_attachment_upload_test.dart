import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/leave_attachment_models.dart';
import 'package:gzus_pro_mobile_web/leave_attachment_upload.dart';
import 'package:gzus_pro_mobile_web/leave_submission_flow.dart';

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

  test('学校新建请假单返回空 localStore 时使用当前表单存储', () {
    final parsed = parseLeaveFormAttachmentMetadata(
      '{"docUnid":"doc-1","processId":"process-1","nodeName":"申请人","localStore":""}',
    );

    expect(parsed, metadata);
  });

  test('学校附件组件的存储标识会原样透传', () {
    final parsed = parseLeaveFormAttachmentMetadata(
      '{"docUnid":"doc-1","processId":"process-1","nodeName":"申请人","localStore":"1"}',
    );

    expect(parsed.localStore, '1');
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

  test('办理面板消息只在附件上传完成后触发确认', () {
    const message = LeaveWorkflowMessage(
      type: 'approval_panel_ready',
      cycle: 1,
    );

    expect(
      shouldShowLeaveSubmitConfirmation(
        LeaveSubmissionStage.uploadingAttachments,
        message,
        -1,
      ),
      isFalse,
    );
    expect(
      shouldShowLeaveSubmitConfirmation(
        LeaveSubmissionStage.waitingForApproval,
        message,
        -1,
      ),
      isTrue,
    );
  });

  test('同一办理周期不会重复弹出确认', () {
    const message = LeaveWorkflowMessage(
      type: 'approval_panel_ready',
      cycle: 3,
    );

    expect(
      shouldShowLeaveSubmitConfirmation(
        LeaveSubmissionStage.waitingForApproval,
        message,
        3,
      ),
      isFalse,
    );
    expect(
      shouldShowLeaveSubmitConfirmation(
        LeaveSubmissionStage.waitingForApproval,
        message,
        2,
      ),
      isTrue,
    );
  });

  test('办理监听和提交脚本使用已验证的页面控件', () {
    final observer = buildLeaveWorkflowObserverScript('gzusLeaveWorkflow');

    expect(observer, contains("a.submitbtn"));
    expect(observer, contains("#ApprovalTable"));
    expect(observer, contains("#BU1001"));
    expect(observer, contains("approval_panel_ready"));
    expect(observer, isNot(contains('button.click')));
    expect(leaveWorkflowSubmitScript, contains("getElementById('BU1001')"));
    expect(leaveWorkflowSubmitScript, contains('button.click()'));
  });

  test('非法办理消息不会进入确认流程', () {
    expect(LeaveWorkflowMessage.parse('not-json'), isNull);
    expect(
      LeaveWorkflowMessage.parse(
        '{"type":"approval_panel_ready","cycle":"1"}',
      ),
      isNull,
    );
  });
}
