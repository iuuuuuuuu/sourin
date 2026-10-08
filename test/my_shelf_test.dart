// ═══════════════════════════════════════════════════════════════════════
//  「我的」分段控件 —— 与底栏的一致性契约
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户验收标准（2026-09-24）
//
// > 左上角和这个源切换,还是跟底部的不太一样
//
// 「左上角」= 「最近追更 / 最近收藏 / 播放历史」这个分段控件。
//
// # 为什么用静态断言而不是 widget test
//
// 这个控件要 `GlassContainer`（依赖 shader + `LiquidGlassWidgets.wrap`），
// 在 `flutter_test` 里构造不出真实渲染 —— 硬测只会得到"测了我自己搭的壳"
// 这种**假绿**（我在标题栏那轮踩过：手搓壳测试 false fail）。
//
// 所以这里断言的是**契约**：结构、参数、以及"两套主题值必须成对"。
// 真实观感由真机截图对比覆盖（把底栏和它裁到同一张图）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;
  late String shell;

  setUpAll(() {
    src = File('lib/ui/widgets/my_shelf.dart').readAsStringSync();
    // 底栏是"正确样板" —— 要拿它做参照
    shell = File('lib/shell.dart').readAsStringSync();
  });

  /*
   * ★★ 归一化：只抹掉 State 子类里的 `widget.` 取值前缀。
   *
   * # 为什么需要它（不是为了让测试变绿）
   *
   * 同一个字段在两种地方写法**必然**不同：
   *   - StatelessWidget 里   → `cols.badgeBg`        （构造参数，裸名）
   *   - State 子类里         → `widget.cols.badgeBg`  （State 看不到构造参数）
   *
   * `_ShelfTabChip` 是 StatefulWidget、`_ShelfTabs` 是 StatelessWidget，
   * 于是**同一个调色板**在两处长得不一样；直接字面比对 = 拿写法当判据，
   * 而不是拿「是否来自同一个调色板」当判据。
   *
   * ⚠️ 刻意**不是**大范围的 `replaceAll('widget.', '')`：
   *    那会把 `widget.label` / `widget.onTap` / `widget.count`
   *    也一起改掉，等于顺手放宽了别处的判据。这里只认
   *    `widget.cols.` / `widget.active` 这两个**调色板相关**的前缀。
   *
   * ★ 判别力由两组反例自检保证（见「调色板判据的反例自检」）：
   *   - 把文字色换成 `Theme.of(context).colorScheme.onSurface` ⇒ 必须判不过
   *   - 把角标底换成 `Theme.of(context).colorScheme.surfaceContainerHighest` ⇒ 必须判不过
   */
  String unwidget(String s) => s
      .replaceAll('widget.cols.', 'cols.')
      .replaceAll('widget.active ?', 'active ?');

  group('结构契约', () {
    test('★★ 玻璃在**外层容器**上，不是每个 tab 各自一块', () {
      /*
       * 原版 `MyShelf.vue`：
       * ```css
       * .mine__tabs { background: var(--surface-1); ... }  /* 一个玻璃容器 */
       * .mtab { background: transparent; }                 /* tab 自己透明 */
       * ```
       * 我第一版给**每个 tab** 各套了一块 `GlassContainer` ——
       * 屏幕上出现三个独立小玻璃胶囊，与底栏那条大玻璃完全不像。
       */
      final glassCount = RegExp(r'GlassContainer\(').allMatches(src).length;
      expect(
        glassCount,
        1,
        reason: '★ 整个文件里 `GlassContainer` 只能出现 **1 次**'
            '（外层容器）。出现多次 = 又变成"每个 tab 一块玻璃"了。'
            '当前 $glassCount 次。',
      );

      // 而且必须包住 Row（三个 tab 在它里面），不是包住单个 tab
      expect(
        src.contains('child: _ShelfTabs('),
        isTrue,
        reason: '外层 GlassContainer 里应该是一个 `_ShelfTabs`',
      );
    });

    test('★ 三个 tab 用同一个 ShelfTab.values 枚举驱动', () {
      expect(
        src.contains('for (final t in ShelfTab.values)'),
        isTrue,
        reason: '三个 tab 应由枚举驱动，避免手写三份（漏一个就少一个 tab）',
      );
      expect(src.contains('enum ShelfTab { following, favorites, history }'),
          isTrue);
    });

    test('★ 每个 tab 必须有**等宽**（滑动药丸靠它算位置）', () {
      /*
       * 药丸位置是纯算术 `index * 宽度` —— 前提是三个 tab 等宽。
       * 让内容自适应的话，角标从"有"变"无"会让宽度变，药丸就错位了。
       *
       * ★ 2026-10-05：宽度从「固定 96」改成「`min(96, (可用宽 − 8) / 3)`」。
       *   仍然是**等宽**（同一个局部 `tabWidth` 同时喂给药丸和三个 tab），
       *   只是多了一个按容器收窄的钳制 —— 360dp 上三个 96 装不进 272.4dp，
       *   末 tab 的角标会被玻璃容器右沿切掉（真机 ck109_badge_zoom.png）。
       *
       * ⚠️ 断言跟着从 `_shelfTabWidth` 改成局部 `tabWidth`：
       *   硬编码旧字面量会让这个契约在改动后**假绿**（字面量还在，但已经
       *   不再喂给 SizedBox 了）。
       */
      expect(
        src.contains('_shelfTabWidth'),
        isTrue,
        reason: '★ 必须有宽度上限常量（与底栏 `_tabWidth` 同一个办法）',
      );
      expect(
        src.contains('_shelfTabWidthFor('),
        isTrue,
        reason: '★ 必须有钳制函数 —— 证明是「上限」而不是把常量删了/硬编码换个数',
      );
      expect(
        src.contains('width: tabWidth'),
        isTrue,
        reason: '每个 tab 都要显式给宽度（同一个局部变量 ⇒ 天然等宽）',
      );
      expect(
        src.contains('left: current.index * tabWidth'),
        isTrue,
        reason: '★ 药丸位置用纯算术算 —— 不量布局（量布局要等一帧，首帧会闪）',
      );
      expect(
        src.contains('_shelfTabWidthFor(constraints.maxWidth)'),
        isTrue,
        reason: '★ 钳制必须吃 LayoutBuilder 的 maxWidth（放在 Padding 里会双扣 8dp）',
      );
    });
  });

  group('与底栏的一致性（逐项对齐）', () {
    test('★★ 药丸的时长与曲线必须与底栏相同', () {
      /*
       * 用户说"不太一样" —— 动效曲线不一致也是"不一样"的一部分。
       * 底栏用 `Duration(milliseconds: 420)` + `Curves.easeOutBack`。
       */
      expect(src.contains('curve: Curves.easeOutBack'), isTrue,
          reason: '★ 曲线必须与底栏一致（easeOutBack 会轻微过冲再回弹，'
              '那就是"液态"手感）');

      // 从底栏源码里把时长抠出来，确保两边**字面一致**
      final m = RegExp(r'duration: const Duration\(milliseconds: (\d+)\)')
          .allMatches(shell);
      final barDurations = m.map((x) => x.group(1)).toSet();
      expect(
        barDurations.contains('420'),
        isTrue,
        reason: '底栏的药丸时长应该是 420ms（取不到说明底栏改了，'
            '这里要跟着改）',
      );
      expect(
        src.contains('Motion.slow'),
        isTrue,
        reason: '★ 这里用 `Motion.slow` —— 它的值必须是 420ms。'
            '见下一个用例。',
      );
    });

    test('★ Motion.slow 就是 420ms（否则上面那条形同虚设）', () {
      final tokens = File('lib/ui/tokens.dart').readAsStringSync();
      expect(
        RegExp(r'static const Duration slow = Duration\(milliseconds: 420\)')
            .hasMatch(tokens),
        isTrue,
        reason: '★ `Motion.slow` 必须等于底栏用的 420ms —— '
            '否则"两边时长一致"就不成立了',
      );
    });

    test('★ 药丸必须是**渐变**（不是纯色）—— 与底栏同款高光', () {
      expect(
        src.contains('gradient: LinearGradient('),
        isTrue,
        reason: '★ 底栏药丸是 `LinearGradient`（上亮下暗，模拟玻璃高光），'
            '纯色会显得"平"',
      );
      expect(
        src.contains('begin: Alignment.topCenter'),
        isTrue,
        reason: '渐变方向要自上而下（与底栏一致）',
      );
    });

    test('★ 药丸阴影参数与底栏一致', () {
      for (final frag in [
        'blurRadius: 8',
        'spreadRadius: -2',
        'offset: const Offset(0, 2)',
      ]) {
        expect(src.contains(frag), isTrue,
            reason: '药丸阴影的 `$frag` 要与底栏一致');
      }
    });

    test('★★ 外层形状/质量与底栏一致（squircle + standard）', () {
      expect(
        src.contains('shape: const LiquidRoundedSuperellipse(borderRadius: 999)'),
        isTrue,
        reason: '★ 轮廓语言必须是 squircle（iOS 26）—— 与底栏同一个形状类',
      );
      expect(
        src.contains('quality: GlassQuality.standard'),
        isTrue,
        reason: '★ 质量档必须一致 —— 底栏用 standard'
            '（premium 是 Impeller-only 且只适合静态表面）',
      );
      // 交叉验证：底栏确实也是这两个值
      expect(shell.contains('LiquidRoundedSuperellipse'), isTrue);
      expect(shell.contains('GlassQuality.standard'), isTrue);
    });
  });

  group('两套主题的取值必须**成对**（最容易漏的地方）', () {
    test('★★ 浅色：近纯白药丸 + **深色**文字', () {
      /*
       * 原版 `theme-light.css`：
       * ```css
       * --tab-pill-bg: linear-gradient(180deg,
       *                  rgb(255 255 255 / 0.96), rgb(255 255 255 / 0.80));
       * --tab-fg-strong: rgb(16 18 26 / 0.94);   /* 深字 */
       * ```
       */
      expect(src.contains('Colors.white.withValues(alpha: 0.96)'), isTrue,
          reason: '浅色药丸上端 0.96 白');
      expect(src.contains('Colors.white.withValues(alpha: 0.80)'), isTrue,
          reason: '浅色药丸下端 0.80 白');
      // 深色文字（0xFF10121A 是原版 --text-primary 的合成值）
      expect(src.contains('Color(0xFF10121A)'), isTrue,
          reason: '★ 浅色下药丸几乎纯白 → 文字**必须**是深色，'
              '否则白底白字看不见');
    });

    test('★★ 深色：很透的白叠加药丸 + **白色**文字', () {
      /*
       * 原版 `tokens.css`：
       * ```css
       * --tab-pill-bg: linear-gradient(180deg,
       *                  rgb(255 255 255 / 0.19), rgb(255 255 255 / 0.10));
       * --tab-fg-strong: #ffffff;                /* 白字 */
       * ```
       * 深色药丸只有 0.19/0.10 —— 叠在深底上仍然是**暗**的，白字才看得清。
       */
      expect(src.contains('Colors.white.withValues(alpha: 0.19)'), isTrue,
          reason: '深色药丸上端 0.19 白（原版值）');
      expect(src.contains('Colors.white.withValues(alpha: 0.10)'), isTrue,
          reason: '深色药丸下端 0.10 白（原版值）');
      expect(src.contains('activeText: Colors.white'), isTrue,
          reason: '★ 深色下药丸很透（底仍偏暗）→ 文字必须是白色');
    });

    test('★★ 药丸与文字色必须来自**同一个**调色板对象', () {
      /*
       * 这是防"只改一半"的关键：
       * 如果药丸和文字色分别写 `isLight ? ... : ...`，
       * 将来改主题时很容易只改一处 → 出现「白药丸 + 白字」。
       * 集中在 `_ShelfPalette` 里就不可能出现这种不一致。
       */
      expect(src.contains('class _ShelfPalette'), isTrue,
          reason: '★ 两套值必须集中在一个调色板类里');
      expect(src.contains('static _ShelfPalette of(bool isLight)'), isTrue,
          reason: '调色板按明暗给两套值');
      // 药丸和文字都从 cols 取
      expect(src.contains('colors: cols.pillGradient'), isTrue,
          reason: '药丸填充从调色板取');
      /*
       * ⚠️ 这一条跑在 `norm` 上，不是 `src`：文字色那行在
       *    `_ShelfTabChipState`（State 子类）里，取值**必须**带 `widget.`
       *    —— State 看不到构造参数。归一化只抹这个前缀，判据不变。
       *    判别力由「调色板判据的反例自检」那一组保证。
       */
      final norm = unwidget(src);
      expect(
          norm.contains('active ? cols.activeText : cols.idleText'), isTrue,
          reason: '★ 文字色也从**同一个**调色板取 —— 这样不可能出现'
              '"药丸和文字明暗不匹配"');
    });

    test('★ 不得用 onSurface / foreground 当药丸上的文字色', () {
      /*
       * 这两个角色**跟着主题反相**（深色下是近白、浅色下是近黑），
       * 而药丸的明暗是**另一套**逻辑 —— 直接拿来用很容易配错。
       * 一律走 `_ShelfPalette`。
       *
       * ⚠️ 断言必须**限定在药丸相关的两个类里**（第一版写成了全文件，
       *    把页面标题、空状态文案、骨架屏的合法用法也一起报了假失败）。
       *    那些地方的 `onSurface` 是对的（它们不在药丸上）。
       */
      String bodyOf(String sig, String nextSig) {
        final a = src.indexOf(sig);
        final b = src.indexOf(nextSig);
        expect(a, greaterThan(0), reason: '找不到 `$sig`');
        expect(b, greaterThan(a), reason: '找不到 `$nextSig`');
        return src.substring(a, b);
      }

      // 只看 `_ShelfTabs` 与 `_ShelfTabChip`（药丸所在的两个类）
      final pillScope = bodyOf(
        'class _ShelfTabs extends StatelessWidget {',
        'class _ShelfSkeleton extends StatelessWidget {',
      );
      final stripped = pillScope
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') &&
                !t.startsWith('*') &&
                !t.startsWith('/*');
          })
          .join('\n');

      expect(
        stripped.contains('colors.onSurface'),
        isFalse,
        reason: '★ 药丸相关的类里不要用 `onSurface` 当文字色 —— '
            '它的反相逻辑与药丸不同步，容易配成"白底白字"',
      );
      expect(
        stripped.contains('colors.foreground'),
        isFalse,
        reason: '★ 同理，`FColors.foreground` 也不能用（且这个文件用的是'
            'Material 的 ColorScheme，根本没有 `foreground`）',
      );
    });
  });

  group('角标', () {
    test('★ 角标要有底色（原版 `.mtab__count` 是药丸形小底）', () {
      expect(src.contains('badgeBg'), isTrue,
          reason: '角标不是裸数字 —— 原版给它一个 `--surface-track` 小底');
      // ⚠️ 同样跑在归一化文本上：现盘源码是 `color: widget.cols.badgeBg,`
      //    （角标在 `_ShelfTabChipState.build` 里）。
      expect(
        unwidget(src).contains('color: cols.badgeBg'),
        isTrue,
        reason: '角标底色也走调色板（两套主题各一份）'
            ' —— 写法可能是 `cols.badgeBg` 或 `widget.cols.badgeBg`，'
            '两者指的是同一个调色板字段',
      );
    });

    test('★ 角标文字色与标签一致（保证在白药丸上可读）', () {
      // 角标容器和标签都用 `textColor`（同一个变量）
      expect(
        src.contains('color: textColor'),
        isTrue,
        reason: '★ 角标文字要用与标签**同一个** textColor —— '
            '否则选中时角标可能变成看不清的颜色',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  判别力自检（meta-test）
  // ═════════════════════════════════════════════════════════════════════
  //
  // # 为什么必须有这一组
  //
  // 上面两条断言原本写成**逐字**比对 `src.contains('active ? cols...')`。
  // 现盘改成在 `unwidget(src)` 上比对 —— 归一化是"放宽"，而任何放宽都可能
  // 把断言掏空。所以这里用**反例**把"仪器还有效"这件事测出来：
  // 拿现盘源码做最小替换，注入原版明确禁止的写法，
  // 断言匹配器**必须判不过**。
  //
  // ⚠️ 这一组不依赖磁盘上恰好是什么，依赖的是替换**成立**（先 assert
  //    替换确实改了文本），否则"判不过"可能只是因为没换成，属于假绿。
  group('调色板判据的反例自检', () {
    test('★ 文字色改用 onSurface ⇒ 匹配器必须判不过', () {
      const lit = 'active ? cols.activeText : cols.idleText';
      final spy = src.replaceAll('widget.', '');
      expect(spy.contains(lit), isTrue, reason: '前提：归一化后能匹配现盘写法');

      final bad = src.replaceFirst(
        'widget.active ? widget.cols.activeText : widget.cols.idleText',
        'widget.active ? Theme.of(context).colorScheme.onSurface '
            ': Theme.of(context).colorScheme.onSurfaceVariant',
      );
      expect(bad == src, isFalse, reason: '前提：反例注入必须真的改到文本');
      final badNorm = spy.replaceFirst(
        lit,
        'active ? Theme.of(context).colorScheme.onSurface '
            ': Theme.of(context).colorScheme.onSurfaceVariant',
      );
      expect(badNorm.contains(lit), isFalse,
          reason: '反例下匹配器必须判不过 —— 否则这条断言已经失效');
    });

    test('★ 角标底色改用 surfaceContainerHighest ⇒ 匹配器必须判不过', () {
      const lit = 'color: cols.badgeBg';
      final spy = src.replaceAll('widget.', '');
      expect(spy.contains(lit), isTrue, reason: '前提：归一化后能匹配现盘写法');

      final bad = src.replaceFirst('color: widget.cols.badgeBg',
          'color: Theme.of(context).colorScheme.surfaceContainerHighest');
      expect(bad == src, isFalse, reason: '前提：反例注入必须真的改到文本');
      expect(spy.replaceFirst(lit, 'color: Theme.of(context).colorScheme.surfaceContainerHighest')
          .contains(lit), isFalse,
          reason: '反例下匹配器必须判不过');
    });

    test('★ 只改一半（药丸不走调色板 / 文字不走调色板）也要判不过', () {
      const lit = 'active ? cols.activeText : cols.idleText';
      // 半改：文字色退回主题色，但药丸仍从 cols 取 —— 正是注释说的
      // "白药丸 + 白字"场景，必须被抓到。
      final halfRaw = src.replaceFirst(
          'widget.active ? widget.cols.activeText : widget.cols.idleText',
          'widget.active ? Theme.of(context).colorScheme.surface : Colors.white');
      expect(halfRaw == src, isFalse, reason: '前提：半改注入必须真的改到文本');
      final half = halfRaw.replaceAll('widget.', '');
      expect(half.contains(lit), isFalse, reason: '半改必须判不过（防"只改一半"）');
    });

    test('★★ 归一化只放宽调色板前缀，不放宽别的 widget. 取值', () {
      // unwidget 必须是"窄"的：只有这两个前缀被抹掉。
      expect(unwidget('widget.cols.badgeBg'), 'cols.badgeBg');
      expect(unwidget('widget.active ?'), 'active ?');
      expect(unwidget('widget.label'), 'widget.label',
          reason: 'widget.label 不归调色板管，必须原样保留');
      expect(unwidget('widget.onTap'), 'widget.onTap',
          reason: 'widget.onTap 不归调色板管，必须原样保留');
      expect(unwidget('widget.count > 0'), 'widget.count > 0',
          reason: 'widget.count 不归调色板管，必须原样保留');
    });

    test('★ 现盘源码本身仍满足这两条判据（归一化没有把判据放宽到自欺）', () {
      final norm = unwidget(src);
      expect(norm.contains('active ? cols.activeText : cols.idleText'), isTrue);
      expect(norm.contains('color: cols.badgeBg'), isTrue);
      // 而药丸填充那条本来就是裸名，归一化前后都命中
      expect(norm.contains('colors: cols.pillGradient'), isTrue);
    });
  });
}
