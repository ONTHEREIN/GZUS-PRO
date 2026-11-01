import 'package:flutter/material.dart';

/// 智能助手回答用的轻量 Markdown 渲染：只覆盖模型实际会输出的语法——
/// 表格、无序/有序列表、标题、**加粗** 与 `行内代码`，其余按原文显示。
/// 不引入第三方包，避免为一个页面给生产 App 增加依赖。
class SimpleMarkdown extends StatelessWidget {
  const SimpleMarkdown(this.source, {super.key});

  final String source;

  static final _tableSeparator =
      RegExp(r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$');
  static final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  static final _ordered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');

  @override
  Widget build(BuildContext context) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final blocks = <Widget>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 6));
        i++;
        continue;
      }
      // 表格：以 | 开头的连续行，第二行是分隔行
      if (trimmed.startsWith('|') &&
          i + 1 < lines.length &&
          _tableSeparator.hasMatch(lines[i + 1].trim())) {
        final rows = <List<String>>[_cells(trimmed)];
        i += 2;
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          rows.add(_cells(lines[i].trim()));
          i++;
        }
        blocks.add(_MarkdownTable(rows: rows));
        continue;
      }
      final heading = _heading.firstMatch(trimmed);
      if (heading != null) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text.rich(
            _inline(context, heading.group(2)!),
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ));
        i++;
        continue;
      }
      final bullet = _bullet.firstMatch(line);
      final ordered = bullet == null ? _ordered.firstMatch(line) : null;
      if (bullet != null || ordered != null) {
        final indent = (bullet?.group(1) ?? ordered!.group(1)!).length ~/ 2;
        final marker = bullet != null ? '•' : '${ordered!.group(2)}.';
        final text = bullet?.group(2) ?? ordered!.group(3)!;
        blocks.add(Padding(
          padding: EdgeInsets.only(left: 4.0 + indent * 16, top: 1, bottom: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: bullet != null ? 14 : 22, child: Text(marker)),
              Expanded(child: Text.rich(_inline(context, text))),
            ],
          ),
        ));
        i++;
        continue;
      }
      blocks.add(Text.rich(_inline(context, trimmed)));
      i++;
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
  }

  static List<String> _cells(String row) {
    var body = row.trim();
    if (body.startsWith('|')) body = body.substring(1);
    if (body.endsWith('|')) body = body.substring(0, body.length - 1);
    return body.split('|').map((c) => c.trim()).toList();
  }

  /// 行内：**加粗** 与 `代码`；未闭合的标记按原文显示。
  static TextSpan _inline(BuildContext context, String text) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.w700)));
      } else {
        spans.add(TextSpan(
          text: m.group(2),
          style: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          ),
        ));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(children: spans);
  }
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.rows});

  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final columns = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    TableRow row(List<String> cells, {bool header = false}) => TableRow(
          decoration:
              header ? BoxDecoration(color: scheme.surfaceContainerHigh) : null,
          children: [
            for (var c = 0; c < columns; c++)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text.rich(
                  SimpleMarkdown._inline(
                      context, c < cells.length ? cells[c] : ''),
                  style: header
                      ? const TextStyle(fontWeight: FontWeight.w700)
                      : null,
                ),
              ),
          ],
        );
    // 列多时横向滚动，不挤压文字
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(6)),
          children: [
            row(rows.first, header: true),
            for (final r in rows.skip(1)) row(r)
          ],
        ),
      ),
    );
  }
}
