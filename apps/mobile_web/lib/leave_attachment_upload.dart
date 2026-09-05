import 'dart:convert';

import 'leave_attachment_models.dart';

typedef LeaveFormAttachmentMetadata = ({
  String docUnid,
  String processId,
  String nodeName,
  String localStore,
});

LeaveFormAttachmentMetadata parseLeaveFormAttachmentMetadata(
  Object javaScriptResult,
) {
  final firstDecoded = jsonDecode(javaScriptResult.toString());
  final decoded =
      firstDecoded is String ? jsonDecode(firstDecoded) : firstDecoded;
  if (decoded is! Map) {
    throw const FormatException('请假表单未返回附件上传信息');
  }
  final docUnid = decoded['docUnid']?.toString().trim() ?? '';
  final processId = decoded['processId']?.toString().trim() ?? '';
  final nodeName = decoded['nodeName']?.toString().trim() ?? '';
  // 学校的新建请假单未输出 localStore；附件组件以 "0" 表示当前表单存储。
  final parsedLocalStore = decoded['localStore']?.toString().trim() ?? '';
  final localStore = parsedLocalStore.isEmpty ? '0' : parsedLocalStore;
  if (docUnid.isEmpty || processId.isEmpty || nodeName.isEmpty) {
    throw StateError('未读取到当前请假单的附件上传信息');
  }
  return (
    docUnid: docUnid,
    processId: processId,
    nodeName: nodeName,
    localStore: localStore,
  );
}

Future<LeaveFormAttachmentMetadata> waitForLeaveFormAttachmentMetadata({
  required int maximumAttempts,
  required Duration retryInterval,
  required Future<LeaveFormAttachmentMetadata> Function() readMetadata,
  required Future<void> Function(Duration) wait,
}) async {
  for (var attempt = 0; attempt < maximumAttempts; attempt++) {
    try {
      return await readMetadata();
    } on StateError {
      // 办事大厅会在初始字段出现后异步生成当前单据及附件上传参数。
    } on FormatException {
      // WebView 返回值会随平台包装一次字符串，下一次轮询后再解析。
    }
    if (attempt + 1 < maximumAttempts) await wait(retryInterval);
  }
  throw StateError('学校页面尚未生成当前请假单草稿，请稍后重试上传附件');
}

Future<void> uploadLeaveAttachments(
  List<PickedAttachment> attachments,
  LeaveFormAttachmentMetadata metadata,
  Future<bool> Function(LeaveFormAttachmentMetadata, PickedAttachment) upload,
) async {
  for (final attachment in attachments) {
    final uploaded = await upload(metadata, attachment);
    if (!uploaded) {
      throw StateError('附件“${attachment.name}”上传失败');
    }
  }
}
