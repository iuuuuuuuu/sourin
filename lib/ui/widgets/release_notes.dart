// ═══════════════════════════════════════════════════════════════════════
//  版本说明的极简 Markdown 渲染
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么自己渲染而不用 `flutter_markdown`
//
// 版本说明来自我们自己的 Release notes，语法很窄：标题、列表、
// 行内代码、粗体、链接。不值得为此加一个包（它还会拖进
// `markdown` 与一整套解析器，而本仓正在为安装包体积把关）。
//
// # 明确不支持的（遇到了就按纯文本显示，不报错）
// 表格、图片、引用块嵌套、HTML 内联。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// 把版本说明 Markdown 渲染成一组 widget
List<Widget> buildReleaseNotes(String md, {Color? linkColor}) {
  final lines = md.split('\n');
  final out = <Widget>[];
  final listBuf = <String>[];
  String? heading;

  void flushList() {
    if (listBuf.isEmpty) return;
    for (final l in listBuf) {
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: Sp.x1, left: Sp.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('•',
                style: TextStyle(
                    fontSize: FontSizes.sm, color: linkColor ?? Colors.grey)),
            const SizedBox(width: Sp.x2),
            Expanded(child: _inline(l, linkColor)),
          ],
        ),
      ));
    }
    listBuf.clear();
  }

  void flushHeading() {
    if (heading == null) return;
    out.add(Padding(
      padding: const EdgeInsets.only(top: Sp.x2, bottom: Sp.x1),
      child: Text(heading!,
          style: TextStyle(
              fontSize: FontSizes.base,
              fontWeight: FontWeights.semibold,
              color: linkColor)),
    ));
    heading = null;
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    final t = line.trim();
    if (t.isEmpty) {
      flushList();
      flushHeading();
      continue;
    }
    if (t.startsWith('#')) {
      flushList();
      flushHeading();
      final h = t.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      heading = h.isEmpty ? null : h;
      continue;
    }
    if (t.startsWith('- ') || t.startsWith('* ') || RegExp(r'^\d+[.)]\s').hasMatch(t)) {
      flushHeading();
      listBuf.add(t.replaceFirst(RegExp(r'^([-*]|\d+[.)])\s*'), ''));
      continue;
    }
    flushList();
    flushHeading();
    out.add(Padding(
      padding: const EdgeInsets.only(bottom: Sp.x1),
      child: _inline(t, linkColor),
    ));
  }
  flushList();
  flushHeading();

  if (out.isEmpty) {
    out.add(Text('这个版本没有写说明。',
        style: TextStyle(fontSize: FontSizes.sm, color: linkColor)));
  }
  return out;
}

/// 行内：`**粗**`、`` `代码` ``、`[文字](链接)`、`https://…`
Widget _inline(String text, Color? color) {
  final spans = <TextSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)');
  var i = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > i) {
      spans.add(TextSpan(text: text.substring(i, m.start)));
    }
    if (m.group(1) != null) {
      spans.add(TextSpan(
          text: m.group(1),
          style: const TextStyle(fontWeight: FontWeights.semibold)));
    } else if (m.group(2) != null) {
      spans.add(TextSpan(
          text: m.group(2),
          style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.cap)));
    } else {
      spans.add(TextSpan(
          text: m.group(3),
          style: TextStyle(color: color, decoration: TextDecoration.underline)));
    }
    i = m.end;
  }
  if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
  return Text.rich(
    TextSpan(children: spans),
    style: TextStyle(fontSize: FontSizes.sm, color: color),
  );
}