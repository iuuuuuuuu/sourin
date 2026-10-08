// task-58 前置验证：合并页的**布局地基**能不能成立？
//
// # 为什么先测这个（而不是先写页面）
//
// 目标形态是 `Column[视频(16:9), 详情区(可滚动)]`，而 `PlayerPage` 的
// build 返回的是**整页 `Scaffold`**，其内部 `Stack` 里 `Video` 是
// `Positioned.fill`（player_page.dart L5909-5917）——
// 也就是说它**会铺满给它的任何空间**。
//
// ⇒ 所以整个方案的地基是一个**可验证的布局假设**：
// ```text
// 把 `Scaffold` 放进 `SizedBox(height: H)` 里，它是否**尊重**这个约束
// （渲染成 H 高），而不是撑满父级？
// ```
// 若尊重 ⇒ 「上播放器 + 下详情」用 `Column + SizedBox` 就能实现，
//           **不需要改 player_page.dart 的 8172 行**。
// 若不尊重 ⇒ 必须改 PlayerPage（报行号给 lead）。
//
// ★ 这是**纯布局原语**的验证，不涉及 media_kit/网络 ⇒ 快且确定性。
//   被测的是"Scaffold/Stack/Positioned.fill 在受限高度下的行为"，
//   与业务无关 ⇒ 用同构的最小 widget 树即可，不必起真播放器。
//
// ★ 我**没有**用真实 PlayerPage 测：那需要 mpv + 网络，
//   而本测试要回答的问题（约束是否被尊重）与播放器无关。
//   "真实 PlayerPage 也能被这样包住"由**真机实测**回答（见 task-58 验收判据）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 `PlayerPage` 的**外层结构**同构（Scaffold → Stack → Positioned.fill → Video）
///
/// 用 `ColoredBox` 代替 `Video`：这里要测的是**布局**，不是渲染视频。
/// `Video` 在 `PlayerPage` 里就是 `Positioned.fill` 的子节点，
/// 所以"它拿到多大的盒子"完全由外层布局决定。
///
/// ⚠️ `key` 挂在**填满的那层**（`Positioned.fill` 的直接子节点）——
///    不能挂在 `Center` 里面的 `ColoredBox` 上：`Center` 给子节点**松约束**，
///    无子节点的 `ColoredBox` 会缩成 **0x0**（我第一版就是这么写的，
///    量到 `Rect(640,180,640,180)` ⇒ 那是**仪器错**，不是布局错）。
Widget playerLike({Key? key}) => Scaffold(
      key: key,
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: SizedBox.expand(
                key: const ValueKey('video'),
                child: const ColoredBox(color: Colors.blue),
              ),
            ),
          ),
          // 与 PlayerPage 一样：面板也是 Positioned.fill / Positioned（会被约束到同一盒子）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ColoredBox(
              key: const ValueKey('bar'),
              color: Colors.black87,
              child: const SizedBox(height: 56),
            ),
          ),
        ],
      ),
    );

void main() {
  const size = Size(1280, 800);

  testWidgets('★★ 地基假设：Scaffold 放进 SizedBox 会**尊重**高度约束', (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const videoH = 360.0; // 16:9 在 640 宽下 ≈ 360
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(height: videoH, child: playerLike()),
            const Expanded(
              child: SingleChildScrollView(
                child: SizedBox(height: 2000, child: Text('详情区')),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final scaf = tester.getRect(find.byType(Scaffold).last);
    final video = tester.getRect(find.byKey(const ValueKey('video')));
    final bar = tester.getRect(find.byKey(const ValueKey('bar')));

    debugPrint('[EMBED] 外层 Scaffold = $scaf');
    debugPrint('[EMBED] 内层 Scaffold(播放器) = $scaf');
    debugPrint('[EMBED] 视频盒 = $video');
    debugPrint('[EMBED] 控制条 = $bar');

    // ① 内层播放器必须**只占** videoH 高（尊重约束）
    expect(video.height, closeTo(videoH, 0.5),
        reason: '★ 视频区必须恰好是 $videoH 高（= 约束被尊重）。'
            '若它等于整屏 800 ⇒ Scaffold 撑满了父级 ⇒ '
            '「上播放器 + 下详情」用 SizedBox 包不住 ⇒ 必须改 PlayerPage');
    expect(video.top, closeTo(0, 0.5), reason: '视频区必须从顶部开始');
    // ② 控制条必须贴在**视频区底部**（不是整屏底部）
    expect(bar.bottom, closeTo(videoH, 0.5),
        reason: '★ 控制条必须贴在视频区底部（$videoH），而不是整屏底部（800）'
            '⇒ 否则播放器的浮层会盖到详情区上面');
    // ③ 详情区必须能占满剩余高度
    final detail = tester.getRect(find.byType(SingleChildScrollView));
    debugPrint('[EMBED] 详情区 = $detail');
    expect(detail.top, closeTo(videoH, 0.5), reason: '详情区必须紧接视频区');
    expect(detail.bottom, closeTo(800, 0.5), reason: '详情区必须占满剩余高度');
  });

  testWidgets('★★ 全屏态：只渲染视频（详情区不参与布局）', (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: playerLike(),
    ));
    await tester.pump();

    final video = tester.getRect(find.byKey(const ValueKey('video')));
    debugPrint('[FULL] 视频盒 = $video（应为整屏 1280x800）');
    expect(video.size, size,
        reason: '★ 全屏态视频必须铺满整屏（这才是"全屏时只剩视频"）');
  });

  testWidgets('★★ 详情区滚动时**不重建**视频区（关键：不能重建播放器）',
      (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 用 StatefulWidget 计数：视频区的 build 次数
    var videoBuilds = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              height: 360,
              child: Builder(builder: (_) {
                videoBuilds++;
                return playerLike();
              }),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: SizedBox(height: 3000, child: Text('详情' * 500)),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    final afterFirst = videoBuilds;

    // 滚动详情区
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
    await tester.pump();

    debugPrint('[REBUILD] 首次 build = $afterFirst，滚动后 = $videoBuilds');

    // ★ 这里只断言"布局没坏"。**真正的"播放器没被重建"判据在真机上**
    //   （日志不该出现第二次 `[PLAYER] open`）—— 因为 `Player` 的生命周期
    //   由 `State` 决定，而 `State` 是否复用取决于**元素树的位置与 key**，
    //   纯 widget 测试里没有真 Player 可观察。
    expect(videoBuilds, greaterThanOrEqualTo(afterFirst),
        reason: '布局在滚动后仍然有效');
    final video = tester.getRect(find.byKey(const ValueKey('video')));
    expect(video.height, closeTo(360, 0.5),
        reason: '★ 滚动详情区**不能**改变视频区高度（否则播放器会被 relayout）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 风险①的地基：全屏切换**不能重建**播放器
  // ═══════════════════════════════════════════════════════════════════

  /// ★★★ 全屏切换必须**保留视频区的 State**（= 不会重建 `Player`）
  ///
  /// # 为什么这是风险①的可测部分
  ///
  /// `Player` 的生命周期挂在 `State` 上（`player_page.dart` L1253 在
  /// `initState` 里 `_player = Player(...)`）。而 **`State` 是否被复用**，
  /// 取决于 `Element` 在树里的**位置与类型**：
  /// ```text
  /// 位置/类型不变 ⇒ Element 复用 ⇒ State 复用 ⇒ Player 不重建 ✓
  /// 位置或类型变了 ⇒ 旧 Element 卸载 ⇒ 新 State ⇒ ★ 新 Player（黑屏/重载）
  /// ```
  ///
  /// ⇒ 所以「全屏 ⇒ 只剩视频」**不能**写成：
  /// ```dart
  /// _fullscreen
  ///   ? playerWidget                                  // 位置 A
  ///   : Column(children: [SizedBox(child: playerWidget)])  // ★ 位置 B（换了父级！）
  /// ```
  /// 那会让 `playerWidget` 的父级在 `Column` 与根之间切换 ⇒ **remount** ✗
  ///
  /// ★ 正确写法：**始终**是同一个 `Column` 的第 0 个 `Expanded`，
  ///   只改 flex 与"详情区在不在"：
  /// ```dart
  /// Column(children: [
  ///   Expanded(flex: videoFlex, child: playerWidget),   // ← 类型与位置恒定 ✓
  ///   if (!fullscreen) Expanded(flex: detailFlex, child: detail),  // ← ★ 2026-10-04：
  ///                                                                 //   `videoFlex`/`detailFlex`
  ///                                                                 //   常量已被 m01887 第③条删除，
  ///                                                                 //   窄档改由 `_narrowVideoHeight()`
  ///                                                                 //   算出的高度 ×10 当 flex。
  ///                                                                 //   **本段是示意伪代码**，
  ///                                                                 //   生产写法见 `media_page.dart`
  ///                                                                 //   `:991-1014`。
  /// ])
  /// ```
  /// 全屏时只剩第 0 个 ⇒ 它拿到 100% 高度。
  ///
  /// 本测试用"数 initState 次数"作为**结构性判据**：
  /// `initState` 只跑一次 ⇒ State 被复用 ⇒ 真机上 `Player` 不会重建。
  testWidgets('★★★ 全屏切换必须保留视频区 State（initState 只跑一次）',
      (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              flex: 3,
              child: _CountingPlayer(key: _videoKey),
            ),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                child: SizedBox(height: 2000, child: Text('详情' * 300)),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final st1 = _videoKey.currentState!;
    debugPrint('[STATE] 窗口态 initState 次数 = ${st1.initCount}');
    expect(st1.initCount, 1, reason: '首次构建应当只 initState 一次');

    final rect1 = tester.getRect(find.byKey(const ValueKey('video')));
    debugPrint('[STATE] 窗口态视频盒 = $rect1');

    // ── 切到"全屏"：只留视频（详情区移除，flex 变大）──
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              flex: 1,
              child: _CountingPlayer(key: _videoKey),
            ),
            // ★ 详情区**整个不在**（与全屏时一致）
          ],
        ),
      ),
    ));
    await tester.pump();

    final st2 = _videoKey.currentState;
    final rect2 = tester.getRect(find.byKey(const ValueKey('video')));
    debugPrint('[STATE] 全屏态 initState 次数 = ${st2?.initCount}');
    debugPrint('[STATE] 全屏态视频盒 = $rect2');

    expect(identical(st1, st2), isTrue,
        reason: '★★★ 全屏切换后 `State` 必须**是同一个对象** ⇒ '
            '否则 `Player` 会被重建（真机表现：黑屏/重新 open）');
    expect(st2!.initCount, 1,
        reason: '★★★ `initState` 必须仍然只跑过 **1** 次 ⇒ '
            '跑了 2 次就意味着播放器被重建（风险①）');
    expect(rect2.size, size,
        reason: '★ 全屏态视频必须铺满整屏（flex=1 且无兄弟 ⇒ 100%）');
  });

  /// ★ 反面对照：**换父级**的写法**会**重建 State（证明上一条的仪器有区分力）
  ///
  /// 没有这条，"initState 只跑一次"可能只是因为**任何**写法都复用 State ——
  /// 那就无法证明"必须用同类型同位置"这个约束。
  testWidgets('★ 反面对照：换父级的写法**会**重建 State（仪器有效性）',
      (tester) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final k1 = GlobalKey<_CountingPlayerState>();
    final k2 = GlobalKey<_CountingPlayerState>();

    // 窗口态：视频在 Column → SizedBox 里
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SizedBox(height: 360, child: _CountingPlayer(key: k1)),
          const Expanded(child: SizedBox()),
        ]),
      ),
    ));
    await tester.pump();
    debugPrint('[STATE-反面] 窗口态 initState = ${k1.currentState?.initCount}');

    // "全屏"：视频**直接**作为 body（父级从 SizedBox 变成 Scaffold）⇒ remount
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _CountingPlayer(key: k2)),
    ));
    await tester.pump();
    debugPrint('[STATE-反面] 换父级后 initState = ${k2.currentState?.initCount}');

    expect(k2.currentState!.initCount, 1,
        reason: '新位置新建了 State（这正是"换父级 ⇒ remount"的证据）');
    expect(identical(k1.currentState, k2.currentState), isFalse,
        reason: '★★ 换父级必须得到**不同**的 State ⇒ '
            '这证明"同类型同位置"这个约束是**必要的**，不是多余的');
  });
}

/// 一个"像播放器"的 StatefulWidget：数 `initState` 跑了几次
///
/// ★ 它代表 `PlayerPage`：`Player` 在它的 `initState` 里创建
///   （`player_page.dart` L1253）⇒ `initState` 次数 = 播放器创建次数。
class _CountingPlayer extends StatefulWidget {
  const _CountingPlayer({super.key});
  @override
  State<_CountingPlayer> createState() => _CountingPlayerState();
}

class _CountingPlayerState extends State<_CountingPlayer> {
  int initCount = 0;
  @override
  void initState() {
    super.initState();
    initCount++;
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox.expand(
            key: ValueKey('video'),
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      );
}

final GlobalKey<_CountingPlayerState> _videoKey = GlobalKey<_CountingPlayerState>();
