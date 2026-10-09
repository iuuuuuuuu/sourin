// ═══════════════════════════════════════════════════════════════════════
//  任务㉑③⑦ 进播放页时标题栏必须转暗（修"闪白条"）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 进入播放页还是上面会闪出来白条
// > 我觉得点播放页进去的时候那个白条可能跟顶部的自定义操作条有关系,
// > 然后吧 其实还有点丑
//
// ★ 用户的猜测**是对的**。
//
// # 实测根因（`.probe/real_player_capture.py`，真实点击）
//
// ```text
// STEP home    顶部 40px = #e7eaf2 / #e8ebf3   ← 浅色液态玻璃
// STEP detail  顶部 40px = #e7eaf2 / #e8ebf3   ← 同上
// 点「继续观看」→ 播放页（纯黑）
// ```
// 标题栏挂在 `MaterialApp.builder`（**Navigator 之外**），
// 所以它**永远压在所有路由之上**。播放页是纯黑，
// 那条浅色玻璃就成了一条 40px 的"白条" —— 正是用户看到的东西。
//
// # 为什么不能像原版那样隐藏（关键约束）
//
// 原版 `TitleBar.vue`：
// ```js
// hidden.value = route.name === "player";
// ```
// 原版能这么干是因为它是 **WebView 里的网页**，窗口由 Tauri 管，
// 隐藏标题栏后**原生窗口仍然可拖**。
//
// 我们去掉了系统标题栏（`titleBarStyle: hidden`），
// **这条标题栏就是唯一的拖动区** —— 隐藏它 = 窗口彻底拖不动。
// 用户为这件事专门纠正过（`player_page.dart:602-604` 记录了原话）：
// ```text
// > 播放器页面没有顶部的那个可拖动 缩小 放大 关闭的那个操作条,
// > 影响体验,在桌面端播放页面 无法拖动窗口
// ```
//
// ⇒ 所以正解是 **保留功能、压暗颜色**，不是隐藏。
//
// # 实测效果（修复后）
//
// ```text
// home    LIGHT   #e7eaf2       ← 不变
// detail  LIGHT   #e7eaf2       ← 不变
// 进播放页 转场 31 帧：LIGHT-top = 0，dark = 28   ← ★ 一条浅色帧都没有
// 播放页   #000000              ← 与纯黑播放页融为一体
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String stripComments(String s) {
  final noBlock = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  group('任务㉑③⑦ 播放页标题栏必须转暗', () {
    late String shellSrc;
    late String playerSrc;
    late String visSrc;

    setUpAll(() {
      shellSrc = File('lib/shell.dart').readAsStringSync();
      playerSrc = File('lib/ui/player_page.dart').readAsStringSync();
      visSrc = File('lib/ui/titlebar_visibility.dart').readAsStringSync();
    });

    test('★ 必须存在 `titleBarDark` 信号', () {
      expect(
        visSrc.contains('final titleBarDark = ValueNotifier<bool>'),
        isTrue,
        reason: '★ 需要一个"标题栏转暗"的信号 —— 没有它就修不掉"白条"',
      );
      expect(
        visSrc.contains('ValueNotifier<bool>(false)'),
        isTrue,
        reason: '默认必须是 **false**（正常页面用浅色玻璃）',
      );
    });

    test('★★ `PlayerPage` 进入时必须置 true，且**退出必须复位**', () {
      /*
       * 这是"成对置位"类缺陷的典型：忘了复位 →
       * 用户进过播放页后返回首页，标题栏**一直是黑的**。
       *
       * 而且必须 `dispose` + `_exitPlayer` **两处都复位** ——
       * `dispose` 覆盖所有销毁路径（含 pushReplacement），
       * `_exitPlayer` 覆盖"主动返回"。
       */
      final sets = RegExp(r'titleBarDark\.value\s*=\s*true')
          .allMatches(playerSrc)
          .length;
      final resets = RegExp(r'titleBarDark\.value\s*=\s*false')
          .allMatches(playerSrc)
          .length;

      expect(sets, greaterThanOrEqualTo(1),
          reason: '★ `PlayerPage` 进入播放页时必须把标题栏转暗');
      expect(
        resets,
        greaterThanOrEqualTo(2),
        reason: '★★ 至少要有 **2 处**复位（`dispose` + `_exitPlayer`）—— '
            '漏了的话"进过播放页后返回首页标题栏一直是黑的"。'
            '当前只有 $resets 处。',
      );
      expect(
        resets,
        greaterThanOrEqualTo(sets),
        reason: '复位点不能少于置位点',
      );
    });

    test('★ `_CustomTitleBar` 必须接受并真的用上 `dark`', () {
      expect(
        shellSrc.contains('this.dark = false'),
        isTrue,
        reason: '`dark` 要有默认值 false（其它页面不受影响）',
      );
      expect(
        shellSrc.contains('_CustomTitleBar(') && shellSrc.contains('dark: isDark'),
        isTrue,
        reason: '★ `_TitleBarHost` 必须把 `titleBarDark` 的值传进去',
      );
      expect(
        shellSrc.contains('_titleBarRow('),
        isTrue,
        reason: '★ 浅色/深色两种外观必须**共用同一个内容行** —— '
            '各写一份很容易在深色态漏掉拖动区，'
            '那会重现用户抱怨过的"播放页无法拖动窗口"',
      );
    });

    test('★★ 深色态必须**保留拖动区**（用户明确要求过）', () {
      /*
       * 用户原话（`player_page.dart:602-604`）：
       * > 播放器页面没有顶部的那个可拖动 缩小 放大 关闭的那个操作条,
       * > 影响体验,在桌面端播放页面 无法拖动窗口
       *
       * 所以"修白条"**绝不能**通过隐藏标题栏来实现。
       */
      expect(
        shellSrc.contains('windowManager.startDragging()'),
        isTrue,
        reason: '★ 必须有拖动调用',
      );
      // 拖动区在共用的 _titleBarRow 里 → 两种外观都有
      final rowIdx = shellSrc.indexOf('Widget _titleBarRow(');
      expect(rowIdx, greaterThan(0), reason: '找不到 _titleBarRow');
      final row = shellSrc.substring(rowIdx, rowIdx + 2600);
      expect(
        row.contains('windowManager.startDragging()'),
        isTrue,
        reason: '★★ 拖动区必须在**共用**的 `_titleBarRow` 里 —— '
            '这样深色态（播放页）同样能拖窗口',
      );
      expect(
        row.contains('_WinButton('),
        isTrue,
        reason: '★ 三个窗口按钮（最小化/最大化/关闭）也必须在共用行里',
      );
    });

    test('★ 深色态不得再用 `GlassContainer`（黑底上会发灰）', () {
      /*
       * 液态玻璃是"折射背后内容"。背后是纯黑播放页时，
       * 它只会得到一条**发灰**的带子 —— 那正是用户说"有点丑"的来源。
       *
       * ⚠️ 断言范围必须**精确切出深色分支**。我第一版取了固定 700 字符，
       *    结果窗口越界进了**浅色分支**（那里本来就有 `GlassContainer`），
       *    报了一个假失败。
       */
      final darkIdx = shellSrc.indexOf('if (dark) {');
      expect(darkIdx, greaterThan(0), reason: '找不到深色分支');
      // 以浅色分支的注释作为结束锚点（结构上稳定）
      final lightIdx = shellSrc.indexOf('标题栏 = 开源包的', darkIdx);
      expect(lightIdx, greaterThan(darkIdx),
          reason: '找不到浅色分支的起始注释，无法界定深色分支范围');
      final darkBlock = shellSrc.substring(darkIdx, lightIdx);

      expect(
        darkBlock.contains('Colors.black'),
        isTrue,
        reason: '★ 深色态应直接用纯黑，与播放页无缝',
      );
      expect(
        darkBlock.contains('GlassContainer'),
        isFalse,
        reason: '★ 深色态**不要**用 GlassContainer —— '
            '黑底上液态玻璃会发灰，看起来更脏。'
            '（实测深色分支内容：${darkBlock.length} 字符）',
      );
    });

    test('★ `_WinButton` 必须支持自定义图标色（否则黑底黑图标）', () {
      /*
       * 深色态若不传图标色，会 fallback 到
       * `AppPalette.of(context).foreground` —— 浅色主题下那是**深色**，
       * 在纯黑标题栏上就是"黑底黑图标"，看不见。
       */
      expect(
        shellSrc.contains('final Color? iconColor'),
        isTrue,
        reason: '★ `_WinButton` 必须有 `iconColor` 参数',
      );
      expect(
        shellSrc.contains('widget.iconColor ??'),
        isTrue,
        reason: '★ 且必须真的用它',
      );
    });

    test('★ `_TitleBarHost` 必须监听 `titleBarDark`（否则不重建）', () {
      expect(
        shellSrc.contains('titleBarDark.addListener('),
        isTrue,
        reason: '★ 不监听就不会重建，转暗不会生效',
      );
      expect(
        shellSrc.contains('titleBarDark.removeListener('),
        isTrue,
        reason: '★ 有 add 必须有 remove（否则泄漏 + 回调打到已销毁的 State）',
      );
    });
  });
}
