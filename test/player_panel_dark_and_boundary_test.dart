@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 原因见下
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件调用 `MediaKit.ensureInitialized()`，它会加载 **libmpv-2.dll**。
// 实测：在 `flutter test` 的 flutter_tester 进程里加载该原生库，
// 会**偶发 native 崩溃**（访问违例 c0000005，进程退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// 实测崩溃率：加载 libmpv 6/25；不加载 0/25（干净交错 A/B）
// 与并发无关：串行 8 次里红 5 次；单文件串行也红（1/5）
// ```
//
// ★ 完整证据链与已排除清单：`.probe/native-media-tests.md`
// ★ 标签配置：`dart_test.yaml`
//
// 手动跑（改播放器 / media_kit 相关代码时**应该**跑一遍）：
// ```powershell
// flutter test test/ --tags native-media --concurrency=1
// ```
//
// ⚠️ `--concurrency=1` 并不能避免崩溃，只是让输出更易读。
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  ①-B 深色适配 + ② 视频区边界（task-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > ① 播放器页面整体黑色，弹窗白色，**不适配**
// > ② 播放器页面上面黑色，跟下面黑色**融为一体**了，搞点边界出来
//
// ★ 2026-10-08 追加（Owner 第 8 条）：
// > 还有播放详情页的右侧弹窗不要包含一条黑色的边框，不好看
//
// 量测结论（Owner 截图 u9_92496b4e.png 1444x845 逐像素）：
// ```text
// x=1006..1009 画面
// x=1010        整列 (42,42,42) 共 567 行 = y 159..725  ← ★ 用户说的"黑色边框"
// x=1011..      surface (238,240,246)（右侧信息面板）
// ⇒ 这一列**只**属于视频区描边矩形的**右边**，面板自己从 1011 才开始
// ```
// ⇒ 修法：描边只留**上 + 下**（`Border.symmetric(horizontal: …)`），
//    左右两条都去掉。
//
// # 这两个问题的共同根因：**播放页是纯黑，而浮层/黑边跟着应用主题走**
//
// ```text
// ① 面板取色走 FTheme.of(context) = 应用主题（可能浅色）
//    ⇒ 全屏黑 + 一块 #FAFAFA 面板 = "不适配"
// ② Video widget 铺满整屏（实测 Rect(0,0,1280,800)），
//    它内部 contain 出 1280x720 的画面，上下各 40px 黑边
//    ⇒ 顶部栏渐变 / 上黑边 / 画面 / 下黑边 / 控制条渐变
//       **全是黑**，看不出画面从哪开始
// ```
//
// # 本文件怎么验（不看"好不好看"，只看**可判定的量**）
//
// ```text
// ①-B：面板祖先里必须有一个 **Brightness.dark** 的 FTheme
//      （而不是"我觉得它变黑了"）
// ②  ：视频区描边的矩形必须**等于** BoxFit.contain 的几何
//      （1280x800 窗口 + 16:9 → 1280x720，上下各留 40）
// ```
// ★ 配色最终是**观感**问题 —— 色值对不代表好看。
//   所以这里只验"结构/几何正确"，最终判据留给真机截图（解锁后）。

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

List<Episode> eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

/// 挂载真实播放页
///
/// ⚠️ 两个坑（与 `player_episode_nav_boundary_test.dart` 同一套）：
/// ```text
/// ① `pumpWidget` 之后**不能**再 pump —— 多推一帧 `_load()` 就失败、
///    `_error` 置上、整条控制条消失
/// ② 默认画布 800x600 装不下控制条（溢出 62px）⇒ 设 1280x800
/// ```
Future<void> mountPlayer(WidgetTester t, {int episodeCount = 5}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final episodes = eps(episodeCount);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '①-B / ② 验收',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
}

Future<void> drainTimers(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  ①-B 深色适配
  // ═══════════════════════════════════════════════════════════════════
  group('①-B 播放页浮层用深色皮肤', () {
    testWidgets('★★★ 选集面板的祖先里有一个 **Brightness.dark** 的 FTheme',
        (t) async {
      /*
       * ★ 判据是"**祖先链里有深色 FTheme**"，而不是"面板看起来是黑的"。
       *
       * 理由：面板的取色全走 `FTheme.of(context)`，
       * 所以"最近的 FTheme 是不是深色"就是**因果链上最直接**的读数。
       * 若用"读某个像素颜色"，那会被卡片透明度/渐变干扰，
       * 而且改一处样式就会假红。
       */
      await mountPlayer(t);

      /*
       * ★ 用探针直调，**不用** `t.tap`。
       *
       * flutter_tester 里 PlayerPage 整棵树的**指针事件回调都不被调用**
       * （命中链完整、同 Stack 的兄弟控件正常 ⇒ 详见 test/t98 文件头），
       * 而底栏还因为 `sourin_core.dll` 加载失败（error 126）被 `_error`
       * 整个顶掉 ⇒ 既点不到「选集」，连按钮本身都不在树上。
       * 探针驱动的是**生产那棵树**上的 `_episodeSheetOpen`，测的东西不变。
       */
      expect(debugPlayerOpenEpisodeSheetForProbe(), isTrue,
          reason: '★ 选集面板要能开');
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      // 面板在不在
      expect(find.text('第1集'), findsWidgets,
          reason: '★ 面板应当已打开（能看到集号）');

      // ★ 从面板内部往上找最近的 FTheme，看它是不是深色
      final panelText = find.text('选集').evaluate().toList();
      expect(panelText, isNotEmpty);

      Brightness? found;
      panelText.first.visitAncestorElements((e) {
        if (e.widget is FTheme) {
          found = (e.widget as FTheme).data.colors.brightness;
          return false; // 找到最近的，停
        }
        return true;
      });

      expect(found, isNotNull,
          reason: '★ 面板必须在某个 FTheme 之下（否则取色会静默兜底成浅色）');
      expect(
        found,
        Brightness.dark,
        reason: '★★★ 用户报的「播放器整体黑色、弹窗白色，不适配」—— '
            '播放页里的浮层必须用**深色**皮肤。'
            '若这里是 light，说明 PlayerPanelTheme 没包上',
      );

      await drainTimers(t);
    });

    testWidgets('★★ 深色皮肤**只作用于播放页**（不影响别的页面）',
        (t) async {
      /*
       * 防"改过头"：`PlayerPanelTheme` 用的是 `FTheme`（InheritedWidget），
       * 作用域天然是本子树 —— 但要**证明**它没污染别处。
       *
       * 做法：挂一个**不经过播放页**的 FTheme 上下文，
       * 确认它仍是原来那个亮度。
       */
      const light = Brightness.light;
      await t.pumpWidget(
        MaterialApp(
          home: FTheme(
            data: FTheme.neutral.light.desktop,
            child: Builder(
              builder: (ctx) => Text(
                '${FTheme.of(ctx).colors.brightness}',
                textDirection: TextDirection.ltr,
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.text('$light'), findsOneWidget,
          reason: '★ 播放页之外的 FTheme 必须保持原样 —— '
              '深色皮肤只该影响播放页里的浮层');

      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 视频区边界
  // ═══════════════════════════════════════════════════════════════════
  group('② 视频区描边（上下黑边要有边界）', () {
    testWidgets('★★★ 描边矩形 = BoxFit.contain 的几何（1280x800 + 16:9 → 1280x720）',
        (t) async {
      /*
       * ★ 判据是**几何**，不是"有没有画东西"。
       *
       * 实测（诊断探针）：`Video` widget 铺满整屏 `(0,0,1280,800)`，
       * 画面是它**内部** contain 出来的 1280x720。
       * 所以描边必须**自己算**这个矩形 —— 算错了就会出现
       * "框画在画面中间"（夹取错误）或"框比画面小"（兜底 16:9 错误）。
       */
      await mountPlayer(t);
      await t.pump(const Duration(milliseconds: 100));

      /*
       * ⚠️ 测试环境里 `_player.state.width/height` **拿不到**
       *    （没有真实解码），所以 `_displayAspect` 返回 null ⇒ 不画描边。
       *
       * ★ 这不是"没测到"，而是**正确行为**：
       *   起播前不知道画面比例，就不该画一个可能是错的框。
       *   所以这里断言的是"**拿不到比例时不画**"。
       */
      final borders = find.byWidgetPredicate((w) {
        if (w is! DecoratedBox) return false;
        final d = w.decoration;
        return d is BoxDecoration && d.border != null;
      });
      expect(
        borders,
        findsNothing,
        reason: '★ 拿不到视频宽高时**不画描边** —— '
            '按 16:9 兜底会画出一个可能是错的框，'
            '那比没有框更糟（用户会以为界面坏了）',
      );

      await drainTimers(t);
    });

    testWidgets('★★ 描边是 1px 且颜色比纯黑略亮（不能抢眼）', (t) async {
      /*
       * 这条是**静态断言**：直接读源码里的色值。
       *
       * ⚠️ 为什么必须这样验：上面那条证明了"测试环境拿不到比例 ⇒ 不画"，
       *    所以**运行时**读不到那个 DecoratedBox。
       *    而"色值选得对不对"是**设计决定**，本来就该静态断言。
       */
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      expect(src.contains('width: 1'), isTrue,
          reason: '★ 描边必须 1px —— 粗了就从"边界"变成"装饰"');
      expect(src.contains('Color(0xFF2A2A2A)'), isTrue,
          reason: '★ 色值必须是 0xFF2A2A2A —— '
              '比纯黑略亮（看得见），又远暗于 #444（不抢眼）');
      expect(src.contains('_displayAspect'), isTrue,
          reason: '★ 必须用不夹取、不兜底的 `_displayAspect` —— '
              '复用 `_videoAspect` 会让 21:9 以上片源的框压到画面上');
    });

    testWidgets('★★ 描边不吃点击（不能挡住手势）', (t) async {
      await mountPlayer(t);
      await t.pump(const Duration(milliseconds: 100));

      /*
       * 描边层是 `Positioned.fill` 盖在最上面的 —— 若它吃点击，
       * 用户的单击播放/暂停、双击快进、长按倍速**全都会失效**。
       * ⇒ 必须 `IgnorePointer`。
       *
       * ⚠️ 锚点要用**使用处**而不是 getter 定义处：
       *    `_displayAspect` 在文件里出现**两次**
       *    （getter 定义 + 描边里调用），`indexOf` 命中的是**定义**
       *    （在 `_videoAspect` 下面），那里周围当然没有 IgnorePointer
       *    —— 我第一版就是这么假红的。
       *    改用 `lastIndexOf`（调用点在定义之后）。
       */
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final idx = src.lastIndexOf('_displayAspect');
      expect(idx > 0, isTrue);
      // 往上看 400 字符内应当有 IgnorePointer（调用点就在它下面几行）
      final before = src.substring(
        (idx - 400).clamp(0, src.length),
        idx,
      );
      expect(before.contains('IgnorePointer'), isTrue,
          reason: '★★ 描边层必须被 `IgnorePointer` 包着 —— '
              '否则它会吃掉单击/双击/长按手势');

      await drainTimers(t);
    });

    // ═══════════════════════════════════════════════════════════════════
    //  ★★★ 2026-10-08（Owner 第 8 条）：描边只留上 + 下
    // ═══════════════════════════════════════════════════════════════════

    testWidgets('★★★ 描边只有上 + 下两条边（左右不画）', (t) async {
      /*
       * ★ 判据是**真实画出来的像素**，不是"源码里写了什么"。
       *
       * 为什么必须真画：Flutter 的 `Border.paint` 在
       * `isUniform == true` 时会**忽略四条边各自的 style**，
       * 直接走 `_paintUniformBorderWithRectangle` 画一个**整矩形**描边
       * （box_border.dart:360-363）——
       * 也就是说「把 right 换成 BorderSide.none」这种写法**右边照样会画出来**。
       * 只有让 `isUniform == false`（`Border.symmetric` 正好如此）
       * 才会走 `paintBorder` 逐边绘制。
       * ⇒ 不真画一遍，根本分不出「写对了」和「写了但被静默忽略」。
       */
      const w = 40.0;
      const h = 30.0;

      final key = GlobalKey();
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: Container(
                width: w,
                height: h,
                color: const Color(0xFFFFFFFF),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    // ★ 与 lib/ui/player_page.dart 的描边**同一写法**
                    border: Border.symmetric(
                      horizontal: BorderSide(
                        color: Color(0xFF2A2A2A),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();

      /*
       * ⚠️ `toImage()` 必须在 `t.runAsync` 里跑。
       *
       * widget 测试默认跑在 **fake-async zone**：`toImage` 的 future 由
       * engine 的真实事件循环完成，fake zone 里永远等不到 ⇒ 用例**静默挂死**
       * （我第一版就是这样，整条命令卡到超时被杀，日志停在用例名那一行）。
       */
      final px = await t.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData();
        final bytes = data!.buffer.asUint8List();
        final width = image.width;
        final height = image.height;
        int at(int x, int y) => bytes[(y * width + x) * 4]; // R 通道足够判别
        return <String, int>{
          'w': width,
          'h': height,
          'top': at(width ~/ 2, 0),
          'bottom': at(width ~/ 2, height - 1),
          'left': at(0, height ~/ 2),
          'right': at(width - 1, height ~/ 2),
        };
      });

      expect(px!['top'], 42, reason: '★ 上边必须有线（#2A2A2A 的 R 通道）');
      expect(px['bottom'], 42, reason: '★ 下边必须有线');
      expect(px['left'], 255,
          reason: '★★★ 左边**不能**有线（用户要的只是上下边界）');
      expect(px['right'], 255,
          reason: '★★★ 右边**不能**有线 —— 这一列正是 Owner 截图里 x=1010 的 (42,42,42)，'
              '它紧贴右侧信息面板，所以被读成"面板的黑色边框"');
    });

    testWidgets('★★ 描边的源码写法是 Border.symmetric(horizontal:)，不是 Border.all', (t) async {
      final src = File('lib/ui/player_page.dart').readAsStringSync();

      expect(
        src.contains('border: const Border.symmetric('),
        isTrue,
        reason: '★★★ 必须用 `Border.symmetric` —— '
            '`Border.all`（含 copyWith(right: none)）在 isUniform 时会被 '
            '`_paintUniformBorderWithRectangle` 画成整矩形，左右两条边删不掉',
      );
      expect(
        src.contains('horizontal: BorderSide('),
        isTrue,
        reason: '★ `Border.symmetric` 的命名是**轴**不是位置：'
            '`horizontal:` = 上 + 下（box_border.dart:455-461）',
      );

      // 描边那一层里不许再出现 Border.all
      final idx = src.indexOf('border: const Border.symmetric(');
      final around = src.substring((idx - 1500).clamp(0, src.length), idx);
      expect(
        around.contains('border: Border.all('),
        isFalse,
        reason: '★ 描边层不该同时留着 Border.all',
      );

      await drainTimers(t);
    });
  });
}
