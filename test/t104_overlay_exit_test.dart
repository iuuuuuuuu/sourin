// ═══════════════════════════════════════════════════════════════════════
//  task-104：浮层**退场**动效 + 对话框统一入口（第 7 条二期）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（桌面端 9 条问题 · 第 7 条）
//     很多弹窗我都觉得很生硬，包括抽屉还有页面之间的跳转，请优化
// 以及二期追加（逐字）：
//     第 7 条只做了一半：进入动画做了（遮罩 + 卡片 + 五处面板），
//     退出动画和 18 处普通 showDialog 没做。做了吧,顺便要统一一下
//
// # 本文件守什么（task-99 守的是**入场**，这里只补**退场**与**统一**）
// ```text
// ① SheetExitMotion：关掉后**第 1 帧面板还在**（改前是「一帧就没了」）
// ② 退出期间 Opacity **单调下降**（不是瞬变，也不是跳变）
// ③ 跑完 260ms 才真的卸载（不多留、不早退）
// ④ 退出期间 IgnorePointer.ignoring == true（淡出的面板不许再吃点击）
// ⑤ Reduce Motion ⇒ **第 0 帧**就卸载（无障碍语义与同族件一致）
// ⑥ showAppDialog：路由时长 == token（框架默认 150ms ⇒ 传没传一眼可辨）
// ⑦ 三个真面板（弹幕设置 / B 站导入 / 字幕）在**真 PlayerPage** 上真的带退场
// ⑧ 静态门禁：15 处生产调用点全走 showAppDialog；lib 里裸 showDialog 归零
// ```
//
// # ★★ 阳性对照（铁律②）
// 「关掉后第 1 帧还在」有两种解释：
// ```text
// ① 退场动画真的在跑        ← 期望
// ② 压根没关 / 仪器瞎了     ← 必须排除
// ```
// ⇒ 每组都先断言「打开时面板在位、Opacity == 1」，再看关闭后的行为。
//
// # ★ 为什么不读 SheetTransition 的同类值
// 那是**入场 + 退场都做**的另一件（选集 / 直播 / 线路三个面板），
// 它已经被 `sheet_close_animation_test.dart` 与 `t72_jank_test.dart` 钉住；
// 本文件只碰「只做退场」的新件，避免两套断言互相踩。

@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/subtitle/subtitle_panel.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';

import '_support/strip_comments.dart';

// ══════════════════════════════════════════════════════════════════════
//  读取渲染树里的实际值（与 t99 同一套「取最外层」的规矩）
// ══════════════════════════════════════════════════════════════════════

/// 取 [of] 子树里**最外层**的那个 Opacity 的实际值
///
/// ⚠️ 按 **element 深度**取最小（= 最外层），不用 `.first` ——
///    遍历顺序不是文档承诺的（`sheet_close_animation_test.dart:128-129` 记过）。
double? overlayOpacity(WidgetTester t, Finder of) {
  final els = find
      .descendant(of: of, matching: find.byType(Opacity))
      .evaluate()
      .toList();
  if (els.isEmpty) return null;
  Element? best;
  var bestDepth = 1 << 30;
  for (final e in els) {
    var d = 0;
    e.visitAncestorElements((_) {
      d++;
      return true;
    });
    if (d < bestDepth) {
      bestDepth = d;
      best = e;
    }
  }
  return t.widget<Opacity>(find.byWidget(best!.widget)).opacity;
}

/// 取 [of] 子树里**最外层**的那个 IgnorePointer 的 ignoring
bool? overlayIgnoring(WidgetTester t, Finder of) {
  final els = find
      .descendant(of: of, matching: find.byType(IgnorePointer))
      .evaluate()
      .toList();
  if (els.isEmpty) return null;
  Element? best;
  var bestDepth = 1 << 30;
  for (final e in els) {
    var d = 0;
    e.visitAncestorElements((_) {
      d++;
      return true;
    });
    if (d < bestDepth) {
      bestDepth = d;
      best = e;
    }
  }
  return t.widget<IgnorePointer>(find.byWidget(best!.widget)).ignoring;
}

const Key kPanelKey = Key('t104-panel');

/// 被包住的子树是否还挂在树上
bool panelPresent() => find.byKey(kPanelKey).evaluate().isNotEmpty;

/// 一个能**外部切换 visible** 的宿主（模拟播放页的开关）
class _Host extends StatefulWidget {
  const _Host({this.reduceMotion = false, this.initial = true});

  final bool reduceMotion;
  final bool initial;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late bool _visible = widget.initial;

  void setVisible(bool v) => setState(() => _visible = v);

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Builder(
      builder: (ctx) => MediaQuery(
        // ★ 必须 copyWith 叠加：新建 MediaQueryData(disableAnimations:)
        //   会把 size 清成 Size.zero ⇒ 依赖 MediaQuery.sizeOf 的子树假失败
        data: MediaQuery.of(ctx)
            .copyWith(disableAnimations: widget.reduceMotion),
        child: Scaffold(
          body: Stack(
            children: <Widget>[
              // ★ 生产形态：Positioned.fill → SheetExitMotion → 面板
              //   （面板 fill: false ⇒ 自己不再写 Positioned，否则抛
              //    Incorrect use of ParentDataWidget）
              Positioned.fill(
                child: SheetExitMotion(
                  visible: _visible,
                  child: const ColoredBox(
                    key: kPanelKey,
                    color: Color(0xFF14161C),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 取宿主 State（要外部切 visible）
_HostState hostOf(WidgetTester t) => t.state<_HostState>(find.byType(_Host));

// ===================================================================
//  task-14: 两条静态门禁的**唯一**正则定义
// ===================================================================
//
// # 为什么要提成常量 (铁律 170: 同一纪律只能有一份实现)
//
// 反面对照那条测试必须拿**生产扫描用的同一份正则**去验 --
// 若在对照里另写一份字面量, 两边会各自演化, 对照就与生产脱钩了,
// 照样能假绿. 所以两边都引用这里的顶层常量.
//
// # 改前的洞 (本件即为此而做)
//
// 原正则要求 showDialog 后面**紧跟** < => 只能抓
// 「显式带类型参数」的 showDialog<T>(...), **抓不到**不带类型参数的
// showDialog(...) (Dart 会推断 T) -- 而后者同样会漏掉动效 token.
// 现在两条都改成 [<(] (同时匹配两种形态).

/// 生产代码里不许出现的裸 showDialog (< 与 ( 两种形态都要抓)
final kGateShowDialog = RegExp(r'\bshowDialog\s*[<(]');

/// 统一入口 showAppDialog (调用点计数同样两种形态都要算)
final kGateShowAppDialog = RegExp(r'\bshowAppDialog\s*[<(]');

/// 改前的老正则 -- 只给反面对照用 (证明那时的裸 ( 形态确实抓不到)
final kGateShowDialogOld = RegExp(r'\bshowDialog\s*<');

/// 改前的老正则 (showAppDialog 版, 同上)
final kGateShowAppDialogOld = RegExp(r'\bshowAppDialog\s*<');

void main() {
  setUpAll(() {
    // ★ 与 player_panel_wiring_test.dart:277-282 同款：libmpv 只在**存在时**加载
    //   （加载它会偶发 native 崩溃，见 .probe/native-media-tests.md；
    //    所以本文件带 native-media 标签、默认不跑，由门禁显式打开）
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 退场动画本体
  // ═══════════════════════════════════════════════════════════════════

  group('① SheetExitMotion：关掉后仍然在树上，并逐帧淡出', () {
    testWidgets('★★★ 阳性对照：visible=true 时面板在，Opacity == 1', (t) async {
      await t.pumpWidget(const _Host());
      await t.pump();
      expect(
        panelPresent(),
        isTrue,
        reason:
            '★★ 阳性对照：打开状态下面板必须在 —— '
            '这一条不过，下面所有「关闭后还在」的判定都无意义',
      );
      expect(
        overlayOpacity(t, find.byType(SheetExitMotion)),
        closeTo(1.0, 0.001),
        reason: '在位时应当完全不透明（入场由 OverlayScrim/OverlayCardMotion 负责）',
      );
      expect(
        overlayIgnoring(t, find.byType(SheetExitMotion)),
        isFalse,
        reason: '在位时必须能接收点击',
      );
    });

    testWidgets('★ 关闭后第 1 帧面板**还在**（改前是「一帧就没了」）', (t) async {
      await t.pumpWidget(const _Host());
      await t.pump();
      hostOf(t).setVisible(false);
      await t.pump(); // 只走一帧（零时长 pump 不推进动画）
      expect(
        panelPresent(),
        isTrue,
        reason:
            '★★ 关闭后第 1 帧就找不到面板 ⇒ 那是「一帧硬切」，'
            '等于本件的退场动画根本没生效（用户报的正是这个）',
      );
      expect(
        overlayOpacity(t, find.byType(SheetExitMotion)),
        closeTo(1.0, 0.001),
        reason: '第 1 帧还没开始降 —— 这是「退场从 1.0 开始」的基线',
      );
      expect(
        overlayIgnoring(t, find.byType(SheetExitMotion)),
        isTrue,
        reason:
            '★ 已关闭 ⇒ 立刻不许再吃点击（Opacity 不影响命中测试，'
            '所以必须显式 IgnorePointer，否则用户会点到正在淡出的面板）',
      );
    });

    testWidgets('★ 退出期间 Opacity 单调下降（不是瞬变、不是跳变）', (t) async {
      await t.pumpWidget(const _Host());
      await t.pump();
      hostOf(t).setVisible(false);
      await t.pump();

      final samples = <double>[];
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 40));
        final o = overlayOpacity(t, find.byType(SheetExitMotion));
        expect(o, isNotNull, reason: '第 $i 次采样时面板已经不在了 ⇒ 退场跑太快/没跑');
        samples.add(o!);
      }
      expect(samples.first, lessThan(1.0), reason: '★ 必须真的开始降了 —— 否则「单调下降」是空的');
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i],
          lessThanOrEqualTo(samples[i - 1] + 0.0001),
          reason: '★ 第 $i 次采样比上一次大 ⇒ 退场不单调（画面会闪）',
        );
      }
      expect(
        samples.last,
        lessThan(samples.first),
        reason: '★ 5 次采样必须真的在下降（否则只是「停住了」）',
      );
    });

    testWidgets('★ 跑完 260ms 才真的卸载（不多留、不早退）', (t) async {
      await t.pumpWidget(const _Host());
      await t.pump();
      hostOf(t).setVisible(false);
      await t.pump();

      await t.pump(
        OverlayMotion.exitDuration - const Duration(milliseconds: 40),
      );
      expect(panelPresent(), isTrue, reason: '★ 退场还没跑完就把面板摘了 ⇒ 用户看到的仍是一次硬切');

      await t.pump(const Duration(milliseconds: 60));
      expect(panelPresent(), isFalse, reason: '★ 退场跑完了面板必须卸载（否则它永远盖在播放器上）');
    });

    testWidgets('★ Reduce Motion ⇒ 第 0 帧直接卸载（不走 reverse）', (t) async {
      await t.pumpWidget(const _Host(reduceMotion: true));
      await t.pump();
      expect(panelPresent(), isTrue, reason: '阳性对照：开着的时候仍然在');
      hostOf(t).setVisible(false);
      await t.pump();
      expect(
        panelPresent(),
        isFalse,
        reason:
            '★ 系统开了「减少动态效果」时，关闭必须是**立即**的'
            '（同族契约见 motion_prefs.dart:60-66 与 tokens.dart 的 OverlayMotion）',
      );
    });

    testWidgets('★ 再打开 ⇒ 立刻在位（不接管入场，避免双重动画）', (t) async {
      await t.pumpWidget(const _Host(initial: false));
      await t.pump();
      expect(panelPresent(), isFalse, reason: '初始 visible=false ⇒ 不该挂着');
      hostOf(t).setVisible(true);
      await t.pump();
      expect(panelPresent(), isTrue);
      expect(
        overlayOpacity(t, find.byType(SheetExitMotion)),
        closeTo(1.0, 0.001),
        reason:
            '★ 本件**只做退场**：再打开时直接落到 1.0，'
            '入场交给 OverlayScrim / OverlayCardMotion —— '
            '否则同一段路会动两次（抖动）',
      );
    });
  });
  // ═══════════════════════════════════════════════════════════════════
  //  ② 统一入口：showAppDialog 真的把 token 接上了
  // ═══════════════════════════════════════════════════════════════════

  group('② showAppDialog：动效真的接到了路由上', () {
    /// 打开一个对话框，返回它所在的**路由**
    Future<ModalRoute<Object?>?> openRoute(
      WidgetTester t, {
      required bool reduceMotion,
      required bool viaApp,
    }) async {
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (ctx) => MediaQuery(
              data: MediaQuery.of(ctx)
                  .copyWith(disableAnimations: reduceMotion),
              child: Scaffold(
                body: Center(
                  // ★ 按钮必须是 MediaQuery 的**后代** —— 直接用外层 Builder 的 ctx
                  //   会读到 MaterialApp 那层的 MediaQuery（disableAnimations 仍是 false）
                  //   ⇒ Reduce Motion 那条会假红（我第一版就是这么写的）
                  child: Builder(
                    builder: (ctx) => ElevatedButton(
                      onPressed: () {
                        final b = (_) => const AlertDialog(
                          title: Text('t104'),
                          content: Text('动效'),
                        );
                        if (viaApp) {
                          showAppDialog<void>(context: ctx, builder: b);
                        } else {
                          // 对照组：**不**传 animationStyle（= 改前那 15 处的形态）
                          showDialog<void>(context: ctx, builder: b);
                        }
                      },
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump(); // 让路由 push 进去
      await t.pump(const Duration(milliseconds: 1));
      return ModalRoute.of(t.element(find.byType(AlertDialog)));
    }

    testWidgets('★★★ 阳性对照：对照组（裸 showDialog）用的是框架默认 150ms', (t) async {
      final route = await openRoute(t, reduceMotion: false, viaApp: false);
      expect(route, isNotNull, reason: '对话框必须真的推上去了');
      expect(
        route!.transitionDuration,
        const Duration(milliseconds: 150),
        reason:
            '★★ 阳性对照：改前那 15 处就是吃这个 150ms。'
            '这一条不过 ⇒ 本文件的读取器无效 ⇒ 下面 showAppDialog 的结论作废',
      );
    });

    testWidgets('★ showAppDialog ⇒ 路由时长 == OverlayMotion.cardDuration', (
      t,
    ) async {
      final route = await openRoute(t, reduceMotion: false, viaApp: true);
      expect(route, isNotNull);
      expect(
        route!.transitionDuration,
        OverlayMotion.cardDuration,
        reason:
            '★ 统一入口没把 animationStyle 接上 ⇒ 15 处调用点等于白改'
            '（animationStyle 是**可选**参数，漏传不报错 —— '
            '所以必须靠这条断言把它钉住）',
      );
    });

    testWidgets('★ Reduce Motion ⇒ 时长归零（与其它浮层同一语义）', (t) async {
      final route = await openRoute(t, reduceMotion: true, viaApp: true);
      expect(route, isNotNull);
      expect(
        route!.transitionDuration,
        Duration.zero,
        reason:
            '★ 无障碍开关必须一路生效到对话框'
            '（AnimationStyle.noAnimation 的两个时长都是 0）',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 三个真面板在**真 PlayerPage** 上真的带退场（探针驱动）
  // ═══════════════════════════════════════════════════════════════════

  group('③ 真 PlayerPage：三个面板的关闭也有动画', () {
    /*
     * ⚠️ 播放页挂上后会起 `RemoteBridge._scheduleRecheck` 的 5 秒定时器
     *    （`remote_bridge.dart:429`）⇒ 收尾必须停掉它并推完挂起的帧，
     *    否则 flutter_test 报 "A Timer is still pending"
     *    （同款收尾见 player_panel_wiring_test.dart:269-274 的 drainTimers）。
     */
    setUp(() => RemoteBridge.instance.stop());
    tearDown(() => RemoteBridge.instance.stop());

    Future<void> drainTimers(WidgetTester t) async {
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(seconds: 6));
      }
      RemoteBridge.instance.stop();
    }

    /// 挂真实 PlayerPage（与 player_panel_wiring_test.mountPlayer 同款）
    Future<void> mount(WidgetTester t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            provider: 'cctv',
            id: 'cctv1',
            title: '退场验证',
            episodes: const <Episode>[
              Episode(
                id: 'ep1',
                title: '第1集',
                url: 'https://example.invalid/1.m3u8',
              ),
            ],
            episodeIndex: 0,
            episodeId: 'ep1',
            episodeTitle: '第1集',
            isTv: false,
            isTouchOnly: false,
          ),
        ),
      );
    }

    /// 某个面板的宿主（要读它包住的那棵子树）
    Finder hostOfPanel(Type panel) => find.ancestor(
      of: find.byType(panel),
      matching: find.byType(SheetExitMotion),
    );

    /// 一个面板的完整退场契约
    Future<void> expectExitMotion(
      WidgetTester t, {
      required Type panel,
      required bool Function() open,
      required bool Function() close,
      required String name,
    }) async {
      // ── 阳性对照：先真的打开 ──
      expect(open(), isTrue, reason: '$name：探针没把面板打开');
      await t.pump();
      expect(
        find.byType(panel),
        findsOneWidget,
        reason:
            '★★ 阳性对照：打开后 $name 必须在树上 —— '
            '这一条不过，下面「关闭后还在」的判定全是空的',
      );
      expect(
        overlayOpacity(t, hostOfPanel(panel)),
        closeTo(1.0, 0.001),
        reason: '$name：在位时必须完全不透明',
      );

      // ── 关闭：第 1 帧必须还在 ──
      expect(close(), isTrue, reason: '$name：探针没把面板关掉');
      await t.pump();
      expect(
        find.byType(panel),
        findsOneWidget,
        reason: '★★ $name 关闭后第 1 帧就没了 ⇒ 没有退场动画（改前正是这样）',
      );
      expect(
        overlayIgnoring(t, hostOfPanel(panel)),
        isTrue,
        reason: '$name：关闭后必须立刻停止接收点击',
      );

      // ── 中途：Opacity 必须真的降了 ──
      await t.pump(const Duration(milliseconds: 120));
      final mid = overlayOpacity(t, hostOfPanel(panel));
      expect(mid, isNotNull, reason: '$name：中途面板不该消失');
      expect(
        mid!,
        lessThan(1.0),
        reason: '★★ $name 的 Opacity 没降 ⇒ 退场动画没跑（只挂了件没生效）',
      );

      // ── 跑完：卸载 ──
      await t.pump(OverlayMotion.exitDuration);
      expect(
        find.byType(panel),
        findsNothing,
        reason: '$name：退场跑完必须卸载（否则永远盖在播放器上）',
      );

      await drainTimers(t);
    }

    testWidgets('① 弹幕设置面板', (t) async {
      await mount(t);
      await expectExitMotion(
        t,
        panel: DanmakuSettingsDialog,
        open: debugPlayerOpenDanmakuSettingsForProbe,
        close: debugPlayerCloseDanmakuSettingsForProbe,
        name: '弹幕设置面板',
      );
    });

    testWidgets('② 哔哩哔哩弹幕导入面板', (t) async {
      await mount(t);
      await expectExitMotion(
        t,
        panel: BiliImportDialog,
        open: debugPlayerOpenBiliSheetForProbe,
        close: debugPlayerCloseBiliSheetForProbe,
        name: 'B 站导入面板',
      );
    });

    testWidgets('③ 在线搜索字幕面板', (t) async {
      await mount(t);
      await expectExitMotion(
        t,
        panel: SubtitlePanel,
        open: debugPlayerOpenSubtitlePanelForProbe,
        close: debugPlayerCloseSubtitlePanelForProbe,
        name: '字幕面板',
      );
    });

    testWidgets('★ 关闭后底栏的判据仍然认「关着」（不靠动画时长兜底）', (t) async {
      await mount(t);
      expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
      await t.pump();
      expect(debugPlayerCloseDanmakuSettingsForProbe(), isTrue);
      await t.pump();
      expect(
        debugPlayerAnySheetOpen(),
        isFalse,
        reason:
            '★ 真源（_danmakuSheetOpen）必须**立刻**翻 false —— '
            '退场动画只是视觉层，不许把「面板还开着」这个事实拖到动画结束',
      );
      expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
      await drainTimers(t);
    });
  });
  // ═══════════════════════════════════════════════════════════════════
  //  ④ 静态门禁：统一入口 + 挂载形态（源码级，剥注释后断言）
  // ═══════════════════════════════════════════════════════════════════
  //
  // ⚠️ 为什么必须有这一组：`animationStyle` 是**可选**参数 ⇒ 漏传不报错，
  //    类型系统拦不住「又有人新写一个不带动效的弹窗」。
  //    而「统一」这件事只能靠「只剩一个入口」来保证。

  group('④ 静态门禁', () {
    /// 剥注释后的源码（共用 test/_support/strip_comments.dart，不许再抄一份）
    String code(String rel) => stripComments(File(rel).readAsStringSync());

    /// 出现次数
    int count(String src, String needle) {
      var n = 0;
      var from = 0;
      while (true) {
        final i = src.indexOf(needle, from);
        if (i < 0) return n;
        n++;
        from = i + needle.length;
      }
    }

    test('★ lib 里除了唯一入口，不再有裸 showDialog', () {
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final rel = e.path.replaceAll(r'\', '/');
        if (rel == 'lib/ui/widgets/overlay_motion.dart') continue; // 入口本体
        final c = stripComments(e.readAsStringSync());
        final n = kGateShowDialog.allMatches(c).length;
        if (n > 0) offenders.add(rel + '（' + n.toString() + ' 处）');
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '★★ 这些文件还在直接调 showDialog ⇒ 它们的动效不受 token 管'
                '（统一入口是 showAppDialog）。清单：' +
            offenders.join(' / '),
      );
    });

    test('★★ 15 处生产调用点逐个都在统一入口上', () {
      const want = <String, int>{
        'lib/ui/player_page.dart': 1,
        'lib/ui/settings_page.dart': 5,
        'lib/ui/settings/emby_page.dart': 1,
        'lib/ui/settings/skip_page.dart': 1,
        'lib/ui/widgets/provider_import_dialog.dart': 2,
        'lib/ui/widgets/provider_login_panel.dart': 1,
        'lib/ui/widgets/source_switch_dialog.dart': 1,
        'lib/ui/widgets/sync_panel.dart': 2,
        'lib/ui/widgets/tvbox_source_panel.dart': 1,
      };
      var total = 0;
      want.forEach((rel, n) {
        // ★ task-14 ③：同时匹配 showAppDialog< 与 showAppDialog(（同类洞一起补）
        final got = kGateShowAppDialog.allMatches(code(rel)).length;
        expect(
          got,
          n,
          reason:
              '★ ' + rel + ' 应恰好 ' + n.toString() + ' 处，实测 ' + got.toString(),
        );
        total += got;
      });
      expect(total, 15, reason: '★ 用户说的 18 处，实测生产调用点是 15 处（其余是注释与真机探针）');
      /*
       * ★ task-14 ③ 反面对照：showAppDialog(...)（不带类型参数）也必须被数到
       *
       * 改前的正则同样只认显式类型参数 —— 与 ④ 那条是**同一类洞**。
       * 这里用样本钉死，避免它又退化。
       */
      const sampleAppTyped = 'Future<void> d(BuildContext c) async {'
          '  await showAppDialog<int>(context: c, builder: (_) => x);'
          '}';
      const sampleAppBare = 'Future<void> e(BuildContext c) async {'
          '  await showAppDialog(context: c, builder: (_) => x);'
          '}';
      expect(kGateShowAppDialog.allMatches(stripComments(sampleAppTyped)).length, 1);
      expect(
        kGateShowAppDialog.allMatches(stripComments(sampleAppBare)).length,
        1,
        reason: '★ 不带类型参数的 showAppDialog( 也必须被数到（同类洞）',
      );
      // 改前那个正则对裸形态抓不到 —— 洞的存在性证明
      expect(kGateShowAppDialogOld.allMatches(stripComments(sampleAppBare)).length, 0);
    });

    /*
     * ★★★ 反面对照：门禁必须**真的会抓**（本仓库铁律②阳性对照）
     *
     * # 为什么必须有这一条
     *
     * 上面那条「lib 里没有裸 showDialog」是**存在性断言** ——
     * 它对「门禁正则写错了 / 从不检查」这种故障**恒为真**。
     * 本仓库反复吃过这个亏（.probe/REPORT-core-8-14.md §6.5.1 记过同类假绿）。
     *
     * ⇒ 造三个临时源码样本，断言：
     *     样本 A：showDialog<int>(…)  ← 带类型参数（**改前就能抓**）
     *     样本 B：showDialog(…)       ← **不带**类型参数（**改前抓不到** ← 这就是那个洞）
     *     样本 C：只在**注释**里出现  ← 必须**不**被抓（剥注释的对照）
     *   把任一样本删掉，这条测试就会红 ⇒ 它**不可能**假绿。
     */
    test('★★ 反面对照：门禁必须同时抓到 showDialog< 与 showDialog(', () {
      // ★ 与生产扫描**同一份**正则 —— 不许在这里另写一个（否则对照就脱钩了）

      const sampleTyped = 'Future<void> a(BuildContext c) async {'
          '  await showDialog<int>(context: c, builder: (_) => const SizedBox());'
          '}';
      const sampleBare = 'Future<void> b(BuildContext c) async {'
          '  await showDialog(context: c, builder: (_) => const SizedBox());'
          '}';
      // 只在注释里 ⇒ 剥注释后应为 0
      const sampleCommentOnly = '// 示例：await showDialog<int>(context: c, builder: (_) => x);'
          'Future<void> c0() async {}';

      expect(
        kGateShowDialog.allMatches(stripComments(sampleTyped)).length,
        1,
        reason: '★ 带类型参数的 showDialog<T>( 必须被抓到',
      );
      expect(
        kGateShowDialog.allMatches(stripComments(sampleBare)).length,
        1,
        reason: '★★ 不带类型参数的 showDialog( 也必须被抓到 —— 这正是改前的洞',
      );
      expect(
        kGateShowDialog.allMatches(stripComments(sampleCommentOnly)).length,
        0,
        reason: '★ 注释里的示例**不许**被抓（必须剥注释后再匹配）',
      );

      // ★ 把「改前抓不到样本 B」也钉死 —— 这条就是洞的存在性证明
      expect(
        kGateShowDialogOld.allMatches(stripComments(sampleTyped)).length,
        1,
        reason: '改前正则对样本 A 有效（所以它抓到了 ui-dev 那一版）',
      );
      expect(
        kGateShowDialogOld.allMatches(stripComments(sampleBare)).length,
        0,
        reason: '★ 改前正则对样本 B **完全抓不到** —— 这就是门禁的洞（本条即证明）',
      );
    });

    test('★ 唯一入口自己把 animationStyle 接上了（漏传不报错 ⇒ 必须钉）', () {
      final c = code('lib/ui/widgets/overlay_motion.dart');
      expect(
        c.contains('animationStyle: overlaySheetAnimationStyle(context),'),
        isTrue,
        reason: '★ 统一入口没接 animationStyle ⇒ 全部调用点等于没改',
      );
      expect(c.contains('Future<T?> showAppDialog<T>({'), isTrue);
      expect(
        c.contains('=> showDialog<T>('),
        isTrue,
        reason: '★ 入口必须是 showDialog 的薄封装（不复制框架语义）',
      );
    });

    test('★ 三个面板的挂载点：常挂 + 只翻 visible（不是 if (_xOpen)）', () {
      final c = code('lib/ui/player_page.dart');
      for (final f in const [
        '_danmakuSheetOpen',
        '_biliSheetOpen',
        '_subtitlePanelOpen',
      ]) {
        expect(
          c.contains('visible: ' + f + ','),
          isTrue,
          reason: '★ ' + f + ' 的挂载点不是 SheetExitMotion(visible: …) 形态 ⇒ 退场动画没有',
        );
        // ★ 判据用「行尾换行」而不是裸子串：
        //   `if (_danmakuSheetOpen) _refreshDanmakuReadout();` 这类**同行的其它用法**
        //   是合法的（它不挂面板）；挂载点的形态是 `if (_xOpen)` 后面直接换行。
        expect(
          c.contains('if (' + f + ')\n'),
          isFalse,
          reason:
              '★★ ' +
              f +
              ' 又变回 if (…) 换行挂载了 —— 那样 flag 翻 false 时'
                  '那个 Element 会被整个移除、didUpdateWidget 不跑'
                  '⇒ 退场动画**静默失效**（这是本任务最容易写错的一处）',
        );
      }
      expect(
        count(c, 'child: SheetExitMotion('),
        3,
        reason: '★ 三个挂载点必须都包在 SheetExitMotion 里',
      );
    });

    test('★ 三个面板都支持 fill: false，且默认 true（老调用点零破坏）', () {
      for (final rel in const [
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'lib/ui/widgets/bili_import_dialog.dart',
        'lib/ui/subtitle/subtitle_panel.dart',
      ]) {
        final c = code(rel);
        expect(
          c.contains('this.fill = true,'),
          isTrue,
          reason: '★ ' + rel + ' 少了 fill 开关的**默认 true**（老宿主会被破坏）',
        );
        expect(c.contains('final bool fill;'), isTrue);
        expect(
          c.contains(
            'return widget.fill ? Positioned.fill(child: body) : body;',
          ),
          isTrue,
          reason: '★ ' + rel + ' 的根节点没有按 fill 分流',
        );
      }
      final c = code('lib/ui/player_page.dart');
      expect(
        count(c, 'fill: false,'),
        3,
        reason:
            '★ 三个挂载点都要传 fill: false —— 面板自己再写 Positioned.fill'
            '会抛 Incorrect use of ParentDataWidget（父链里已经夹了 Opacity）',
      );
    });

    test('★ 退场时长只来自 token（共享件里没有裸 Duration 魔数）', () {
      final c = code('lib/ui/widgets/overlay_motion.dart');
      expect(
        RegExp(r'Duration\(milliseconds:').hasMatch(c),
        isFalse,
        reason: '★ 共享件里出现了裸时长 ⇒ 改一处漏两处',
      );
      final tk = code('lib/ui/tokens.dart');
      expect(
        tk.contains('static const Duration exitDuration = cardDuration;'),
        isTrue,
        reason: '★ 退场时长必须是一个 token，而不是各调用点的魔数',
      );
      expect(tk.contains('static const Curve exitCurve = cardCurve;'), isTrue);
    });
  });
}
