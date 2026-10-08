// ═══════════════════════════════════════════════════════════════════════
//  task-37：首页海报「黑色占位 → 图片」跳变 —— 占位色必须与背景几乎无差
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
//
// > 切换首页的时候图片从黑色占位再变成图片  体验割裂
//
// # ★★★ 本文件守的核心判据：**合成后与背景的差值**
//
// 只看"占位色是什么值"是**测不出**这个 bug 的：
// ```text
// 旧值 #23262E  「是一个深色」        ← 这个描述本身没错，但它不是判据
// 新值 5% 前景色 「是一个半透明色」    ← 也不是判据
// ```
// 真正的判据是用户看到的东西：**占位块与它周围背景的差异**。
// 因为"割裂"的来源不是"颜色深"，而是"**与背景差得多**"。
//
// ⇒ 所以本文件把占位色**合成到页面底色上**，再断言差值：
// ```text
// 旧值 #23262E 叠在浅色背景 #EEF0F6 上 → 差值 ≈ 203/202/200  ★ 一块近黑方块
// 新值 onSurface 5% 叠在同一背景上     → 差值 ≈  10/ 10/ 10  ★ 几乎重合
// ```
// 这两者**相差一个数量级**，断言能干净地把它们分开。
//
// # ★★ 为什么不靠"抓图片未加载的那一帧"
//
// 那种做法有两个假阴性来源：
// ```text
// ① 机器够快 ⇒ 根本抓不到中间帧 ⇒ "没抓到" 会被误读成 "没问题"
// ② 要判断"这块像素属于占位还是属于图片" ⇒ 还得猜
// ```
// ⇒ 本文件改用**确定性**手段：
// ```text
// ① 直接读 widget 树里那个占位 Container 的 color（纯 Dart 层，无需渲染）
// ② 用**不存在的 URL** 强制进入占位态（必然发生，不靠运气）
// ```
//
// # 原版依据（`D:\WishProject\cctv_to_client\src\`）
//
// ```css
// /* design/base.css:734 —— 深色（默认） */
// .poster { background: rgb(255 255 255 / 0.05); }
//
// /* design/theme-light.css:220 —— 浅色主题只改这一条 */
// :root[data-theme="light"] .poster { background: rgb(16 18 26 / 0.05); }
// ```
// ★ 两条都是 **5%**，只是"叠在什么上面"不同 ⇒ 原版占位**永远与背景只差 5%**。
//   这就是"不割裂"的机制，也是本文件断言的依据。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

/*
 * ⚠️ task-58：DetailPage 已不再是**独立页面**（Owner 裁决③），
 *    它现在由 MediaPage 嵌在下半屏（embedded: true）。
 *    ⇒ 本文件断言的契约**仍然成立**且仍在产品路径上（不是假绿）。
 *    而它被挂在正确的地方由 	est/t58_media_page_test.dart 的 group ③ 守着。
 */


// ═══════════════════════════════════════════════════════════════════════
//  颜色工具
// ═══════════════════════════════════════════════════════════════════════

/// 把 `fg` 以 `alpha` 合成到 `bg` 上（标准的 source-over 合成）
///
/// ⚠️ 这是本文件的核心工具，它必须**可自证**（见 ⓪ 组的阳性对照）：
///    如果它算错了，"差值很小"这个结论就是空的。
Color composite(Color fg, Color bg) {
  final a = fg.a; // Flutter 3.27+：Color.a 是 0..1 的 double
  return Color.from(
    alpha: 1.0,
    red: fg.r * a + bg.r * (1 - a),
    green: fg.g * a + bg.g * (1 - a),
    blue: fg.b * a + bg.b * (1 - a),
  );
}

/// 两个颜色在 RGB 三通道上的**最大**差值（0..255）
///
/// 用"最大值"而不是"平均值"：只要有一个通道差得多，人眼就看得出色块。
int maxChannelDiff(Color a, Color b) {
  int d(double x, double y) => ((x - y).abs() * 255).round();
  return [d(a.r, b.r), d(a.g, b.g), d(a.b, b.b)].reduce((x, y) => x > y ? x : y);
}

/// 把 0..1 的浮点通道转成 0..255 整数（打印用）
String hex255(Color c) {
  int q(double v) => (v * 255).round().clamp(0, 255);
  return '#${q(c.r).toRadixString(16).padLeft(2, '0')}'
      '${q(c.g).toRadixString(16).padLeft(2, '0')}'
      '${q(c.b).toRadixString(16).padLeft(2, '0')}';
}

/// 用**生产同一套**主题构造（`shell.dart:726-729` 的那两步）
///
/// ⚠️ 不能只用 `FTheme.neutral.light.desktop` —— 那会跳过
///    `buildLightMaterialTheme` / `buildMaterialTheme`，
///    于是 `Theme.of(context).colorScheme.onSurface` 拿到的是
///    forui 的中性兜底值，**不是用户看到的那个**。
///    （task-32 踩过同一个坑：浅色下 primary 变成近黑而不是品牌蓝。）
Widget host(Widget child, {required Brightness brightness}) {
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

/// 从渲染树里取出「占位」那个 `Container` 的颜色
///
/// 判据：`PosterCard` 里带 `BoxDecoration`/`color` 且**尺寸等于海报区域**
/// 的那个 `Container`。用"它是 `Container` 且 color 非空且不是 InkWell 的
/// 高亮"来定位。
///
/// ★ 更稳的做法：占位是 `Stack` 里**第一个**子节点（见 poster_card.dart 的
///   `Stack(children: [占位, 图片, ...])`）。这里按 widget 树的顺序取第一个
///   带纯色的 `Container`，正是它。
Color? placeholderColorOf(WidgetTester t) {
  final containers = find
      .descendant(
        of: find.byType(PosterCard),
        matching: find.byType(Container),
      )
      .evaluate();

  for (final e in containers) {
    final w = e.widget;
    if (w is Container && w.color != null) return w.color;
  }
  return null;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检 —— 先证明工具本身是对的（铁律 1：阳性对照）
  // ═══════════════════════════════════════════════════════════════════

  group('⓪ 仪器自检（证明颜色工具不是恒真/恒假）', () {
    test('★ composite 半透明合成是对的（拿已知值对照）', () {
      // 50% 黑 叠 纯白 = 中灰 #808080（±1）
      final mid = composite(
        const Color(0xFF000000).withValues(alpha: 0.5),
        const Color(0xFFFFFFFF),
      );
      expect(maxChannelDiff(mid, const Color(0xFF808080)), lessThanOrEqualTo(1),
          reason: '★ 50% 黑叠白必须≈中灰 —— 这条不过的话，'
              '后面所有"合成后差值"的结论都作废');

      // alpha=0 ⇒ 完全等于背景
      final none = composite(
        const Color(0xFF000000).withValues(alpha: 0.0),
        const Color(0xFFEEF0F6),
      );
      expect(maxChannelDiff(none, const Color(0xFFEEF0F6)), 0,
          reason: 'alpha=0 必须与背景完全相同');
    });

    test('★★ 判据能**区分**旧值和正确值（否则等于没断言）', () {
      /*
       * 这是整个文件的元判据：如果"旧的深色"和"新的 5%"算出来的
       * 差值差不多，那我的断言就是在测空气。
       */
      const bg = Color(0xFFEEF0F6); // LightTokens.bgBase
      const oldColor = Color(0xFF23262E); // 修之前的硬编码深色
      final newColor = const Color(0xFF1E2028).withValues(alpha: 0.05);

      final oldDiff = maxChannelDiff(composite(oldColor, bg), bg);
      final newDiff = maxChannelDiff(composite(newColor, bg), bg);

      // ignore: avoid_print
      print('[T37] 浅色背景 ${hex255(bg)}：\n'
          '        旧 #23262E 合成 → ${hex255(composite(oldColor, bg))}  '
          '差值=$oldDiff\n'
          '        新 5%    合成 → ${hex255(composite(newColor, bg))}  '
          '差值=$newDiff');

      expect(oldDiff, greaterThan(100),
          reason: '★ 旧值必须是一个**明显**的色块（差值 > 100）—— '
              '否则用户不会报"黑色占位"');
      expect(newDiff, lessThan(20),
          reason: '★ 新值必须几乎融进背景（差值 < 20）');
      expect(oldDiff, greaterThan(newDiff * 5),
          reason: '★★ 两者必须差 5 倍以上 ⇒ 断言真的能区分它们'
              '（旧=$oldDiff 新=$newDiff）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 占位色随主题变（核心验收⑥）
  // ═══════════════════════════════════════════════════════════════════

  group('① 占位色必须与背景几乎无差（两套主题都验）', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('★★ [$tag] 占位合成后的差值 < 20', (t) async {
        await t.binding.setSurfaceSize(const Size(900, 700));
        addTearDown(() => t.binding.setSurfaceSize(null));

        await t.pumpWidget(
          host(
            /*
             * ★ 故意用**不存在的 URL** 强制进入占位态
             *
             * 这样"占位态"是**必然**出现的，不依赖"机器够慢能抓到中间帧"
             * 那种碰运气的方式（那是假阴性的温床）。
             * `errorBuilder` 会返回 `SizedBox.shrink()`，占位 Container 仍然在。
             */
            const PosterCard(
              title: '不存在的封面测试',
              cover: 'http://127.0.0.1:9/never-exists-task37.jpg',
            ),
            brightness: brightness,
          ),
        );
        await t.pump();

        final ph = placeholderColorOf(t);
        expect(ph, isNotNull,
            reason: '★ 必须能找到占位 Container（找不到说明选择器失效，'
                '后面的结论全部作废）');

        final bg = AppTheme.floorColor(brightness);
        final composited = composite(ph!, bg);
        final diff = maxChannelDiff(composited, bg);

        // ignore: avoid_print
        print('[T37] $tag 背景=${hex255(bg)} 占位=${hex255(ph)} '
            '(alpha=${ph.a.toStringAsFixed(2)}) '
            '合成=${hex255(composited)} 差值=$diff');

        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 必须是**双侧**断言 —— 这是 red-proof 抓出来的一个真缺口
         * ══════════════════════════════════════════════════════════════
         *
         * 我第一版只写了 `diff < 20`（单侧）。red-proof 的 M5 把
         * alpha 改成 `0.0` —— **测试全绿**。
         *
         * 为什么那是错的：`alpha=0` 意味着占位**完全不可见**，
         * 用户看到的是"**空白 → 突然出现图片**"。那不仅没修好，
         * 反而更糟 —— 原版刻意留 5% 就是为了给用户一个
         * "这里会有一张图"的**微弱提示**（骨架屏的基本作用）。
         *
         * ⇒ 正确判据是**区间**，两端都要管：
         * ```text
         * 下界：必须**看得见**（否则退化成"空白→图片"，仍是跳变）
         * 上界：必须**不成块**（否则就是用户报的"黑色占位"）
         * ```
         * 原版的 5% 落在这个区间正中（实测浅色 10、深色 12）。
         */
        const lowerBound = 3; // 低于此值 ≈ 肉眼不可见
        const upperBound = 20; // 高于此值 ≈ 明显的色块

        expect(diff, greaterThan(lowerBound),
            reason: '★★ [$tag] 占位必须**看得见**（差值 > $lowerBound）—— '
                'alpha=0 会让它完全不可见，用户看到的是"空白 → 突然出现图片"，'
                '那仍是跳变（且比原版更糟：没有"图要来"的提示）。'
                '实测差值=$diff');

        expect(diff, lessThan(upperBound),
            reason: '★★ [$tag] 占位必须**不成块**（差值 < $upperBound）—— '
                '这正是"不割裂"的判据。实测差值=$diff\n'
                '背景=${hex255(bg)} 占位=${hex255(ph)} 合成=${hex255(composited)}');

        // ③ 不透明度本身也要落在原版给出的量级上（5%）
        expect(ph.a, greaterThanOrEqualTo(0.03),
            reason: '★ 不透明度太低下界（原版是 0.05）');
        expect(ph.a, lessThanOrEqualTo(0.12),
            reason: '★ 不透明度太高上界（原版是 0.05）—— '
                '再高就重新变成肉眼可见的色块');
      });

      testWidgets('★★★ [$tag] 反面：把占位换回旧的硬编码深色，差值必然很大',
          (t) async {
        /*
         * ★ 阳性对照（铁律 1）。
         *
         * 没有它的话，上面那条"差值 < 20"可能只是因为
         * `placeholderColorOf` 取错了 widget（比如取到了透明的那个），
         * 于是任何输入都"通过"。
         *
         * 做法：用同一个选择器去取一个**故意画成旧颜色**的占位，
         * 确认它算出来的差值**很大** ⇒ 选择器真的取到了占位块。
         */
        await t.binding.setSurfaceSize(const Size(900, 700));
        addTearDown(() => t.binding.setSurfaceSize(null));

        await t.pumpWidget(
          host(
            // 用同一结构、但占位是旧的深色 —— 模拟"修之前"
            SizedBox(
              width: AppMetrics.posterWidth,
              child: AspectRatio(
                aspectRatio: AppMetrics.posterAspect,
                child: ClipRRect(
                  borderRadius: Radii.rMd,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: const Color(0xFF23262E)), // 旧值
                    ],
                  ),
                ),
              ),
            ),
            brightness: brightness,
          ),
        );
        await t.pump();

        final containers = find.byType(Container).evaluate();
        Color? oldPh;
        for (final e in containers) {
          final w = e.widget;
          if (w is Container && w.color != null) {
            oldPh = w.color;
            break;
          }
        }
        expect(oldPh, isNotNull);

        final bg = AppTheme.floorColor(brightness);
        final diff = maxChannelDiff(composite(oldPh!, bg), bg);

        /*
         * ★★★ 阈值必须**按主题分开** —— 这是一个真实的发现，不是将就
         *
         * 实测（本测试第一次跑出来的）：
         * ```text
         * 浅色：旧 #23262E 叠 #EEF0F6 → 差值 203   ★ 一块近黑方块
         * 深色：旧 #23262E 叠 #0A0A0A → 差值  36   ← 只有 36！
         * ```
         * 原因：`#23262E` 本身就是**深色**（RGB 35/38/46），
         * 它跟深色背景 `#0A0A0A`（10/10/10）本来就近。
         *
         * ⇒ ★★ **这个 bug 是"浅色主题专属"的。**
         *   用户的实际设置是 `"dsh.theme":"system"` + 系统浅色
         *   （`ui-prefs.json` + `AppsUseLightTheme=1`），
         *   所以他看到的正是那 203 的版本 —— 与他的抱怨吻合。
         *   在深色主题下这个 bug **几乎看不出来**。
         *
         * ⇒ 所以对照阈值要分开写，否则要么在深色下假失败、
         *   要么为了迁就深色而把浅色的判据放松（那才是真的危险）。
         */
        final threshold = brightness == Brightness.light ? 100 : 25;

        expect(diff, greaterThan(threshold),
            reason: '★★★ [$tag] 阳性对照：旧的 #23262E 必须算出**大**差值 —— '
                '否则说明判据测不出"深色块"。'
                '实测差值=$diff（阈值 $threshold；'
                '浅色下这个 bug 是 203，深色下只有 36 —— '
                '**本 bug 是浅色主题专属**）');
      });
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 静态审计：源码里不能再出现硬编码占位色
  // ═══════════════════════════════════════════════════════════════════

  group('② 静态审计（防止硬编码色回归）', () {
    /// 剥注释（本项目已踩 7 次"grep 命中注释导致假通过"）
    String stripComments(String src) {
      final out = StringBuffer();
      var i = 0;
      String? quote;
      while (i < src.length) {
        final c = src[i];
        final n = i + 1 < src.length ? src[i + 1] : '';
        if (quote != null) {
          if (c == r'\') {
            out.write(c);
            if (n.isNotEmpty) {
              out.write(n);
              i += 2;
              continue;
            }
          }
          if (c == quote) quote = null;
          out.write(c);
          i++;
          continue;
        }
        if (c == "'" || c == '"') {
          quote = c;
          out.write(c);
          i++;
          continue;
        }
        if (c == '/' && n == '/') {
          while (i < src.length && src[i] != '\n') {
            i++;
          }
          continue;
        }
        if (c == '/' && n == '*') {
          i += 2;
          while (i < src.length &&
              !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
            if (src[i] == '\n') out.write('\n');
            i++;
          }
          i += 2;
          continue;
        }
        out.write(c);
        i++;
      }
      return out.toString();
    }

    test('★★★ 三个海报占位点都不再引用硬编码的 posterPlaceholder', () {
      const files = [
        'lib/ui/widgets/poster_card.dart',
        'lib/ui/detail_page.dart',
        'lib/ui/follow_page.dart',
      ];

      /*
       * ★★★ 必须用**标识符边界**匹配，不能用 `contains`
       *
       * 本测试第一版写的是 `code.contains('AppColors.posterPlaceholder')`
       * —— 它**恒为真**，因为新名字
       * `AppColors.posterPlaceholderAlpha` **包含**那个前缀。
       * ⇒ 一条永远失败的断言（幸好我看到了它红）。
       *
       * 这正是"断言要能测出反面"的又一次实例：`contains` 在
       * "新名字是旧名字的前缀"这种情况下**无法区分**两者。
       */
      final oldIdent = RegExp(r'AppColors\.posterPlaceholder(?!\w)');

      for (final path in files) {
        final f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path 必须存在');
        final code = stripComments(f.readAsStringSync());

        expect(oldIdent.hasMatch(code), isFalse,
            reason: '★★★ $path 不能再用旧的硬编码占位色 —— '
                '它在浅色主题下是一块近黑方块（用户报的"黑色占位"）');

        expect(code.contains('posterPlaceholderAlpha'), isTrue,
            reason: '★ $path 必须用新的"前景色 5%"语义常量');
      }
    });

    test('★★ tokens.dart 里不能再有那个硬编码深色', () {
      final code = stripComments(File('lib/ui/tokens.dart').readAsStringSync());

      // ⚠️ 用 `0xFF23262E` 这个**字面量**而不是常量名 ——
      //    注释里引用了旧名字作为"历史记录"（那是刻意的，见 tokens.dart
      //    的证据链），所以按名字判会假失败；按色值判才是真判据。
      expect(code.contains('0xFF23262E'), isFalse,
          reason: '★★★ 旧色值 #23262E 必须彻底移除 —— '
              '留着它，后人"就近复制"就会把 bug 带回来');

      expect(code.contains('posterPlaceholderAlpha'), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 原版依据（防止后人"凭感觉"改回固定色）
  // ═══════════════════════════════════════════════════════════════════

  group('③ 原版依据（可执行记录）', () {
    test('★★ 原版占位是 5% 半透明，且浅色主题也是 5%', () {
      /*
       * ★★★ 这是"为什么用 5% 而不是某个固定浅灰"的**唯一依据**。
       *
       * 如果将来有人觉得"5% 太淡了看不见"，想把占位改成
       * `surfaceContainerHighest` 那种实色 —— 这条测试会告诉他：
       * 原版**两个主题都是 5%**，即"与背景只差 5%"是**刻意的设计**，
       * 不是"没调好"。
       *
       * ⚠️ 原版在**另一个仓库**，不存在时跳过而不是失败
       *    （否则只有 Flutter 侧的环境会假失败 —— 铁律 12）。
       */
      final base = File(r'D:\WishProject\cctv_to_client\src\design\base.css');
      final light =
          File(r'D:\WishProject\cctv_to_client\src\design\theme-light.css');

      if (!base.existsSync() || !light.existsSync()) {
        // ignore: avoid_print
        print('⚠️ 跳过：原版仓库不在本机（${base.path}）');
        return;
      }

      final baseSrc = base.readAsStringSync();
      final lightSrc = light.readAsStringSync();

      // 深色：.poster { background: rgb(255 255 255 / 0.05); }
      expect(baseSrc.contains('rgb(255 255 255 / 0.05)'), isTrue,
          reason: '★ 原版深色占位 = 白 5%');
      // 浅色：:root[data-theme="light"] .poster { background: rgb(16 18 26 / 0.05); }
      expect(lightSrc.contains('rgb(16 18 26 / 0.05)'), isTrue,
          reason: '★ 原版浅色占位 = 黑 5% —— **同样是 5%**，'
              '这就是"与背景几乎无差"的设计意图');
    });
  });
}
