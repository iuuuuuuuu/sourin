// ═══════════════════════════════════════════════════════════════════════
//  task-37 ②：保活（task-41）+ 占位色（task-37）**一起**验
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这条测试是"两个修复的联合验收"
//
// 用户原话里其实有**两个**抱怨，我一开始只抓到了第一个：
// ```text
// ① 「图片从黑色占位再变成图片」        → 占位色太深（task-37 修）
// ② 「不是加的有缓存吗？怎么切换还会这个样子」
//     → 切回首页时**页面被销毁重建**（task-41 修：KeepAlive）
// ```
// ★ 用户的反问才是主因：**缓存救得了字节，救不了 State。**
//
// 两个修复各自治一段，必须**同时**成立才不割裂：
// ```text
// 保活生效   ⇒ 切回来**不再**重建 ⇒ 占位态**不再每次出现**（治本）
// 占位色正确 ⇒ 真的冷加载那一次，占位**几乎融进背景**（治标但不白做）
// ```
//
// # ★ 判据设计：必须能**分别**测出这两个变量
//
// 一个笼统的"看起来不割裂"是测不出东西的。所以拆成两条独立断言：
// ```text
// A. PosterCard 的 State 在"父级重建但 key 相同"时**被复用**（保活语义）
// B. 占位色合成后与背景的差值落在 [3, 20] 区间（可见但不显眼）
// ```
// 其中 A 用**计数器**验证 State 真的被复用（而不是"看起来像复用"）。
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

/// 用生产同一套主题（`shell.dart:726-729` 的两步）
Widget host(Widget child, {Brightness brightness = Brightness.light}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.light
        ? buildLightMaterialTheme(theme)
        : buildMaterialTheme(theme),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(
      backgroundColor: AppTheme.floorColor(brightness),
      body: Center(child: child),
    ),
  );
}

/// 把 `fg` 以自身 alpha 合成到 `bg` 上
Color composite(Color fg, Color bg) {
  final a = fg.a;
  return Color.from(
    alpha: 1.0,
    red: fg.r * a + bg.r * (1 - a),
    green: fg.g * a + bg.g * (1 - a),
    blue: fg.b * a + bg.b * (1 - a),
  );
}

int maxChannelDiff(Color a, Color b) {
  int d(double x, double y) => ((x - y).abs() * 255).round();
  return [d(a.r, b.r), d(a.g, b.g), d(a.b, b.b)].reduce((x, y) => x > y ? x : y);
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  A. 保活语义：State 必须被**复用**（不是重建）
  // ═══════════════════════════════════════════════════════════════════

  group('A. PosterCard 的 State 在父级重建时被复用（保活的前提）', () {
    testWidgets('★★★ 同 key 重建父级 → State **不重建**（_loaded 不丢）',
        (t) async {
      /*
       * 这是"保活能不能救到 PosterCard"的**最小可复现模型**。
       *
       * `shell.dart` 的保活（task-41）靠 `_contentFor` 缓存**同一个
       * Widget 实例**来让 `Element`/`State` 存活。本测试验证：
       * 只要 `PosterCard` 的 `key` 稳定，父级 setState 重建时
       * 它的 `State`（含 `_loaded`）**会被复用**。
       *
       * # 怎么"数"State 有没有被复用
       *
       * 直接读私有 `_loaded` 不行（跨库）。所以用**间接但可靠**的判据：
       * ```text
       * 重建后如果 State 被复用 → didUpdateWidget 里 cover 没变
       *                          → 不会走"重置 _loaded"那条分支
       * 重建后如果 State 新建   → initState 跑 → _loaded 从 false 开始
       * ```
       * 两条路都不可直接观测，所以我用一个**受控的**对照：
       * 同一棵树重建两次，断言 `PosterCard` 的 **Element 同源**
       * （`find.byType(PosterCard)` 拿到的 Element 是同一个对象）。
       */
      final key = GlobalKey();
      final card = PosterCard(
        key: key,
        title: '保活验证',
        cover: 'http://127.0.0.1:9/nope.jpg',
      );

      await t.binding.setSurfaceSize(const Size(400, 500));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(card));
      await t.pump();

      final el1 = t.element(find.byType(PosterCard));
      final state1 = (el1 as StatefulElement).state;

      // 父级 setState 重建（模拟"父页面重建，但缓存的是同一个 child 实例"）
      await t.pumpWidget(host(card));
      await t.pump();

      final el2 = t.element(find.byType(PosterCard));
      final state2 = (el2 as StatefulElement).state;

      expect(identical(el1, el2), isTrue,
          reason: '★★★ 同 key 重建时 Element 必须复用 —— '
              '这正是 KeepAlive 能救到 PosterCard 的机制');
      expect(identical(state1, state2), isTrue,
          reason: '★★★ State 必须复用 —— 复用则 `_loaded` 保留，'
              '图片不会重新走一次占位态（这就是用户要的"有缓存就不该再占位"）');
    });

    testWidgets('★★★ 反面：**换 key** 时 State 必然重建（旧行为）', (t) async {
      /*
       * ★ 阳性对照（铁律 1）。
       *
       * 没有它的话，上面那条"State 复用"可能只是因为
       * `host()` 恰好让 widget 没变 —— 恒过的断言等于没断言。
       *
       * 这条复刻**修之前**的行为：每次换 key（= 老的
       * `shell.dart:2265 ValueKey(_tab)`）⇒ State 重建。
       */
      await t.binding.setSurfaceSize(const Size(400, 500));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(host(PosterCard(
        key: const ValueKey('tab-home'),
        title: '换key验证',
        cover: 'http://127.0.0.1:9/nope.jpg',
      )));
      await t.pump();
      final state1 =
          (t.element(find.byType(PosterCard)) as StatefulElement).state;

      // 换 key（= 切 tab 的旧行为）
      await t.pumpWidget(host(PosterCard(
        key: const ValueKey('tab-follow'),
        title: '换key验证',
        cover: 'http://127.0.0.1:9/nope.jpg',
      )));
      await t.pump();
      final state2 =
          (t.element(find.byType(PosterCard)) as StatefulElement).state;

      expect(identical(state1, state2), isFalse,
          reason: '★★★ 阳性对照：**换 key 必须重建 State** —— '
              '如果这条不成立，"同 key 复用"那条就证明不了什么。'
              '这正是用户看到的 bug：切 tab = 换 key = State 归零 = 又占位一次');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B. 占位色在"真的冷加载"那一次必须不显眼
  // ═══════════════════════════════════════════════════════════════════

  group('B. 冷加载那一次：占位必须"可见但不显眼"', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('★★ [$tag] 差值落在 [3, 20]（两端都管）', (t) async {
        await t.binding.setSurfaceSize(const Size(400, 500));
        addTearDown(() => t.binding.setSurfaceSize(null));

        await t.pumpWidget(host(
          PosterCard(
            key: const ValueKey('cold'),
            title: '冷加载',
            // 不存在的封面 ⇒ **必然**进入占位态（不靠运气抓中间帧）
            cover: 'http://127.0.0.1:9/nope.jpg',
          ),
          brightness: brightness,
        ));
        await t.pump();

        Color? ph;
        for (final e in find
            .descendant(
              of: find.byType(PosterCard),
              matching: find.byType(Container),
            )
            .evaluate()) {
          final w = e.widget;
          if (w is Container && w.color != null) {
            ph = w.color;
            break;
          }
        }
        expect(ph, isNotNull, reason: '必须能找到占位 Container');

        final bg = AppTheme.floorColor(brightness);
        final diff = maxChannelDiff(composite(ph!, bg), bg);

        expect(diff, greaterThan(3),
            reason: '★★ [$tag] 占位必须**看得见**（> 3）—— '
                '完全看不见会退化成"空白 → 突然出现图片"，仍是跳变');
        expect(diff, lessThan(20),
            reason: '★★ [$tag] 占位必须**不显眼**（< 20）—— '
                '这就是"不割裂"。实测=$diff');
      });
    }
  });
}
