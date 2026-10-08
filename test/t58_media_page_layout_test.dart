@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-10-04 补：本文件被标记为 `native-media`（默认不跑）
// ═══════════════════════════════════════════════════════════════════════
//
// 与 `zz_t42_player_keys_test.dart` 同因同法：本文件 `setUpAll` 里调
// `MediaKit.ensureInitialized()` 加载 **libmpv-2.dll**，而 `flutter_tester`
// 里加载该原生库会**偶发 native 崩溃**（访问违例 c0000005，退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// ```
//
// ★ 本文件是**第 8 个**同类文件 —— 全仓 7 个加载 libmpv 的测试文件里
//   只有它没标（`zz_t42_player_keys_test.dart:18-21` 记着那 7 个）。
//   实测后果（2026-10-04 全量首跑）：19 条 `[E]` 里 17 条来自本文件，
//   而**单独跑 16/16 全绿**（日志 `.probe/lead_t58_alone.txt`）。
//
// 手动跑（改播放器 / media_kit 相关代码时**应该**跑一遍）：
// ```powershell
// flutter test test/ --run-skipped --tags native-media --concurrency=1
// ```
//
// 手动跑本文件：
// ```powershell
// flutter test test/t58_media_page_layout_test.dart --run-skipped --tags native-media
// ```
// ═══════════════════════════════════════════════════════════════════════
//  task-58/59：**合并页的左右分栏在真 widget 树里成立**
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ task-59 的变更（Owner 新裁决取代 task-58）
//
// ```text
// task-58（旧）：上播放器 + 下详情      ⇒ Column
// task-59（新）：**左播放器 + 右信息**  ⇒ Row（宽屏 >=900）
//               窄屏 <900 仍回退 Column（手机上左右分栏不可用）
// ```
// Owner 原话：
// > 你参照一下腾讯视频的播放页面布局，**左侧播放器右侧是视频的信息**
//
// # 为什么需要这个文件（验收判据里"可结构化的那一半"）
//
// 判据"右侧栏有海报/简介/选集"是**视觉**判据 ⇒ 屏幕锁着时做不了。
//
// 但其中**可结构化的那一半**不需要屏幕：
// ```text
// · 详情区**在树里**吗？（不是"看起来在"）
// · 它占了**正确的矩形**吗？（视频区在左、详情区在右、不重叠、等高）
// · 视频区是不是恒定的第 0 个 child？
// · 全屏时详情区**真的从树里消失**了吗？
// ```
// ⇒ ★ 这些用 `WidgetTester` 就能判定，而且比截图**更可靠**
//   （截图受分辨率/主题/字体影响；而我抓不到 —— 锁屏 + ANGLE 返回缓存帧）。
//
// # ★★ 设计纪律：**不 mock `Player`**（Lead 明确要求）
//
// ```text
// ✗ 为了测试去 mock Player ⇒ 引入"测试专用抽象"
//   ⇒ 那是**假绿的温床**（测的是 mock 的行为，不是真件的行为）
// ✓ 挂**真** `MediaPage`（真 PlayerPage + 真 DetailPage），
//   只断言**结构性**的东西（Row/Column / Expanded / 矩形 / 树里有没有）
// ```
// ★ 而"详情区占的矩形"那条**已经由 `t58_embed_layout_test.dart` 用**同构**的
//   树证明过** ⇒ 这里不重复。
//
// # 全屏怎么驱动（★ 用**真路径**，不用测试后门）
//
// 真机路径是「按 Enter ⇒ `_toggleFullscreen` ⇒ `_onFullscreenChanged?.call(next)`」。
// ⇒ 本文件**真的按 Enter**（与 `zz_t42_player_keys_test.dart` 同一手法）。
//   `windowManager.setFullScreen` 在测试环境不可用，但播放器那边是
//   `try/catch` 包住的（"插件不可用 —— 不该因此让播放中断"）⇒ 不影响判据。
//
// # 挂真 `PlayerPage` 的代价与做法
//
// `PlayerPage.initState` 会创建 `Player`（media_kit）⇒ 需要 `libmpv-2.dll`。
// ★ 照抄 `zz_t42_player_keys_test.dart` 的既有做法
//   （`MediaKit.ensureInitialized` + 逐帧 `pump` + 最后 `drain` 推完挂起的定时器）。
//
// ⚠️ 本文件 L26 起的 `import 'package:flutter/material.dart';` 是
//    **既有测试文件的既有写法**，保持原样（生产代码才禁止它）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import '_support/strip_comments.dart';

/// 挂载**真实** `MediaPage`
///
/// ⚠️ **必须把测试视口设成真实窗口尺寸**（1280×800）。
///
/// # 为什么（我第一版没设，8 条测试全红 —— 而原因是**测试环境**，不是布局）
///
/// `flutter_test` 的默认视口是 **2400×1800 物理 / dpr=3.0 ⇒ 逻辑 800×600**。
/// 而合并页把 800 高切成 9:11 ⇒ 视频区只有 **270** 高、详情区 330 高。
/// 视频区里 `PlayerPage` 的 `_ErrorOverlay`（一个 `Center` + `Column`）
/// 在 270 高里**放不下** ⇒ `RenderFlex overflowed` ⇒ 抛异常 ⇒ 测试红。
///
/// ★ 而那个溢出**在真机上不会发生** —— 真机窗口是 1280×800，
///   视频区 360 高（`t58_embed_layout_test` 实测过），放得下。
///
/// ⇒ ★★ **教训**：widget 测试的**视口尺寸是判据的一部分** ——
///   不设就等于在"一个不存在的屏幕"上测，得到的红/绿都不代表真机。
Future<void> mountMediaPage(
  WidgetTester t, {
  Size window = const Size(1280, 800),
  double dpr = 1.0,
  /// ★ task-59 ⑥：允许指定主题亮度（默认深色 —— 与既有 33 条的行为**逐字一致**，
  ///   只给"底色跟随主题"那组传 `Brightness.light`）。
  ///
  /// ⚠️ 默认值必须是 `dark`：既有测试跑在深色主题下（本文件原本就用的
  ///    `MaterialApp` 默认值），改成 light 会让**既有断言的行为**变化
  ///    —— 那是"顺手改坏"。
  Brightness brightness = Brightness.dark,
}) async {
  t.view.physicalSize = window;
  t.view.devicePixelRatio = dpr;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3A6EA5),
          brightness: brightness,
        ),
        useMaterial3: true,
      ),
      home: const MediaPage(
        provider: 'cctv',
        id: 'cctv1',
        title: 'task-58 合并页布局',
      ),
    ),
  );
  // 多推几帧：真 DetailPage 会发起 IPC，真 PlayerPage 会建 Player
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 把挂起的定时器推完（否则用例结束报 "A Timer is still pending"）
///
/// ★ 照抄 `zz_t42_player_keys_test.dart`：有 `sourin_core.dll` 时
///   会多一个 `resolveStream` 的 120s timeout。
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

/// 一次完整的按键（down + up）—— 与真人敲键一致
Future<void> tapKey(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(k);
  await t.pump(const Duration(milliseconds: 40));
  await t.sendKeyUpEvent(k);
  await t.pump(const Duration(milliseconds: 40));
}

/// 找到合并页的**外层 Row**（task-59：宽屏左右分栏）
///
/// ⚠️ 不能 `find.byType(Row).first` —— `PlayerPage`/`DetailPage` 内部
///    **也有** Row，顺序不保证。
/// ⇒ 判据：**某个直接子节点是 `Expanded` 且它包着 `PlayerPage`**
///   （那正是"视频区恒定在第 0 个 child"这个设计的可识别特征）。
///
/// ★ task-59：Owner 要求「左侧播放器右侧是视频的信息」⇒ 1280x800 视口
///   （`mountMediaPage` 的默认值）宽度 >= 900 ⇒ 走 **Row** 分支。
Row? _outerRow(WidgetTester t) {
  for (final c in t.widgetList<Row>(find.byType(Row))) {
    for (final child in c.children) {
      if (child is Expanded && child.child is PlayerPage) return c;
    }
  }
  return null;
}

/// 找到合并页的**外层 Column**（task-59：窄屏 <900 的回退路径）
///
/// ⚠️ 判据同上 —— 靠"含 `Expanded(PlayerPage)`"识别，不靠 `.first`。
Column? _outerColumn(WidgetTester t) {
  for (final c in t.widgetList<Column>(find.byType(Column))) {
    for (final child in c.children) {
      if (child is Expanded && child.child is PlayerPage) return c;
    }
  }
  return null;
}

/// ★ task-59：**当前生效的轴向容器**（宽屏=Row，窄屏=Column）
///
/// ⇒ 让"第 0 个 child 恒定"这条判据**与轴向无关**地成立
///   （两种轴向都要求播放器在第 0 位）。
/// ⚠️ 返回 `Flex`（Row/Column 的共同基类）⇒ 断言只用 `.children`，
///    不依赖具体轴向 —— 这样轴向切换不会让断言失效。
Flex? _outerFlex(WidgetTester t) => _outerRow(t) ?? _outerColumn(t);

/// 外层容器里的 `Expanded` 列表（第 0 个 = 视频区）
///
/// ★ task-59：同时支持 Row（宽屏）与 Column（窄屏）
List<Expanded> _expanded(WidgetTester t) {
  final c = _outerFlex(t);
  if (c == null) return const [];
  return c.children.whereType<Expanded>().toList();
}

/// ★ task-59：详情区在"外层容器"里的**直接槽位**
///
/// ```text
/// Row（宽屏）   ⇒ SizedBox(width: detailW, child: detail)   ← 定宽
/// Column（窄屏）⇒ Expanded(flex: <由 _narrowVideoHeight 算出>)  ← 比例**可变**
///   ★ m01887 第③条（2026-10-04）：窄档 flex 不再是常量 9:11，
///     而是「视频 16:9 高度 / 剩余高度」换算出来的（见 `media_page.dart`
///     的 `_narrowVideoHeight`）。⇒ **本文件任何断言都不许钉 flex 数值。**
/// ```
/// ⚠️ 两种槽位**类型不同** ⇒ 断言不能写死 `Expanded`。
///   ★ 我第一版照抄旧契约的"窗口态必须有两个 Expanded" ⇒ **2 条测试假红**
///     （实测 `Expected: <2> Actual: <1>`）—— 而**布局是对的**，错的是断言。
///   ⇒ 教训：**改布局契约时断言必须跟着契约走**，不能沿用旧契约的形状。
///     （与"子串命中≠语义存在"同族：**形状相似 ≠ 语义相同**。）
///
/// ⚠️ 2026-09-27 第三轮：详情区外面**多包了一层**（`DecoratedBox` + `ClipRRect`
///    —— 那是 Owner 要求「播放详情页右边也应该圆角」的修复）。
///    ⇒ 判据从 `child.child is DetailPage` 改成
///      **"子树里含有 DetailPage"** —— 判据的本意是
///      "详情区在那个槽位里"，而**不是**"它是槽位的直接 child"。
///    ★ 这是"断言要跟着**语义**走，不要跟着**形状**走"的第二次应用
///      （见上面那段注释 —— 同一个文件里已经踩过一次同类坑）。
Widget? _detailSlot(WidgetTester t) {
  final c = _outerFlex(t);
  if (c == null) return null;

  /*
   * ⚠️ 不能用 `Widget.visitChildren` —— `Widget` **没有**那个方法
   *    （它是 `Element` 的）。而 `Element.visitChildren` 走的是**已挂载**的树。
   *
   * ⇒ 从当前 `Row`/`Column` 的 **Element** 出发，向下找 `DetailPage` 的
   *   Element，再判断它在不在"第 1 个槽位"的子树里。
   *   这样判据是"**详情区在那个槽位里**"，与包了几层无关。
   */
  final flexEl = t.element(find.byWidget(c));

  /// 以 `root` 为根，向下找 `DetailPage` 的 Element
  Element? findDetail(Element root) {
    if (root.widget is DetailPage) return root;
    Element? hit;
    root.visitChildren((child) {
      if (hit == null) hit = findDetail(child);
    });
    return hit;
  }

  // 外层容器里"除播放器外"的那些槽位
  final slots = <Element>[];
  flexEl.visitChildren((child) {
    // 跳过含 PlayerPage 的那个槽位（第 0 个 = 视频区）
    Element? player;
    void findPlayer(Element e) {
      if (e.widget is PlayerPage) {
        player = e;
        return;
      }
      e.visitChildren(findPlayer);
    }

    findPlayer(child);
    if (player == null) slots.add(child);
  });

  for (final slot in slots) {
    if (findDetail(slot) != null) return slot.widget;
  }
  return null;
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  ① 左右分栏（★ task-59 取代 task-58 的上下分栏）
  // ═══════════════════════════════════════════════════════════════════

  group('① task-59：左播放器 + 右信息（宽屏）', () {
    testWidgets('★★★ 有外层 Row；两个 Expanded；详情区在**右**且不重叠', (t) async {
      await mountMediaPage(t);

      final outer = _outerRow(t);
      expect(outer, isNotNull,
          reason: '★★★ 找不到"含 Expanded(PlayerPage)"的外层 **Row** ⇒ '
              '合并页的左右分栏结构变了（task-59 Owner：「左侧播放器'
              '右侧是视频的信息」）');

      /*
       * ★ task-59：**不能**断言"两个 Expanded"！
       *   Row 分支里详情区是 `SizedBox(width: detailW)`（**定宽**），
       *   只有视频区是 `Expanded`。
       *   ⇒ 判据改成"**详情区确实占据了第 1 个槽位**"（与槽位类型无关）。
       */
      expect(_detailSlot(t), isNotNull,
          reason: '★★★ 外层 Row 的**第 1 个槽位**必须放 `DetailPage` '
              '（Row 里是 `SizedBox(width: detailW)`，Column 里是 `Expanded`）—— '
              '找不到 ⇒ 详情区不在树里 ⇒ 用户看不到选集/换源/简介');

      // ★ 矩形：视频区在左、详情区在右、**不重叠**
      final rVideo = t.getRect(find.byType(PlayerPage));
      final rDetail = t.getRect(find.byType(DetailPage));
      debugPrint('[MEDIA-LAYOUT] 左侧(视频) = $rVideo');
      debugPrint('[MEDIA-LAYOUT] 右侧(详情) = $rDetail');

      expect(rVideo.width, greaterThan(0),
          reason: '★ 视频区宽度必须 > 0 ⇒ 否则画面被压成 0');
      expect(rDetail.width, greaterThan(0),
          reason: '★ 详情区宽度必须 > 0 ⇒ 否则"右侧栏"实际没显示出来');
      expect(rDetail.left, greaterThanOrEqualTo(rVideo.right - 0.5),
          reason: '★★★ 详情区必须在视频区**右侧**。若 rDetail.left < rVideo.right '
              '⇒ 两者**重叠** ⇒ 用户会看到详情压在画面上');
      // ★ 纵向等高（CrossAxisAlignment.stretch）—— 腾讯视频侧栏与播放器等高
      expect(rDetail.height, closeTo(rVideo.height, 0.5),
          reason: '★★ 左右两栏必须**等高**（stretch）—— '
              '实测 视频高=${rVideo.height} 详情高=${rDetail.height}');
      expect(rVideo.top, closeTo(0, 0.5),
          reason: '★ 视频区必须贴顶（y=0）');
    });

    testWidgets('★★ 右侧信息栏宽度 = clamp(30% 视口, 340, 440)', (t) async {
      /*
       * ★ task-59 冻结契约：`detailW = (mq.size.width * 0.30).clamp(340.0, 440.0)`
       *   视口 1280 ⇒ 1280*0.30 = 384 ⇒ 落在 [340,440] 内 ⇒ **384**
       */
      await mountMediaPage(t);
      final rDetail = t.getRect(find.byType(DetailPage));
      debugPrint('[MEDIA-LAYOUT] 详情区宽度 = ${rDetail.width}');

      expect(rDetail.width, closeTo(384.0, 1.0),
          reason: '★★ 1280 宽视口 ⇒ 右侧栏应为 1280*0.30 = **384** —— '
              '实测 ${rDetail.width}。若为其它值 ⇒ clamp 边界或比例被改了');
    });

    testWidgets('★★★ 视频区永远是**第 0 个** child（换位置会重建播放器）', (t) async {
      /*
       * ★★★ 这条是本文件最重要的断言。
       *
       * `Player` 在 `_PlayerPageState.initState` 里创建 ⇒ 若视频区的
       * **位置或父级**变了，Element 会卸载 ⇒ **新 State** ⇒ 重建播放器
       * ⇒ 症状"全屏后黑屏/重新加载"，且**极难归因**。
       *
       * ⇒ 判据：**视频区永远是第 0 个 child**（详情区只是"在不在"）。
       * ★ task-59：用 `_outerFlex` ⇒ 该判据对 Row（宽屏）/ Column（窄屏）
       *   **都**成立 ⇒ 轴向切换不会让这条断言失效。
       */
      await mountMediaPage(t);
      final outer = _outerFlex(t);
      expect(outer, isNotNull,
          reason: '★ 找不到"含 Expanded(PlayerPage)"的外层 Flex（Row/Column）');
      expect(outer!.children.first, isA<Expanded>(),
          reason: '★★★ 第 0 个 child 必须是 Expanded（视频区）—— '
              '否则布局结构变了，全屏切换可能重建播放器');
      expect((outer.children.first as Expanded).child, isA<PlayerPage>(),
          reason: '★★★ 第 0 个 child 必须包着 **PlayerPage** ⇒ '
              '"类型与位置恒定"（那是 State 复用、播放器不被重建的前提）');
    });

    testWidgets('★★★ 轴向切换（Row⇄Column）**不得重建播放器**（State 同一实例）', (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ task-59 硬约束 3 的**直接**证明（Lead 明确要求）
       * ══════════════════════════════════════════════════════════════
       *
       * 契约：
       * ```text
       * `_playerKey` 稳定 + 播放器永远是 body 的第 0 个 child
       *   ⇒ 全屏切换 / **Row↔Column 轴向切换**时 Element 位置不变
       *   ⇒ State 复用 ⇒ `Player` **不重建**
       * ```
       *
       * # 为什么这条**必须**单独证明（不能靠"第 0 个 child"那条代替）
       *
       * `Row` 与 `Column` 是**不同的 widget 类型** ⇒ Flutter 的
       * `Element.updateChild` 在"类型不同"时**会卸载旧 Element 并新建**
       * —— **除非**新 child 带 `GlobalKey`（那时走 `GlobalKey` 的
       * **重挂载**路径：`_retakeInactiveElement` ⇒ **保留 State**）。
       *
       * ⇒ ★ 所以"轴向切换后 State 不变"**依赖 GlobalKey 的存在**，
       *   而"第 0 个 child"那条只证明**位置**，**证不出**这一点。
       *   ★ 两条是**互补**的，不是重复的。
       *
       * # 怎么测（真路径：改视口宽度 ⇒ 触发重建 ⇒ 换轴向）
       *
       * ```text
       * 1280x800（>=900）⇒ Row     记录 State 实例
       *  800x800（ <900）⇒ Column  断言 State **仍是同一个实例**
       * 1280x800（>=900）⇒ Row     再断言一次（来回都不断）
       * ```
       * ⚠️ 用 `t.view.physicalSize` 改尺寸是**真机 resize 的同构做法**
       *    （MediaPage 读 `MediaQuery` ⇒ 尺寸变 ⇒ 依赖触发重建）。
       */
      await mountMediaPage(t);   // 1280x800 ⇒ Row

      // ① 前置：确认当前是 **Row**
      expect(_outerRow(t), isNotNull,
          reason: '★ 前置：1280 宽（>=900）应当走 Row');
      expect(_outerColumn(t), isNull,
          reason: '★ 前置：宽屏下不应同时存在外层 Column');

      /*
       * ⚠️ 取 State 用 `t.state(find.byType(PlayerPage))`，**不是** `key.currentState`。
       *
       * # 为什么（红度证明教我的）
       * 我第一版写 `pp0.key! as GlobalKey` + `key.currentState`。
       * 做红度证明时（删掉 `key: _playerKey,`）该行**直接抛 null check**，
       * ⇒ 测试红在**前置**而不是红在 `identical(state…)` 那条断言上
       *   （实测 `MEDIA-AXIS` 打印出现 **0 次** ⇒ 根本没走到断言）。
       * ⇒ ★ 那样"红"是**前置崩了**，**证不出**"State 判据有分辨力"。
       * ★ 改用 finder 取 State（与 key 无关）⇒ 删 key 后测试能**跑到**
       *   `identical(...)` 并**因它**失败 ⇒ 红度落在**被断言的机制**上。
       */
      final stateBefore = t.state(find.byType(PlayerPage));
      debugPrint('[MEDIA-AXIS] Row 态 State = ${identityHashCode(stateBefore)}');

      // ② 改窄 ⇒ 应切成 **Column**
      t.view.physicalSize = const Size(800, 800);
      await t.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }

      expect(_outerColumn(t), isNotNull,
          reason: '★★ 800 宽（<900）必须**回退 Column** —— '
              '否则手机上左右分栏会把播放器挤到不可用');
      expect(_outerRow(t), isNull,
          reason: '★ 窄屏下不应同时存在外层 Row');

      final stateNarrow = t.state(find.byType(PlayerPage));
      debugPrint('[MEDIA-AXIS] Column 态 State = ${identityHashCode(stateNarrow)}');
      expect(
        identical(stateBefore, stateNarrow), isTrue,
        reason: '★★★ **Row → Column 轴向切换后，播放器的 State 必须是同一个实例** ⇒ '
            'Element 未卸载 ⇒ 播放器**没被重建**（视频不中断、不黑屏）。'
            '若这里 false ⇒ 轴向切换重建了播放器 ⇒ 真机上换窗口大小会把'
            '正在播的视频打断。'
            '（★ 保命的是 `_playerKey` 这个 GlobalKey —— 见本测试的注释）',
      );

      // ③ 再改宽 ⇒ 回到 Row，State 仍不变（来回都不断）
      t.view.physicalSize = const Size(1280, 800);
      await t.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }

      expect(_outerRow(t), isNotNull, reason: '★ 回到宽屏应当再次走 Row');
      final stateWideAgain = t.state(find.byType(PlayerPage));
      debugPrint('[MEDIA-AXIS] Row 态（回来）State = '
          '${identityHashCode(stateWideAgain)}');
      expect(
        identical(stateBefore, stateWideAgain), isTrue,
        reason: '★★★ 来回切换后 State 仍必须是**同一个实例** —— '
            '一次切换不重建、来回也不重建',
      );

      await drain(t);
    });

    testWidgets('★★ 播放器必须挂**稳定的 GlobalKey**', (t) async {
      await mountMediaPage(t);
      final pp = t.widget<PlayerPage>(find.byType(PlayerPage));
      expect(pp.key, isA<GlobalKey>(),
          reason: '★★ 播放器必须挂稳定的 `GlobalKey` ⇒ 无论 flex 怎么变、'
              '详情区在不在，它的 Element 位置不变 ⇒ State 复用');

      /*
       * ★ 稳定性判据：再推几帧（会触发重建），key **必须是同一个对象**。
       *   若有人写成 `key: GlobalKey()`（每次 build 新建）⇒ 每次重建都换 key
       *   ⇒ 播放器被重建（而那是本设计要避免的）。
       */
      final k1 = pp.key;
      await t.pump(const Duration(milliseconds: 100));
      final k2 = t.widget<PlayerPage>(find.byType(PlayerPage)).key;
      expect(identical(k1, k2), isTrue,
          reason: '★★★ 重建后 key 必须是**同一个对象** —— '
              '若写成 `key: GlobalKey()`（每次 build 新建）⇒ 每次都重建播放器');

      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 详情区确实是**真 DetailPage**（不是占位）
  // ═══════════════════════════════════════════════════════════════════

  group('② 详情区是真件（不是占位 widget）', () {
    testWidgets('★★ 树里必须有真 DetailPage', (t) async {
      await mountMediaPage(t);
      expect(find.byType(DetailPage), findsOneWidget,
          reason: '★★★ 合并页的**右侧栏**必须是**真** `DetailPage` —— '
              '否则"下详情"就是假的（用户看不到选集/换源/简介）');
    });

    testWidgets('★★ 详情区必须是 embedded（否则多一层 Scaffold）', (t) async {
      await mountMediaPage(t);
      final dp = t.widget<DetailPage>(find.byType(DetailPage));
      expect(dp.embedded, isTrue,
          reason: '★★ 合并页里的详情区必须 `embedded: true` —— '
              '否则它会画自己的 `Scaffold` + `SafeArea` + 返回按钮：'
              '① 多一层 Material 背景（盖住黑底）；'
              '② SafeArea 把"右侧栏"当整屏算内边距 ⇒ 边缘留白错位；'
              '③ 用户看到**两个**返回入口，且语义不一致');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ ★★★ "窗口 == 屏幕" 时详情区**仍须显示**
  //     （尺寸判据的结构性缺陷 —— 这条是"权威优先"的**决定性**判据）
  // ═══════════════════════════════════════════════════════════════════

  group('④ ★★★ 尺寸判据有缺陷 ⇒ 权威来源必须优先', () {
    testWidgets(
        '★★★ 窗口恰好等于屏幕时，详情区**仍须显示**（不得被误判成全屏）',
        (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条是"权威来源必须优先于尺寸判据"的**决定性**判据
       * ══════════════════════════════════════════════════════════════
       *
       * # 背景：`isWindowFullscreen` 是**有缺陷的度量判据**
       *
       * 它自己的文档就写了（`window_frame.dart` L221-231 逐字）：
       * > 它比较的是**同一个 `View`** 的 `physicalSize` 与 `display.size`
       * > ⇒ 在**任何"窗口恰好与显示同尺寸"的环境**里都会返回 true。
       * > ⚠️ 这**不是**"测试环境的巧合"，而是**度量判据的结构性缺陷**
       *
       * # 为什么代价不对称（决定优先级）
       *
       * ```text
       * WindowFrame（决定画不画圆角）      误判 ⇒ 少画一次圆角 ⇒ 只是不好看
       * MediaPage（决定详情区在不在）      误判 ⇒ 详情区**整块消失**
       *                                          ⇒ 用户看不到选集/换源/简介
       * ```
       * ⇒ ★★ 所以本页**必须**先问播放器（结构性来源），尺寸只在最后兜底。
       *
       * # 怎么造出"窗口 == 屏幕"
       *
       * `flutter_test` 的 `display.size` 恒为 **2400x1800**（引擎侧只读）
       * ⇒ 把 `physicalSize` 也设成 2400x1800（dpr=1.0）就复现了那个缺陷场景。
       *
       * ⚠️ ★★ **这条判据是我"差点漏掉"的**：我第一版用 1280x800，
       *    而那时 `isWindowFullscreen` 返回 **false**（因为 1280≠2400）
       *    ⇒ **缺陷场景根本没被造出来** ⇒ 我的红证"通过"了却没区分力。
       *    ⇒ 教训：**验证"兜底判据有缺陷"必须先造出那个缺陷场景**，
       *      否则测试只是在"缺陷不会发作"的环境里自证清白。
       */
      // ★ 关键：physicalSize == display.size ⇒ 尺寸判据会返回 true
      await mountMediaPage(t, window: const Size(2400, 1800), dpr: 1.0);

      expect(find.byType(DetailPage), findsOneWidget,
          reason: '★★★ 窗口恰好等于屏幕（尺寸判据误报全屏）时，详情区**仍须显示**。'
              '若这里失败 ⇒ 合并页把"尺寸兜底"当成了可信来源 ⇒ '
              '任何"窗口==屏幕"的场合用户都会**看不到选集/换源/简介**，'
              '而且日志里只有一行"详情区收起"，看不出是误判。'
              '★ 修法是"先问播放器（结构性来源），尺寸只在最后兜底"。');
    });

    testWidgets('★★ 上一条的**反面对照**：真的全屏时详情区**必须**收起', (t) async {
      /*
       * ★ 没有这条，上一条可能"永远绿"（例如详情区压根不响应全屏）。
       *   两条合起来才有区分力：
       * ```text
       * 窗口==屏幕（误报）⇒ 详情区**在**   ← 不能被缺陷判据骗到
       * 播放器说全屏      ⇒ 详情区**不在** ← 真的全屏必须生效
       * ```
       */
      await mountMediaPage(t, window: const Size(2400, 1800), dpr: 1.0);
      expect(find.byType(DetailPage), findsOneWidget,
          reason: '前置：误报场景下详情区应当在');

      // 真按 Enter ⇒ 播放器通知全屏 ⇒ 详情区必须收起
      await tapKey(t, LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byType(DetailPage), findsNothing,
          reason: '★★ 真全屏（播放器通知）时详情区**必须**收起 —— '
              '否则"全屏时只剩视频"不生效（判据⑥ 失败）');

      /*
       * ⚠️ 必须 drain：真 `PlayerPage`/`DetailPage` 会挂起定时器
       *    （`resolveStream` 的 120s timeout 等）⇒ 不推完就报
       *    `Failed assertion: '!timersPending'`。
       *    ★ 我第一版漏了它 ⇒ 该用例**因无关原因**失败
       *      （而不是因为断言不成立）—— 那会掩盖真正的结论。
       */
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 全屏：详情区**从树里消失**（判据⑥ 的结构化部分）
  // ═══════════════════════════════════════════════════════════════════

  group('③ 全屏时详情区必须**从树里消失**（真 Enter 路径）', () {
    testWidgets('★★★ 按 Enter ⇒ 只剩视频；再按 ⇒ 回到合并页', (t) async {
      /*
       * ★ 这是判据⑥（"全屏时只剩视频"）里**不需要屏幕**的那一半。
       *
       * ★★ 用**真路径**：真的按 Enter（与真机一致）——
       *    而不是从测试里直接改 `_explicitFullscreen`
       *    （那是"测试后门"，会让本测试与真机路径脱节）。
       *    真机链路：Enter ⇒ `_toggleFullscreen` ⇒
       *             `_onFullscreenChanged?.call(next)` ⇒ 合并页 `setState`。
       */
      await mountMediaPage(t);

      expect(find.byType(DetailPage), findsOneWidget,
          reason: '前置：窗口态详情区应当在树里');
      // ★ task-59：用"详情区槽位存在"代替"两个 Expanded"（见 `_detailSlot` 注释）
      expect(_detailSlot(t), isNotNull, reason: '前置：窗口态详情区应当占着第 1 个槽位');

      // ── 进全屏 ──
      await tapKey(t, LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byType(DetailPage), findsNothing,
          reason: '★★★ 全屏后详情区必须**从树里消失**（"全屏时只剩视频"）—— '
              '若它还在，用户全屏时右侧栏仍然占着一块画面');
      expect(_expanded(t).length, 1,
          reason: '★★★ 全屏后外层 Row 只能剩 1 个 Expanded（视频铺满）');

      // ── 退出全屏 ──
      await tapKey(t, LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byType(DetailPage), findsOneWidget,
          reason: '★★ 退出全屏必须回到合并页（详情区重新出现）—— '
              '否则用户退出全屏后再也看不到选集/换源');

      await drain(t);
    });

    testWidgets('★★★ 全屏切换**不得重建播放器**（key 身份不变）', (t) async {
      /*
       * ★★★ 风险① 的结构化判据（真机上我用 `[PLAYER] open:` 计数验证过，
       *      这里用 **key 身份**验证 —— 两者互补）。
       *
       * 若全屏时换了父级（如 `_fullscreen ? player : Column([...player...])`），
       * Element 会卸载 ⇒ 新 State ⇒ **重建播放器**。
       * ⇒ 判据：全屏**前后** `PlayerPage` 的 `key` 是**同一个对象**，
       *   且它在树里**始终存在**（没被移除过）。
       */
      await mountMediaPage(t);

      final kBefore = t.widget<PlayerPage>(find.byType(PlayerPage)).key;
      expect(kBefore, isA<GlobalKey>(), reason: '前置：播放器应当挂 GlobalKey');

      await tapKey(t, LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byType(PlayerPage), findsOneWidget,
          reason: '★★★ 全屏时播放器必须**仍在树里**（"只剩视频"= 只剩它）');
      final kFull = t.widget<PlayerPage>(find.byType(PlayerPage)).key;
      expect(identical(kBefore, kFull), isTrue,
          reason: '★★★ 全屏前后播放器的 key 必须是**同一个对象** ⇒ '
              'Element 未卸载 ⇒ State 复用 ⇒ **播放器没被重建**。'
              '若这里 false ⇒ 全屏时换了父级/位置 ⇒ 真机上会黑屏重载');

      await tapKey(t, LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));

      final kBack = t.widget<PlayerPage>(find.byType(PlayerPage)).key;
      expect(identical(kBefore, kBack), isTrue,
          reason: '★★★ 退出全屏后 key 仍必须是同一个对象（来回都没重建）');

      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ "能滚"（判据③ 的另一半）—— 详情区可滚、**视频区不可滚**
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ 能滚：详情区可滚，视频区**不可**滚', () {
    testWidgets('★★★ 视频区**不得**被包在可滚容器里（滚动不会带着画面跑）', (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★ 这条是"能滚"里**能真验**的那一半（不需要详情加载成功）
       * ══════════════════════════════════════════════════════════════
       *
       * # 为什么"视频区不可滚"必须验
       *
       * ```text
       * 若视频区被包在可滚容器里 ⇒ 用户滚详情时**画面跟着跑**
       * ⇒ "上播放器"就废了（播放器会滑出屏幕）
       * ```
       */
      await mountMediaPage(t);

      final rBefore = t.getRect(find.byType(PlayerPage));
      debugPrint('[MEDIA-SCROLL] 视频区 = $rBefore');

      // ★ 视频区的祖先链里**不得**有 Scrollable
      final videoScrollable = find.ancestor(
        of: find.byType(PlayerPage),
        matching: find.byType(Scrollable),
      );
      expect(videoScrollable, findsNothing,
          reason: '★★★ 视频区**不得**被包在可滚容器里 —— '
              '否则滚详情时画面会跟着跑，"上播放器"就废了');

      expect(rBefore.top, closeTo(0, 0.5),
          reason: '★ 视频区必须**贴在顶部**（y=0）—— 它是左栏，纵向铺满');
    });

    testWidgets('★★ 详情区：外层**固定**，滚动只发生在选集视口内部', (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ⚠️ 为什么这条是**源码门控**而不是 widget 断言（诚实说明）
       * ══════════════════════════════════════════════════════════════
       *
       * 我第一版写的是 widget 断言：
       * ```dart
       * find.descendant(of: find.byType(DetailPage),
       *                 matching: find.byType(Scrollable))
       * ```
       * ⇒ **失败**（`Found 0 widgets with type "Scrollable"`）。
       *
       * ★ 原因**不是**布局错，而是**测试环境限制**：
       *   `DetailPage._init` 走 `SourinApi.getDetail`（真 IPC / FFI）
       *   ⇒ 测试环境里拿不到数据 ⇒ 页面停在"加载中/错误"分支
       *   ⇒ 那个分支**没有**选集视口（只有 `CircularProgressIndicator` / `_ErrorView`）
       *
       * ⇒ ★★ 所以"详情区怎么滚"在**本环境**无法用 widget 断言验证
       *   （除非 mock IPC —— 而 Lead 明确要求**不 mock**：
       *     "测试专用抽象是假绿的温床"）。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02：**判据被反转了**（这条原来是写反的）
       * ══════════════════════════════════════════════════════════════
       *
       * 改前（task-62 时代）：
       * ```dart
       * expect(dp.contains('return ListView('), isTrue,
       *     reason: '详情页的内容必须渲染在 ListView 里（可滚）……'
       *             '若有人把它换成 Column ⇒ 内容会被裁掉且滚不动');
       * ```
       *
       * ★ 那条 reason 现在是**反的**。Owner 原话（逐字）：
       * > 右侧整体固定，不能上下滚动，只有选集部分内部可以滚动
       *
       * 实现已按此改成：`detail_page.dart:1800 return LayoutBuilder(`
       * → `:1953 return Column(`，选集视口才是唯一的可滚体
       * （`:2161-2169` `SizedBox(key: _epsViewportKey, height: epsH, …)`
       *  → `Scrollbar(controller: _epsCtrl, …)` → `SingleChildScrollView(controller: _epsCtrl, …)`）。
       * `:1857-1861` 的注释写明这是**故意**的：
       * 「外层没有 Scrollable 了 ⇒ _scrollEpisodesIntoView 结构上**不可能**滚走整页」
       * （本仓 task-3 同族事故：`Scrollable.ensureVisible` 会向上遍历所有 Scrollable）。
       *
       * ⇒ ★★ **照旧 reason 改回去，就是把 Owner 的需求做反**：
       *   "把 Column 换成 ListView" 正是现在**要禁止**的改动。
       *
       * ★ 契约方向：**结构上不可能** > 靠断言禁止。
       *   旧契约「外层**是** ListView，但纪律要求别去滚它」← 纪律会被后人破坏；
       *   新契约「外层**压根没有**可滚体」← 没有可滚的东西。
       *   所以这条不是"放宽"，是**收紧**。
       *
       * ★ 本条只做**全文件**层面的门控；更严格的**方法体作用域**版本
       *   （按大括号配平取 `_buildBody` / `_bodyEpisodes` 的方法体再断言）
       *   已存在于 `t61_panel_scroll_test.dart`（task-64）—— 不在此处重复实现。
       */
      final dp = stripComments(
        File('lib/ui/detail_page.dart').readAsStringSync(),
      );
      expect(dp.contains('return ListView('), isFalse,
          reason: '★★★ 详情页外层**不许**是 `ListView` —— Owner 要求'
              '「右侧整体固定，不能上下滚动，只有选集部分内部可以滚动」。'
              '★ 注意：这条断言的方向与 task-62 时代**相反**，'
              '照旧 reason（"必须渲染在 ListView 里"）改回去就是把需求做反。'
              '★ 已剥注释：`:1842` 的历史注释里还留着 `return ListView(`，'
              '不剥的话这条会**假红**');
      expect(dp.contains('SingleChildScrollView('), isTrue,
          reason: '★ 滚动必须由**选集视口**提供（`_bodyEpisodes` 里那个'
              ' `SingleChildScrollView(controller: _epsCtrl, …)`）—— '
              '若整页一个可滚体都没有，选集多的作品就看不到下面的集数了');
      expect(dp.contains('controller: _epsCtrl'), isTrue,
          reason: '★ 选集视口的滚动控制器必须是 `_epsCtrl` —— '
              '它是"只滚选集、不滚外层"那条纪律的唯一抓手');
      expect(dp.contains('Scrollable.ensureVisible'), isFalse,
          reason: '★★★ 不许用 `Scrollable.ensureVisible` —— 它会**向上遍历所有** '
              'Scrollable（本仓 task-3 同族事故：把整页滚走，用户看到"页面自己跳了一下"）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ ★★★ task-59 根因①：窗口态底色必须**跟随主题**（不再是硬编码黑）
  // ═══════════════════════════════════════════════════════════════════

  group('⑥ task-59 根因① 窗口态底色跟随主题', () {
    testWidgets('★★★ 亮色主题：窗口态底色 == colorScheme.surface，且**不是**纯黑',
        (t) async {
      /*
       * # 为什么必须**读渲染值**而不是只断言源码里有 `surface`
       * ```text
       * 源码断言只能证明"写了 `Theme.of(context).colorScheme.surface`"
       *   ⇒ **证不出**它真的成了 `Scaffold` 的底色。
       * ⇒ 必须读 `Scaffold.backgroundColor` 的**真值**。
       * ```
       *
       * # Owner 报的 bug（Lead 实测）
       * ```text
       * 详情区标题文字最亮像素 = #1E2028（= LightTokens.textPrimary）
       * 背后背景               = #000000
       * ⇒ WCAG 对比度 = **1.29 : 1**（几乎完全不可见）
       * 整页纯黑占比 = 66.8%   ⇒ 这就是「只有黑色」
       * ```
       */
      await mountMediaPage(t, brightness: Brightness.light);

      final sc = t.widget<Scaffold>(find.byType(Scaffold).first);
      final ctx = t.element(find.byType(MediaPage));
      final surface = Theme.of(ctx).colorScheme.surface;

      debugPrint('[MEDIA-BG] Scaffold.backgroundColor=${sc.backgroundColor} '
          'surface=$surface brightness='
          '${Theme.of(ctx).brightness}');

      expect(sc.backgroundColor, isNot(equals(Colors.black)),
          reason: '★★★ 窗口态**不得**是纯黑 —— Owner 报的正是「进来之后只有黑色」。'
              '实测 Scaffold.backgroundColor=${sc.backgroundColor}。'
              '若为 Colors.black ⇒ 详情区（用主题令牌画）会落在纯黑上 ⇒ '
              '亮色主题下 WCAG 只有 1.29:1');
      expect(sc.backgroundColor, equals(surface),
          reason: '★★★ 窗口态底色必须**等于主题的 surface** —— '
              '实测 ${sc.backgroundColor} vs surface=$surface。'
              '若不等 ⇒ 详情区会落在与它不匹配的底色上');
    });

    testWidgets('★★ 深色主题：窗口态底色也 == 该主题的 surface（两个主题都对）',
        (t) async {
      /*
       * ★ 这条守"别把修法写成只对亮色有效"。
       *   Lead 的取证文档写明：**两个主题下都坏，只是坏法不同**
       *   （亮色 ⇒ 1.29:1 不可见；深色 ⇒ 可读但仍 69.3% 纯黑、无层次）。
       * ⇒ 修法必须对**两个**主题都成立。
       */
      await mountMediaPage(t);

      final sc = t.widget<Scaffold>(find.byType(Scaffold).first);
      final ctx = t.element(find.byType(MediaPage));
      final surface = Theme.of(ctx).colorScheme.surface;

      debugPrint('[MEDIA-BG] Scaffold.backgroundColor=${sc.backgroundColor} '
          'surface=$surface');

      expect(sc.backgroundColor, equals(surface),
          reason: '★★ 窗口态底色必须跟随**当前主题**的 surface（不是硬编码）—— '
              '实测 ${sc.backgroundColor} vs surface=$surface');
    });

    testWidgets('★★★ 全屏态：底色**仍必须是** Colors.black（别把黑底全删了）',
        (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★ 这条是"修一个坏一个"的防线
       * ══════════════════════════════════════════════════════════════
       *
       * 最省事的"修法"是把 `Colors.black` **整个删掉** ⇒ 上面两条也会绿。
       * 但那样全屏时视频周围会变成**浅灰**（主题 surface）——
       * 而全屏的正确观感是**纯黑**（`Colors.black` 在**播放页**的假设是对的）。
       *
       * ⇒ 判据：全屏时底色 = `Colors.black`；窗口态 = `surface`。
       *   **两者必须不同**（若相同，说明三目退化成了常量）。
       */
      await mountMediaPage(t);

      final ctx = t.element(find.byType(MediaPage));
      final surface = Theme.of(ctx).colorScheme.surface;
      final bgWindow = t.widget<Scaffold>(find.byType(Scaffold).first)
          .backgroundColor;
      debugPrint('[MEDIA-BG] 窗口态 = $bgWindow（应 = surface=$surface）');

      // 进全屏（真路径：按 Enter）
      await tapKey(t, LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byType(DetailPage), findsNothing,
          reason: '前置：全屏后详情区应当消失');
      final bgFull = t.widget<Scaffold>(find.byType(Scaffold).first)
          .backgroundColor;
      debugPrint('[MEDIA-BG] 全屏态 = $bgFull（应 = Colors.black）');

      expect(bgFull, equals(Colors.black),
          reason: '★★★ 全屏时底色必须仍是 **Colors.black** —— '
              '实测 $bgFull。全屏时整页都是视频，周边应是纯黑；'
              '若这里是主题 surface ⇒ 浅灰边框，观感变差');
      expect(bgFull, isNot(equals(bgWindow)),
          reason: '★★ 全屏态与窗口态的底色必须**不同** —— '
              '若相同 ⇒ 三目 `fullscreen ? Colors.black : surface` '
              '退化成了常量（修 ① 时把黑底整个删了）');

      await drain(t);
    });
  });
}
