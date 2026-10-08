// ═══════════════════════════════════════════════════════════════════════
//  task-99：浮层 / 面板 / 抽屉的入场动效（统一到 motion token）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（桌面端 9 条问题 · 第 7 条）
//     「很多弹窗我都觉得很生硬，包括抽屉还有页面之间的跳转，请优化」
//
// # 判据（全部**可观测**，不是「读了 flag」）
// ```text
// ① 首帧：遮罩透明度 < 1（动画真的从透明开始）
// ② 中途存在**中间态**（不是瞬变）—— ★ 这是「真的有动画」的硬证据
// ③ 终态：遮罩 opacity == 1、卡片 offset == (0,0)（几何与改前一致）
// ④ 卡片**同时**有透明度与位移（改前 episode 只有位移）
// ⑤ 时长真的取自 token：遮罩 150ms 到位、卡片 260ms 到位
// ⑥ ★ Reduce Motion ⇒ **第 0 帧就到位**（没有中间态）
// ⑦ 动画不改最终态几何：scrim 仍全屏、卡片仍在原位置原尺寸
// ⑧ 命中不变：点遮罩仍关闭、点卡片内部仍不关
// ```
//
// # 为什么读的是**渲染树里 Opacity/Transform 的实际值**
// ```text
// 「传了参数」≠「行为真的变了」—— 本项目已踩过同族问题
// （zz_t44_fade_in_test.dart:15-25 逐字写过这条理由）。
// ⇒ 所以这里读 Opacity.opacity 与 Transform.transform 的**实际矩阵**，
//   而不是断言「我调用了 MotionPrefs.duration」。
// ```
//
// # ★ 为什么不用 FadeTransition / ScaleTransition
// ```text
// · FadeTransition 内部是 RenderAnimatedOpacity ⇒ 树上**没有** Opacity 节点，
//   测试读不到实际值（zz_t44 就是因此才去读 SliverFadeTransition）。
// · ScaleTransition 会**改几何** ⇒ 违反判据⑦。
// ⇒ 共享件统一用 Opacity + Transform.translate（两个都可读、都不改尺寸）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/subtitle/subtitle_panel.dart';

// ══════════════════════════════════════════════════════════════════════
//  读取渲染树里的实际值
// ══════════════════════════════════════════════════════════════════════

/// 取 [of] 子树里**最外层**的那个 Opacity 的实际值
///
/// ⚠️ 按 **element 深度**取最小（= 最外层），不用 `.first` ——
///    遍历顺序不是文档承诺的（`sheet_close_animation_test.dart:128-129`
///    逐字记过这个坑）。
///
/// 为什么需要「最外层」：卡片内部可能自带 Opacity（如 `Slider`），
/// 那些是**更深**的节点，取最外层才拿到我们这层。
double? overlayOpacity(WidgetTester t, Finder of) {
  final f = find.descendant(of: of, matching: find.byType(Opacity));
  final els = f.evaluate().toList();
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

/// 取 [of] 子树里**最外层** Transform 的平移分量（dx, dy）
Offset? overlayOffset(WidgetTester t, Finder of) {
  final f = find.descendant(of: of, matching: find.byType(Transform));
  final els = f.evaluate().toList();
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
  final m = t.widget<Transform>(find.byWidget(best!.widget)).transform;
  return Offset(m.storage[12], m.storage[13]);
}

/// 遮罩那一层 `ColoredBox`
///
/// ⚠️ 取 `.first`：`OverlayScrim` 的 `Stack` 里 `ColoredBox` 是**第一个**孩子
///    （卡片是第二个）⇒ 深度优先遍历先遇到它。颜色断言会兜住这个假设 ——
///    万一匹配错了，颜色对不上会**当场红**，不会静默错下去。
Finder scrimBox() => find
    .descendant(
      of: find.byType(OverlayScrim),
      matching: find.byType(ColoredBox),
    )
    .first;

// ══════════════════════════════════════════════════════════════════════
//  夹具
// ══════════════════════════════════════════════════════════════════════

/// 面板夹具：`DanmakuSettingsDialog` 的根节点是 `Positioned.fill` ⇒ 必须套 Stack
///
/// ★ Reduce Motion 用 `copyWith(disableAnimations:)` **叠加**在既有
///   `MediaQueryData` 上，而不是新建一个 `MediaQueryData(disableAnimations:)`
///   —— 后者会把 `size` 一并清成 `Size.zero`，于是所有依赖
///   `MediaQuery.sizeOf` 的面板（字幕面板的高度上限、选集面板的宽度
///   `min(920, screen.width)`）按**零尺寸**布局，测试变成假失败
///   （我第一版就是这么写的，红了两条）。
Widget _stackHost(Widget child, bool reduceMotion) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Builder(
    builder: (ctx) => MediaQuery(
      data: MediaQuery.of(ctx).copyWith(disableAnimations: reduceMotion),
      child: Scaffold(body: Stack(children: <Widget>[child])),
    ),
  ),
);

DanmakuSettingsState _settingsState() => const DanmakuSettingsState(
  enabled: true,
  appId: 'a',
  appSecret: 'b',
  fontScale: 1.0,
  opacity: 1.0,
  speed: 8.0,
  area: 1.0,
);

DanmakuSettingsDialog _danmakuDialog({VoidCallback? onClose}) =>
    DanmakuSettingsDialog(
      state: _settingsState(),
      onSetEnabled: (_) {},
      onSetAppId: (_) {},
      onSetAppSecret: (_) {},
      onSetFontScale: (_) {},
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onClearCredentials: () {},
      onReload: () {},
      onClose: onClose ?? () {},
    );

/// `SubtitlePanel` 里有 `TextField` ⇒ 必须有 `Material` 祖先（否则抛
/// 「No Material widget found.」，t71_assrt_test.dart:909-911 记过）
Widget _materialStackHost(Widget child, bool reduceMotion) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Builder(
    builder: (ctx) => MediaQuery(
      data: MediaQuery.of(ctx).copyWith(disableAnimations: reduceMotion),
      child: Material(child: Stack(children: <Widget>[child])),
    ),
  ),
);

List<Episode> _eps(int n) => [
  for (var i = 0; i < n; i++)
    Episode(id: 'ep-$i', title: '第${i + 1}集', index: i),
];

EpisodeSheet _sheet({
  bool asDialog = false,
  EpisodePanelStyle style = EpisodePanelStyle.bottomSheet,
}) => EpisodeSheet(
  episodes: _eps(8),
  currentIndex: 0,
  onPick: (_) {},
  onClose: () {},
  asDialog: asDialog,
  style: style,
);

/// 挂一个面板，并**确定性地**推进到「第一帧已渲染」
///
/// ★ 为什么末尾要 `pump(Duration.zero)` 一次：
///   `TweenAnimationBuilder` 在 `pumpWidget` 内部会经历「挂载 → 注册 ticker →
///   第一帧」几个阶段，结束后动画可能还没开始、也可能已经推进了一帧
///   ⇒ 直接读「首帧」会**时红时绿**（zz_t44_fade_in_test.dart:40-54 实测）。
Future<void> mountPanel(
  WidgetTester t,
  Widget panel, {
  bool reduceMotion = false,
  bool needsMaterial = false,
}) async {
  final host = needsMaterial ? _materialStackHost : _stackHost;
  await t.pumpWidget(host(panel, reduceMotion));
  await t.pump(Duration.zero);
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 遮罩淡入
  // ═══════════════════════════════════════════════════════════════════

  group('① 遮罩（scrim）淡入 —— 改前是硬切', () {
    testWidgets('★★ 弹幕设置面板：首帧 <1 → 中途有中间态 → 终态 ==1', (t) async {
      await mountPanel(t, _danmakuDialog());

      final first = overlayOpacity(t, find.byType(OverlayScrim));
      expect(first, isNotNull, reason: '★ 必须能读到 OverlayScrim 里的 Opacity');
      expect(
        first! < 1.0,
        isTrue,
        reason:
            '★★ 第一帧遮罩必须是半透明（实测=$first）—— '
            '若这里是 1.0，说明遮罩仍然是**硬切**的，改了个寂寞',
      );

      // 中途：必须是**中间态**（不是瞬变）
      await t.pump(const Duration(milliseconds: 75));
      final mid = overlayOpacity(t, find.byType(OverlayScrim));
      expect(
        mid! > 0.0 && mid < 1.0,
        isTrue,
        reason:
            '★★★ 75ms 时必须处于中间态（实测=$mid）—— '
            '若这里是 0 或 1，说明动画是瞬变（要么没播、要么已结束）',
      );

      await t.pump(const Duration(milliseconds: 200));
      expect(
        overlayOpacity(t, find.byType(OverlayScrim)),
        1.0,
        reason: '★ 终态必须完全不透明 —— 否则遮罩颜色就不是原来那个了',
      );
    });

    testWidgets('★ 字幕面板：同一个共享件（首帧半透明）', (t) async {
      await mountPanel(
        t,
        SubtitlePanel(onClose: () {}, videoTitle: '维琴河'),
        needsMaterial: true,
      );

      final first = overlayOpacity(t, find.byType(OverlayScrim));
      expect(first, isNotNull);
      expect(first! < 1.0, isTrue, reason: '★ 字幕面板的遮罩也必须淡入（实测=$first）');

      await t.pump(const Duration(milliseconds: 300));
      expect(overlayOpacity(t, find.byType(OverlayScrim)), 1.0);
    });

    testWidgets('★★ 选集面板：改前遮罩在补间**之外**（硬切）', (t) async {
      await mountPanel(t, _sheet());

      final first = overlayOpacity(t, find.byType(OverlayScrim));
      expect(first, isNotNull);
      expect(
        first! < 1.0,
        isTrue,
        reason:
            '★★ 改前 `ColoredBox` 在 `TweenAnimationBuilder` 之外 ⇒ '
            '卡片在淡入而黑幕已经全黑。现在遮罩也走补间（实测=$first）',
      );

      await t.pump(const Duration(milliseconds: 300));
      expect(overlayOpacity(t, find.byType(OverlayScrim)), 1.0);
    });

    testWidgets('★ 选集条（_StripDrawer，手机第一层）：遮罩同样淡入', (t) async {
      await mountPanel(
        t,
        EpisodePanel(
          episodes: _eps(30),
          currentIndex: 0,
          onPick: (_) {},
          onClose: () {},
          isDesktopOverride: false,
        ),
      );

      // 手机形态默认是「条 + 箭头」那一层
      expect(find.text('选集'), findsOneWidget, reason: '阳性对照：条这一层在');
      final first = overlayOpacity(t, find.byType(OverlayScrim));
      expect(first, isNotNull);
      expect(first! < 1.0, isTrue, reason: '★ 改前这一层也是「遮罩硬切」（实测=$first）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 卡片：淡入 + 轻微上浮
  // ═══════════════════════════════════════════════════════════════════

  group('② 卡片淡入 + 上浮（幅度克制，24px）', () {
    testWidgets('★★ 弹幕卡片：首帧 24px 下移 + 半透明 → 终态 (0,0)/1.0', (t) async {
      await mountPanel(t, _danmakuDialog());

      final card = find.byType(OverlayCardMotion);
      final off0 = overlayOffset(t, card);
      final op0 = overlayOpacity(t, card);
      expect(off0, isNotNull);
      expect(op0, isNotNull);
      expect(
        off0!.dy,
        closeTo(OverlayMotion.cardSlide, 0.01),
        reason: '★★ 首帧卡片必须从下方 ${OverlayMotion.cardSlide}px 起步（实测=${off0.dy}）',
      );
      expect(off0.dx.abs(), lessThan(0.01), reason: '★ 居中弹窗不该有横向位移');
      expect(
        op0! < 1.0,
        isTrue,
        reason:
            '★★ 卡片必须**同时**淡入（实测 opacity=$op0）—— '
            '改前它只有位移，是「硬闪 + 平移」',
      );

      await t.pump(const Duration(milliseconds: 400));
      final off1 = overlayOffset(t, card)!;
      expect(off1.dx.abs(), lessThan(0.01), reason: '★ 终态位移必须归零');
      expect(off1.dy.abs(), lessThan(0.01), reason: '★ 终态位移必须归零');
      expect(overlayOpacity(t, card), 1.0, reason: '★ 终态必须完全不透明');
    });

    testWidgets('★★ 选集面板卡片：改前**只有位移、没有透明度**', (t) async {
      await mountPanel(t, _sheet());

      final card = find.byType(OverlayCardMotion);
      final op0 = overlayOpacity(t, card);
      expect(op0, isNotNull, reason: '★ 改前这里根本没有 Opacity 层');
      expect(
        op0! < 1.0,
        isTrue,
        reason:
            '★★ 这是本组最关键的断言：改前卡片是「硬闪 + 平移」'
            '（只有 Transform，没有 Opacity）⇒ 实测 opacity=$op0',
      );
      expect(
        overlayOffset(t, card)!.dy,
        closeTo(OverlayMotion.cardSlide, 0.01),
        reason: '★ 底部抽屉从下方升起',
      );

      await t.pump(const Duration(milliseconds: 400));
      expect(overlayOpacity(t, card), 1.0);
      expect(overlayOffset(t, card)!.dy.abs(), lessThan(0.01));
    });

    testWidgets('★ 桌面居中弹窗（asDialog，非抽屉）：改前 begin==end==0 ⇒ 零动画', (t) async {
      await mountPanel(t, _sheet(asDialog: true));

      final card = find.byType(OverlayCardMotion);
      expect(
        overlayOpacity(t, card)! < 1.0,
        isTrue,
        reason:
            '★★ 改前 asDialog 那一支的 begin 是 0（补间无变化）⇒ '
            '桌面居中弹窗**完全没有入场动画**。现在它有淡入',
      );
      expect(
        overlayOffset(t, card)!.dy,
        closeTo(OverlayMotion.cardSlide, 0.01),
      );
    });

    testWidgets('★ 右侧抽屉（桌面）：横向滑入，与几何一致', (t) async {
      await mountPanel(
        t,
        _sheet(asDialog: true, style: EpisodePanelStyle.rightDrawer),
      );

      final card = find.byType(OverlayCardMotion);
      final off0 = overlayOffset(t, card)!;
      expect(
        off0.dx,
        closeTo(OverlayMotion.cardSlide, 0.01),
        reason:
            '★ 贴右边的抽屉必须**从右滑入** —— '
            '方向与几何不一致会像「东西被甩过来」',
      );
      expect(off0.dy.abs(), lessThan(0.01), reason: '★ 横向抽屉不该有纵向位移');

      // 几何确实在右侧（阳性对照：方向不是随便挑的）
      final align = t.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerRight);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 时长真的取自 token
  // ═══════════════════════════════════════════════════════════════════

  group('③ 时长取自 token（不是魔数）', () {
    test('★ OverlayMotion 的三档就是既有 token 本身', () {
      expect(
        OverlayMotion.scrimDuration,
        Motion.fast,
        reason: '遮罩档必须等于 Motion.fast(150ms)',
      );
      expect(
        OverlayMotion.cardDuration,
        Motion.base,
        reason: '卡片档必须等于 Motion.base(260ms)',
      );
      expect(OverlayMotion.cardCurve, Motion.easeOut);
      expect(
        OverlayMotion.cardSlide,
        24.0,
        reason: '★ 幅度必须克制（page_transition 的缩放幅度只有 0.02）',
      );

      // ★ 不许偷偷用 slow（420ms）—— 弹层比页面切换还慢就是「生硬」
      expect(OverlayMotion.cardDuration, isNot(Motion.slow));
    });

    testWidgets('★★ 遮罩 150ms 到位；卡片 260ms 到位（按帧数判）', (t) async {
      await mountPanel(t, _danmakuDialog());

      final scrim = find.byType(OverlayScrim);
      final card = find.byType(OverlayCardMotion);

      // 150ms（= Motion.fast）时遮罩应当**已经**到位
      await t.pump(Motion.fast);
      expect(
        overlayOpacity(t, scrim),
        closeTo(1.0, 0.001),
        reason: '★ 遮罩必须用 Motion.fast(150ms) —— 若还没到位，说明用了更长的档',
      );

      // 而卡片（260ms）此刻**还没**到位 —— 这是「两档真的不同」的硬证据
      final midCard = overlayOffset(t, card)!;
      expect(
        midCard.dy,
        greaterThan(0.01),
        reason:
            '★★ 150ms 时卡片必须仍在路上（实测 dy=${midCard.dy}）—— '
            '若这里已经是 0，说明卡片也用了 150ms（两档没分开）',
      );

      // 再推到 260ms（累计 410ms）⇒ 卡片到位
      await t.pump(Motion.base);
      expect(overlayOffset(t, card)!.dy.abs(), lessThan(0.01));
      expect(overlayOpacity(t, card), 1.0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ Reduce Motion（无障碍）
  // ═══════════════════════════════════════════════════════════════════

  group('④ ★★★ Reduce Motion ⇒ 第 0 帧就到位（断言行为，不是 flag）', () {
    testWidgets('★★★ 弹幕面板：disableAnimations=true ⇒ 第一帧就是终态', (t) async {
      await mountPanel(t, _danmakuDialog(), reduceMotion: true);

      expect(
        overlayOpacity(t, find.byType(OverlayScrim)),
        1.0,
        reason:
            '★★★ Reduce Motion 打开时，遮罩第一帧就必须是 1.0 —— '
            '若这里是 0，说明动画**仍然会播**（那只证明了「读到了 flag」）',
      );
      final off = overlayOffset(t, find.byType(OverlayCardMotion))!;
      expect(off.dx.abs(), lessThan(0.01));
      expect(
        off.dy.abs(),
        lessThan(0.01),
        reason: '★★★ 卡片第一帧就必须在原位（若 dy=24，说明还在播动画）',
      );
      expect(overlayOpacity(t, find.byType(OverlayCardMotion)), 1.0);

      // 再推几帧，确认**始终**是终态（没有任何中间态）
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 40));
        expect(overlayOpacity(t, find.byType(OverlayScrim)), 1.0);
        expect(
          overlayOffset(t, find.byType(OverlayCardMotion))!.dy.abs(),
          lessThan(0.01),
        );
      }
    });

    testWidgets('★★★ 选集面板：同上（红度对照见上一条 —— 不开时必须有中间态）', (t) async {
      await mountPanel(t, _sheet(), reduceMotion: true);

      expect(overlayOpacity(t, find.byType(OverlayScrim)), 1.0);
      expect(
        overlayOffset(t, find.byType(OverlayCardMotion))!.dy.abs(),
        lessThan(0.01),
      );
      expect(overlayOpacity(t, find.byType(OverlayCardMotion)), 1.0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 几何 / 命中：动画**不许**改最终态
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ 动画不改最终态几何、不改命中', () {
    testWidgets('★★ 遮罩仍是**全屏 + 原色**（含 alpha 逐字不变）', (t) async {
      await mountPanel(t, _danmakuDialog());
      await t.pump(const Duration(milliseconds: 400));

      final box = t.widget<ColoredBox>(scrimBox());
      expect(
        box.color,
        Colors.black.withValues(alpha: 0.72),
        reason: '★★ 遮罩颜色必须与改前**逐字一致**（弹幕设置 = 黑 0.72）',
      );
      final screen = t.getRect(find.byType(Scaffold));
      expect(
        t.getRect(scrimBox()),
        screen,
        reason:
            '★★ 遮罩必须仍然是**全屏** —— 它一旦有孩子就会收缩到孩子大小，'
            '所以共享件把它放在 Stack 里当独立一层',
      );
    });

    testWidgets('★★ 选集面板遮罩色仍是黑 0.5（原版 rgb(0 0 0 / 0.5)）', (t) async {
      await mountPanel(t, _sheet());
      await t.pump(const Duration(milliseconds: 400));
      expect(
        t.widget<ColoredBox>(scrimBox()).color,
        Colors.black.withValues(alpha: 0.5),
      );
    });

    testWidgets('★★ 卡片几何与「无动画」时**逐像素一致**（改前 == 改后）', (t) async {
      // ① 带动画：跑完
      await mountPanel(t, _danmakuDialog());
      await t.pump(const Duration(milliseconds: 400));
      final animated = t.getRect(find.text('弹幕设置'));

      // ② Reduce Motion：第一帧就是终态 ⇒ 这一份就是「没有动画层」的几何
      await mountPanel(t, _danmakuDialog(), reduceMotion: true);
      final instant = t.getRect(find.text('弹幕设置'));

      expect(
        animated,
        instant,
        reason:
            '★★ 动画结束后卡片必须仍在原位置原尺寸 —— '
            '带动画=$animated / 无动画=$instant。'
            '两者不等说明动画改了布局（例如用了 ScaleTransition）',
      );
    });

    testWidgets('★ 点遮罩仍然关闭', (t) async {
      var closed = 0;
      await mountPanel(t, _danmakuDialog(onClose: () => closed++));
      await t.pump(const Duration(milliseconds: 400));

      await t.tapAt(const Offset(8, 8));
      await t.pump();
      expect(closed, 1, reason: '★ 加了动画层之后点背景仍必须能关');
    });

    testWidgets('★ 点卡片内部仍然**不**关闭', (t) async {
      var closed = 0;
      await mountPanel(t, _danmakuDialog(onClose: () => closed++));
      await t.pump(const Duration(milliseconds: 400));

      await t.tap(find.text('弹幕设置'));
      await t.pump();
      expect(closed, 0, reason: '★ 卡片内部要吃掉点击 —— 否则用户点一下标题面板就没了');
    });

    testWidgets('★ 选集面板：点背景关、点内部不关（回归）', (t) async {
      var closed = 0;
      await mountPanel(
        t,
        EpisodeSheet(
          episodes: _eps(8),
          currentIndex: 0,
          onPick: (_) {},
          onClose: () => closed++,
        ),
      );
      await t.pump(const Duration(milliseconds: 400));

      await t.tap(find.text('选集'));
      await t.pump();
      expect(closed, 0, reason: '★ 点面板内部不该关');

      await t.tapAt(const Offset(200, 10));
      await t.pump();
      expect(closed, 1, reason: '★ 点背景要关（episode_strip_test ③ 组同款判据）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 静态：四处都接了共享件；cast 的 sheet 时长也跟 token 对齐
  // ═══════════════════════════════════════════════════════════════════

  group('⑥ 接线（源码级）', () {
    String src(String rel) => File(rel).readAsStringSync();

    test('★★ 四个自实现浮层都用上了共享动效件', () {
      final files = <String, List<String>>{
        'lib/ui/widgets/danmaku_settings_dialog.dart': [
          'OverlayScrim(',
          'OverlayCardMotion(',
        ],
        'lib/ui/subtitle/subtitle_panel.dart': [
          'OverlayScrim(',
          'OverlayCardMotion(',
        ],
        'lib/ui/widgets/episode_strip.dart': [
          'OverlayScrim(',
          'OverlayCardMotion(',
        ],
      };
      files.forEach((path, needles) {
        final body = src(path);
        for (final n in needles) {
          expect(
            body.contains(n),
            isTrue,
            reason: '★★ $path 少了 $n —— 那一处就会退回「硬切/硬闪」',
          );
        }
      });

      // 选集面板里两个形态（条 + 完整面板）各有一份
      final strip = src('lib/ui/widgets/episode_strip.dart');
      expect(
        'OverlayCardMotion('.allMatches(strip).length,
        greaterThanOrEqualTo(2),
        reason: '★ 选集条与完整面板是两个独立外壳，两处都要接',
      );
    });

    test('★ 选集面板里**不再**有裸的 TweenAnimationBuilder 入场', () {
      final strip = src('lib/ui/widgets/episode_strip.dart');
      expect(
        strip.contains('tween: Tween(\n        begin: isDrawer'),
        isFalse,
        reason: '★ 改前那段「只有位移、没有透明度」的补间必须已被共享件取代',
      );
    });

    test('★★ cast 的两个底部弹层都跟 token 对齐了时长', () {
      final a = src('lib/ui/cast/cast_device_sheet.dart');
      final b = src('lib/ui/cast/cast_button.dart');
      expect(
        a.contains('sheetAnimationStyle: overlaySheetAnimationStyle(context)'),
        isTrue,
        reason: '★ 改前不传 ⇒ 吃 material 默认 250ms/200ms（比 token 还慢）',
      );
      expect(
        b.contains('sheetAnimationStyle: overlaySheetAnimationStyle(context)'),
        isTrue,
      );
    });

    test('★ 共享件里没有裸 Duration 魔数（时长只能来自 token）', () {
      final body = src('lib/ui/widgets/overlay_motion.dart');
      expect(
        RegExp(r'Duration\(milliseconds:').hasMatch(body),
        isFalse,
        reason: '★ 本项目已有 33 处裸 Duration 散落 —— 新增的不许再加一处',
      );
    });
  });
}
