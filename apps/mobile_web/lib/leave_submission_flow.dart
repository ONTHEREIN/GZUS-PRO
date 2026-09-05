import 'dart:convert';

enum LeaveSubmissionStage {
  waitingForForm,
  uploadingAttachments,
  waitingForApproval,
  awaitingConfirmation,
  submitting,
  submitted,
  failed,
}

class LeaveWorkflowMessage {
  const LeaveWorkflowMessage({required this.type, required this.cycle});

  final String type;
  final int cycle;

  static LeaveWorkflowMessage? parse(String raw) {
    final decoded = _decode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final type = decoded['type'];
    final cycleValue = decoded['cycle'];
    if (type is! String || cycleValue is! num) return null;
    return LeaveWorkflowMessage(type: type, cycle: cycleValue.toInt());
  }

  static Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}

bool shouldShowLeaveSubmitConfirmation(
  LeaveSubmissionStage stage,
  LeaveWorkflowMessage message,
  int lastApprovalCycle,
) {
  return message.type == 'approval_panel_ready' &&
      stage == LeaveSubmissionStage.waitingForApproval &&
      message.cycle > lastApprovalCycle;
}

String buildLeaveWorkflowObserverScript(String channelName) {
  final encodedChannelName = jsonEncode(channelName);
  return '''
(() => {
  window.__gzusLeaveWorkflowObserver?.();
  const channel = window[$encodedChannelName];
  const approvalSelector = 'a.submitbtn';
  const panelSelector = '#ApprovalTable';
  const submitSelector = '#BU1001';
  const isVisible = (element) => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== 'none' &&
      style.visibility !== 'hidden' &&
      rect.width > 0 &&
      rect.height > 0;
  };
  const notify = (type, cycle) => {
    if (channel?.postMessage) {
      channel.postMessage(JSON.stringify({type, cycle}));
    }
  };
  let approvalClicked = false;
  let cycle = 0;
  let announcedCycle = -1;
  const checkPanel = () => {
    if (!approvalClicked || announcedCycle === cycle) return;
    const panel = document.querySelector(panelSelector);
    const submit = document.querySelector(submitSelector);
    if (isVisible(panel) && isVisible(submit)) {
      announcedCycle = cycle;
      notify('approval_panel_ready', cycle);
    }
  };
  const onClick = (event) => {
    const target = event.target instanceof Element
      ? event.target.closest(approvalSelector)
      : null;
    if (!target) return;
    approvalClicked = true;
    cycle += 1;
    announcedCycle = -1;
    checkPanel();
  };
  const observer = new MutationObserver(checkPanel);
  document.addEventListener('click', onClick, true);
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['class', 'style', 'disabled', 'aria-hidden']
  });
  window.__gzusLeaveWorkflowObserver = () => {
    document.removeEventListener('click', onClick, true);
    observer.disconnect();
    delete window.__gzusLeaveWorkflowObserver;
  };
  checkPanel();
})();
''';
}

const leaveWorkflowSubmitScript = '''
(() => {
  const button = document.getElementById('BU1001');
  if (!button) return false;
  const style = window.getComputedStyle(button);
  const rect = button.getBoundingClientRect();
  if (style.display === 'none' ||
      style.visibility === 'hidden' ||
      rect.width <= 0 ||
      rect.height <= 0 ||
      button.getAttribute('aria-disabled') === 'true') {
    return false;
  }
  button.click();
  return true;
})()
''';
