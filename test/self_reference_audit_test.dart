// ═══════════════════════════════════════════════════════════════════════
//  静态审计：自引用字段初始化（会无限递归）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这条测试（2026-09-23 交付实测抓到 Stack Overflow）
//
// `lib/ui/player_page.dart` 曾经是：
//
// ```dart
// late List<Episode> _episodes = _episodes;   // ← 从自己初始化，无限递归
// ```
//
// # 这段代码怎么来的
//
// 换源功能要求 `_episodes` / `_provider` / `_contentId` / `_sourceCode`
// 从 `widget.xxx` 提成**可变 state**（widget 是 final，换源后改不了）。
// 我做的是**批量文本替换** `widget.episodes` → `_episodes`，
// 结果把初始化表达式 `= widget.episodes` 也一起替换成了 `= _episodes`。
//
// # 为什么 28/0 的交付实测没抓到它
//
// ```text
// ① Dart 的 `late` 是**惰性初始化** —— 只有第一次读该字段才求值
// ② 而 `_episodes` 只在播放器页的特定分支被读，
//    探针路径恰好没走到 → 不报错
// ③ 结果：「通过 28 / 失败 0」与
//    「Unhandled Exception: Stack Overflow」
//    **同时出现**
// ```
//
// ★ 是翻 logcat 的 E 级日志才发现的。**交付实测的 pass 计数
//   不能替代异常扫描** —— 这两个信号当时并存。
//
// # 这类 bug 的特征
//
// ```text
// · 编译器**不会**报错（`late` 允许延迟求值，自引用在语法上合法）
// · `flutter analyze` **不会**报错
// · 单测**不会**失败（只要不读那个字段）
// · 只有**真的读到**才炸，而且炸成 147132 层栈
// ```
//
// 所以必须用**静态扫描**兜住 —— 这也是上次 jmap bug 学到的
// 「修一处 → 系统性审计一整类」的复用。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('自引用字段初始化审计', () {
    test('★ lib/ 下不允许 `_foo = _foo;` 形式的自引用初始化', () {
      /*
       * 匹配形态：
       * ```text
       * late List<Episode> _episodes = _episodes;
       * late String _provider = _provider;
       * Foo _x = _x;
       * ```
       * 关键是**赋值右侧是同一个标识符**。
       *
       * ⚠️ 不做过于宽泛的匹配 —— 误报会让人忽略这条测试。
       *    这里只抓「右侧恰好等于左侧那个 `_xxx` 标识符」。
       */
      final re = RegExp(
        r'^\s*(?:late\s+)?[\w<>?,\s\[\]]*?\b(_\w+)\s*=\s*\1\s*;',
        multiLine: true,
      );

      final hits = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final src = e.readAsStringSync();
        for (final m in re.allMatches(src)) {
          final line = src.substring(0, m.start).split('\n').length;
          hits.add('${e.path}:$line  ${m.group(0)!.trim()}');
        }
      }

      expect(
        hits,
        isEmpty,
        reason: '这些字段从自己初始化，读它就会无限递归（Stack Overflow）：\n'
            '  ${hits.join('\n  ')}\n\n'
            '通常是批量把 `widget.xxx` 替换成 `_xxx` 时，'
            '把**初始化右侧**也一起替换了。改成 `= widget.xxx`。',
      );
    });

    /*
     * ★ 反向验证：确认上面的正则**真的能抓到**那个 bug
     *
     * 否则这条测试可能是"永远绿"的空测试 —— 而空测试比没有测试更危险
     * （它给人一种"已经防住了"的错觉）。这里用当初那段真实代码验证。
     */
    test('★ 反向验证：正则确实能抓到当初那段真实代码', () {
      const theActualBug = '''
class _PlayerPageState extends State<PlayerPage> {
  late List<Episode> _episodes = _episodes;
  late String _provider = widget.provider;
  late String _contentId = widget.id;
}
''';

      final re = RegExp(
        r'^\s*(?:late\s+)?[\w<>?,\s\[\]]*?\b(_\w+)\s*=\s*\1\s*;',
        multiLine: true,
      );

      final found = re.allMatches(theActualBug).toList();
      expect(found.length, 1, reason: '应该恰好抓到 1 处（_episodes）');
      expect(found.first.group(1), '_episodes');

      // 正确的写法不能被误报
      const theFix = '''
class _PlayerPageState extends State<PlayerPage> {
  late List<Episode> _episodes = widget.episodes;
  late String _provider = widget.provider;
}
''';
      expect(re.allMatches(theFix), isEmpty,
          reason: '`= widget.episodes` 是正确写法，不能误报');
    });
  });
}
