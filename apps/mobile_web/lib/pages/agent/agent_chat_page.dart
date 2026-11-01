import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../app_logger.dart';
import '../../gzus_design.dart';
import '../../widgets/simple_markdown.dart';
import '../../widgets/floating_page_scaffold.dart';

const _suggestions = <String>[
  '我上学期成绩怎么样',
  '下周三有什么课',
  '宿舍还剩多少电',
  '期末考试安排有通知吗',
];

/// 智能助手对话页（演示账号）：每条回答可展开查看执行链路，
/// 链路与 AgentLens 测试平台读取的 trace 是同一份 span。
class AgentChatPage extends StatefulWidget {
  const AgentChatPage({super.key, required this.api});

  final ApiClient api;

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

class _ChatEntry {
  _ChatEntry.user(this.text)
      : role = 'user',
        spans = const [],
        latencyMs = null,
        failed = false;

  _ChatEntry.assistant(this.text, this.spans, this.latencyMs)
      : role = 'assistant',
        failed = false;

  _ChatEntry.error(this.text)
      : role = 'assistant',
        spans = const [],
        latencyMs = null,
        failed = true;

  final String role;
  final String text;
  final List<Map<String, dynamic>> spans;
  final double? latencyMs;
  final bool failed;
}

class _AgentChatPageState extends State<AgentChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatEntry> _entries = <_ChatEntry>[];
  String? _conversationId;
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _entries.add(_ChatEntry.user(text));
      _sending = true;
    });
    _input.clear();
    _scrollToEnd();

    // 只把成功的问答作为历史发给后端，失败提示不进入对话上下文
    final history = <Map<String, String>>[
      for (final e in _entries)
        if (!e.failed) {'role': e.role, 'content': e.text},
    ];
    try {
      final reply = await widget.api.agentChat(
        messages: history,
        conversationId: _conversationId,
      );
      final spans = (reply['spans'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final answer = (reply['answer'] as String?)?.trim() ?? '';
      if (!mounted) return;
      setState(() {
        _conversationId = reply['conversationId'] as String?;
        _entries.add(reply['status'] == 'ok' && answer.isNotEmpty
            ? _ChatEntry.assistant(
                answer, spans, (reply['latencyMs'] as num?)?.toDouble())
            : _ChatEntry.error('这次没有得到回答，请换个说法再试一次。'));
      });
    } catch (error, stackTrace) {
      AppLogger.error('智能助手请求失败', error, stackTrace);
      if (!mounted) return;
      setState(() => _entries.add(_ChatEntry.error('请求失败：$error')));
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FloatingPageScaffold(
      title: '智能助手',
      icon: Icons.auto_awesome_outlined,
      actions: [
        if (_entries.isNotEmpty)
          IconButton(
            key: const ValueKey('agent-chat-reset'),
            tooltip: '新对话',
            onPressed: _sending
                ? null
                : () => setState(() {
                      _entries.clear();
                      _conversationId = null;
                    }),
            icon: const Icon(Icons.add_comment_outlined),
          ),
      ],
      bottom: null,
      floatingActionButton: null,
      body: Column(
        children: [
          Expanded(
            child: _entries.isEmpty
                ? _buildWelcome(context)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: _entries.length + (_sending ? 1 : 0),
                    itemBuilder: (context, index) => index < _entries.length
                        ? _MessageBubble(entry: _entries[index])
                        : const _ThinkingBubble(),
                  ),
          ),
          _buildInputBar(context),
        ],
      ),
    );
  }

  Widget _buildWelcome(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        Text(
          '问我课表、成绩、考勤、考试、水电余额或学校通知。',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          '演示账号使用虚构数据。每条回答都可以展开查看助手的执行链路。',
          style: GzusTextStyles.cardSubtitle(context),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _suggestions)
              ActionChip(label: Text(s), onPressed: () => _send(s)),
          ],
        ),
      ],
    );
  }

  Widget _buildInputBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('agent-chat-input'),
                controller: _input,
                enabled: !_sending,
                minLines: 1,
                maxLines: 4,
                maxLength: 2000,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                decoration: const InputDecoration(
                  hintText: '输入问题',
                  border: OutlineInputBorder(),
                  counterText: '',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const ValueKey('agent-chat-send'),
              tooltip: '发送',
              onPressed: _sending ? null : () => _send(_input.text),
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.entry});

  final _ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = entry.role == 'user';
    final background = isUser
        ? scheme.primaryContainer
        : entry.failed
            ? scheme.errorContainer
            : scheme.surfaceContainerHighest;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        // 用 Material 而非带底色的 Container：链路折叠栏的水波纹要画在气泡上
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Material(
            color: background,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 助手回答多为 Markdown（表格、列表、加粗），渲染后显示；整段仍可选中复制
                  if (isUser || entry.failed)
                    SelectableText(entry.text)
                  else
                    SelectionArea(child: SimpleMarkdown(entry.text)),
                  if (entry.spans.isNotEmpty)
                    _TraceView(spans: entry.spans, latencyMs: entry.latencyMs),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TraceView extends StatelessWidget {
  const _TraceView({required this.spans, required this.latencyMs});

  final List<Map<String, dynamic>> spans;
  final double? latencyMs;

  @override
  Widget build(BuildContext context) {
    final seconds = latencyMs == null
        ? ''
        : ' · ${(latencyMs! / 1000).toStringAsFixed(1)}s';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey('agent-chat-trace'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        dense: true,
        title: Text(
          '执行链路 · ${spans.length} 步$seconds',
          style: GzusTextStyles.cardSubtitle(context),
        ),
        children: [for (final span in spans) _SpanRow(span: span)],
      ),
    );
  }
}

class _SpanRow extends StatelessWidget {
  const _SpanRow({required this.span});

  final Map<String, dynamic> span;

  static const _icons = <String, IconData>{
    'plan': Icons.explore_outlined,
    'tool_call': Icons.build_outlined,
    'observation': Icons.visibility_outlined,
    'retrieve': Icons.search,
    'generate': Icons.edit_note,
    'guardrail': Icons.shield_outlined,
  };

  String _describe() {
    switch (span['span']) {
      case 'plan':
        final steps = (span['steps'] as List? ?? const []).join(' → ');
        return '规划：${span['intent']}${steps.isEmpty ? '' : '（$steps）'}';
      case 'tool_call':
        final args = (span['args'] as Map? ?? const {})
            .entries
            .map((e) => '${e.key}=${e.value}')
            .join(', ');
        final ok = span['schema_ok'] == false ? ' · 参数不合法' : '';
        return '调用 ${span['name']}($args)$ok';
      case 'observation':
        if (span['ok'] == false) return '返回异常：${span['error'] ?? '未知'}';
        final rows = span['row_count'];
        return rows == null ? '返回成功' : '返回 $rows 条';
      case 'retrieve':
        final hits = (span['chunk_ids'] as List? ?? const []).length;
        return '检索「${span['query']}」命中 $hits 条';
      case 'generate':
        return '生成回答';
      case 'guardrail':
        return '护栏${span['action'] == 'refuse' ? '拒答' : '改写'}：${span['reason'] ?? ''}';
    }
    return '${span['span']}';
  }

  @override
  Widget build(BuildContext context) {
    final latency = span['latency_ms'] as num? ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icons[span['span']] ?? Icons.circle_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child:
                Text(_describe(), style: Theme.of(context).textTheme.bodySmall),
          ),
          if (latency > 0)
            Text('${latency}ms', style: GzusTextStyles.cardSubtitle(context)),
        ],
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('思考中…'),
          ],
        ),
      ),
    );
  }
}
