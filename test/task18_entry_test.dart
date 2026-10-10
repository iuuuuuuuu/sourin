// ═══════════════════════════════════════════════════════════════════════
//  task-18：一级页两个入口 + 两个二级页的「真断言」守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件（Lead 冻结硬条件 · team-message-64cd54e0 裁决 B）
//
// ① 一级页必须能 `find` 到「播放与下载」与「触摸手势」两行 —— **三端形态各跑一次**
// ② 点进去后二级页标题分别是「播放与下载」与「播放手势」
//    ★ 后者**故意**与入口名不同 —— android-phone 抓到过这个陷阱，
//      这个文件把「二级页上没有『触摸手势』四个字」钉成断言。
// ③ 并发滑杆 `min == 0 && max == 8 && divisions == 8 && onChanged != null`
// ④ 至少一条**能红**的断言（不是恒真）—— 变异记录见文件尾。
//
// # 这个文件测的是「用户能不能走到」，不是「源码里有没有那几行字」
//
// 源码静态断言（`grep 到 '播放与下载' 就算过`）挡不住三类真事故：
//   a) 入口被某个 `if (Device.isTouchOnly)` 包住 ⇒ 桌面端根本看不到；
//   b) 点进去是空白页 / 抛异常被换成 ErrorWidget ⇒ 用户看不到任何东西；
//   c) 二级页标题写错（入口叫「触摸手势」、页面标题叫「播放手势」——
//      这是**故意**的，但必须有测试钉住它，否则下一个人会"顺手改一致"）。
// 本文件全部走**真渲染 + 真点击 + 真导航**，所以三类都能红。
//
// # 仪器关键（照抄 test/zz_t53s_settings_live_toggle_test.dart，理由见那边文件头）
//
// 1) `sourin_core.dll` 必须**先按绝对路径预载** —— `lib/core/ffi.dart:169`
//    只认裸名 open；缺 DLL 时 `settings_page.dart:2189` 的
//    `subtitle: '${SourinApi.version} · 架构与设备信息'` 会抛 ⇒ 整个 ListView
//    被换成 ErrorWidget ⇒ 一级页什么都找不到（**那不是入口坏了**）。
//    DLL 不存在 ⇒ `skip:`（不是失败）。
// 2) `testWidgets` 的测试体跑在 FakeAsync zone 里 ⇒ 裸 await 真 FFI **永不返回**
//    （实测 `TimeoutException after 0:10:00`）⇒ 真异步一律走 `tester.runAsync`。
// 3) `SettingsEntryRow` 里是 `InkWell`，**必须**有 `Material` 祖先，
//    否则抛 `No Material widget found` ⇒ 建树中断 ⇒ 读数全废（`_host` 里给）。
// 4) 二级页比 900px 视口高 ⇒ 控件要先 `scrollUntilVisible` 才点得到
//    （仓内先例 test/player_capability_test.dart:1108-1113）。
//
// # 绝不碰 media_kit
//
// `dart_test.yaml` 的 `native-media` 标签注明：加载 `libmpv-2.dll` 会让
// flutter_tester.exe **偶发 native 崩溃**（访问违例 c0000005，退出码 79，
// 实测 6/25，`--concurrency=1` 也不能避免）⇒ 本文件不调
// `MediaKit.ensureInitialized()`、不挂 `PlayerPage`。
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/player_gestures.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/settings/playback_page.dart';
import 'package:sourin_spike/ui/settings/touch_gestures_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

const String kTag = '[T18E]';
void log(String s) => debugPrint('$kTag $s');

/// ★ 单个用例的硬超时 —— 一个能静默挂 10 分钟的测试比失败的测试更贵
const Timeout kTimeout = Timeout(Duration(minutes: 5));

/// 交付件里那颗 DLL（`lib/core/ffi.dart:169` 只认**裸名**，所以要我们自己载）
const String _dllRel = r'build\windows\x64\runner\Release\sourin_core.dll';

/// ★ 环境前提：DLL 在不在。不在就**跳过**（不是失败）。
final bool _dllReady = File(_dllRel).existsSync();

/// 把 DLL 按**绝对路径**载进本进程 ⇒ 之后 `ffi.dart` 的裸名 open 命中它
void _preloadCoreDll() {
  if (!_dllReady) return;
  DynamicLibrary.open(File(_dllRel).absolute.path);
  log('DLL 预加载 = OK（${File(_dllRel).absolute.path}）');
}

// ═══════════════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════════════

/// ★ 必须给 `Material` 祖先 —— `SettingsEntryRow` 的 `InkWell`、
///   二级页的 `OutlinedButton`/`Slider` 都要它。
Widget _host(Widget child, {Size size = const Size(1280, 900)}) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Builder(
      builder: (context) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(size: size),
          child: Material(
            type: MaterialType.transparency,
            child: Scaffold(body: child),
          ),
        );
      },
    ),
  );
}

/// 收走并**记下**异常（不静默：第一条会打出来）
void _claim(WidgetTester tester, String where) {
  var n = 0;
  while (true) {
    final e = tester.takeException();
    if (e == null) break;
    n++;
    if (n <= 2) {
      log('$where| ★ 收走异常: ${e.toString().split('\n').first}');
    }
  }
}

/// 命中数（find 本身抛异常时返回 -1，绝不让仪器问题伪装成断言失败）
int _count(Finder f) {
  try {
    return f.evaluate().length;
  } catch (_) {
    return -1;
  }
}

/// 给真事件循环开窗口 + 抽干微任务（供 widget 自己发起的 FFI 推进）
Future<void> _settle(WidgetTester tester, {int rounds = 8, int ms = 300}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump();
    _claim(tester, 'settle$i');
  }
}

/// 滚到某个控件 + 推进两帧（`scrollUntilVisible` 收尾会 ensureVisible）
///
/// ★ `scrollable:` 传的 finder **必须恰好命中 1 个** —— `widget<Scrollable>`
///   对多个命中会抛 StateError，所以这里照抄仓内先例用 `.first`。
/// ★★ 2026-10-04 修复（Lead 裁决 · A.desktop 假红）
///
/// 原先这里有一道「先查命中数，`_count(f) == 0` 就跳过滚动」的守卫 ——
/// 它是**错**的：一级页 `ListView` 是懒建的，启动核心后内容变高
/// （Lead 实测 `maxScrollExtent 368 → 649.5`），「触摸手势」入口行在
/// 1280×900 视口下**根本没被建出来** ⇒ 命中数恰好就是 0 ⇒ 守卫直接
/// return ⇒ 永远滚不到 ⇒ 断言读到 0 假红。
///
/// 现在**先滚再判**：`scrollUntilVisible` 内部边滚边找（`dragUntilVisible`），
/// 只有它抛 `StateError: Bad state: No element` 时才退回「直接跳到底 +
/// ensureVisible」，并把每一次退路都打进日志 —— 绝不再用「没建出来就放弃」。
Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  // ★★ 2026-10-04 第二版修复（真跑撞出来的方向 bug）
  //
  // 第一版只做了「`scrollUntilVisible` 抛异常 ⇒ 跳到底再 ensureVisible」，
  // 在 A.touchOnly 上炸了：滚到底之后要再滚回「播放与下载」，而
  // `scrollUntilVisible(f, delta)` 的 `delta` 是**带方向**的
  // （`axisDirection == down` ⇒ moveStep = (0, -delta) ⇒ 只往下扫），
  // 正 delta 永远找不到**上方**的条目 ⇒ `tester.getRect(e1)` 抛
  // `Found 0 widgets with text "播放与下载"`。
  //
  // ⇒ 现在的次序是：**没建出来就先回到顶**，再只向**前**扫
  //   （一级页 ListView 与二级页 CustomScrollView 的条目都在顶之下，
  //    所以「从顶往前扫」一定能覆盖到）；正向扫不到再跳到底兜一次。
  if (_count(f) == 0) {
    await _jumpScroll(tester, toEnd: false, where: 'scroll');
  }
  try {
    await tester.scrollUntilVisible(
      f,
      120,
      scrollable: find.byType(Scrollable).first,
    );
  } catch (e) {
    log('★ 正向滚动没扫到：${e.toString().split(String.fromCharCode(10)).first}'
        ' ⇒ 跳到底兜一次');
    await _jumpScroll(tester, toEnd: true, where: 'scroll');
    if (_count(f) != 0) {
      try {
        await tester.ensureVisible(f);
      } catch (e3) {
        log('★ ensureVisible 也失败：${e3.toString().split(String.fromCharCode(10)).first}');
      }
    }
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  _claim(tester, 'scroll');
}

/// 直接把滚动位置跳到顶 / 底（懒建列表里「让目标条目先被建出来」用）
///
/// ★ 只用 `ScrollableState.position.jumpTo` —— 它不经过手势、不触发 fling，
///   推一帧就生效；比反复 `drag` 稳定得多（`drag` 的步长依赖视口大小）。
Future<void> _jumpScroll(WidgetTester tester,
    {required bool toEnd, required String where}) async {
  try {
    final pos = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final target = toEnd ? pos.maxScrollExtent : pos.minScrollExtent;
    pos.jumpTo(target);
    await tester.pump();
    log('★ 跳到${toEnd ? '底' : '顶'} offset=$target'
        '（视口 ${pos.viewportDimension} / 可滚 ${pos.maxScrollExtent}）');
  } catch (e) {
    log('★ _jumpScroll($where) 失败：${e.toString().split(String.fromCharCode(10)).first}');
  }
}
/// ★★ 按帧推进直到某个 finder **离场**（跨页计数断言前必用）
///
/// # 为什么需要它（真机实测的假红）
///
/// 首跑（442 行的第一版）A 组三个用例**同一行**断言红：
/// `expect(_count(find.text('播放与下载')), 1)` ⇒ Actual **2**。
/// 根因**不是入口坏了**，是**转场没跑完**：
/// ```text
/// routes.dart:293-298   case AnimationStatus.completed:
///                         overlayEntries.first.opaque = opaque;   // ← 只有跑完才置真
///                       case AnimationStatus.forward / reverse:
///                         overlayEntries.first.opaque = false;
/// overlay.dart:888-917  _OverlayState.build: entry.opaque 为真才把**后面的**
///                       旧路由移出 onstage（skipCount）
/// overlay.dart:1061-1062  children.skip(theater.skipCount).forEach(visitor)
///                       ← 这就是 debugVisitOnstageChildren = 默认 finder 的范围
/// ```
/// ⇒ 转场没跑完 ⇒ 旧路由仍在 onstage ⇒ 一级页入口行与二级页标题**同时**可见
///   ⇒ 计数 = 2（**用户眼里根本不存在这个问题**：用户看到的是 1）。
///
/// 转场时长：`page_transitions_theme.dart:470-473`
/// `static const int kTransitionMilliseconds = 450;`（**大于**原来只推的 400ms），
/// 而且置真后还要**下一帧**才重建 Overlay。
///
/// ★ 判据用「**旧路由真的离场**」而不是「推够固定时长」——
///   这样将来任何时长/缓动改动都不会再造成假红/假绿。
Future<int> _pumpUntilGone(WidgetTester tester, Finder gone,
    {int maxFrames = 60, int ms = 50}) async {
  var n = 0;
  while (n < maxFrames && _count(gone) != 0) {
    await tester.pump(Duration(milliseconds: ms));
    n++;
  }
  _claim(tester, 'gone');
  return n;
}

/// 点一个控件并推进导航动画
///
/// ★ 这里只推**两帧**（`pump()` + `pump(450ms)`，450 = 上面的转场时长）。
///   跨页**计数**断言之前**必须**再 `_pumpUntilGone(旧路由)`。
Future<void> _tapAndSettle(WidgetTester tester, Finder f, String where) async {
  await tester.tap(f, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  _claim(tester, where);
}

/// 用例收尾：先拆树再推长时长（排掉二级页 `_flash` 的 3 秒一次性 Timer）
Future<void> _teardownTree(WidgetTester tester, String where) async {
  await tester.pumpWidget(const SizedBox.shrink());
  _claim(tester, '$where|teardown');
  await tester.pump(const Duration(seconds: 5));
  _claim(tester, '$where|teardown');
}

void main() {
  final dataDir = Directory('.probe/t18e_data');

  setUpAll(() async {
    /*
     * ★★★ T10（task-35）2026-10-10 改：DLL 不在 = **另一种被测环境**，不再跳过
     *
     * ```text
     * 旧版：`if (!_dllReady) return;` + 每个用例 `skip: !_dllReady`
     *       ⇒ CI 上（测试步骤跑在构建**之前**、core dll 还没产出）整个文件
     *         只打印 `+0 ~5: All tests skipped.` 并且 **exit 0** —— 假绿：
     *         门禁看起来在跑，其实一条断言都没执行过。
     * 新版：`_dllReady` 只当**环境判别器**。缺件态照样把一级页/二级页真渲染、
     *       真点击、真断言（缺件态有自己的可断言契约，见 A 组与 B/C 组）。
     * ```
     *
     * ★ 为什么缺件态**先** `UiPrefs.debugResetForTest()` 再返回：
     *   B/C 两个用例只读 `ClipDownloader` / `PlayerGestures` / `UiPrefs`
     *   这些**纯 Dart 静态**，DLL 在不在都不影响它们真跑；而它们的确定性
     *   依赖「偏好从空开始」这条前置。
     */
    if (!_dllReady) {
      log('★★ T10 缺件态：$_dllRel 不存在 —— **不跳过**，改跑缺件态契约'
          '（一级页/二级页真渲染 + 版本行降级文案 + B/C 纯静态门禁）');
      UiPrefs.debugResetForTest();
      /*
       * ★★ 两态前置必须**对齐**（否则不是在测产品，是在测仪器）。
       *
       * `PlaybackSettingsPage._refreshEnv()`（`playback_page.dart:466-474`）
       * 走 `_envFields()` ⇒ `ClipDownloader.dataDir()`（`clip_download.dart:531-554`）。
       * 在位态下它命中 `_dataDirCache`（下面 `debugSetDataDir` 灌进去的）
       * ⇒ 微任务内就返回；缺件态若不灌，它会去走
       * `Platform.environment['APPDATA']` + `Directory.create()` —— **真磁盘 I/O**，
       * 而 widget 测试跑在 fake async 区里，那个 future 永远不会完成
       * ⇒ 「环境信息」卡片永远停在「读取中…」（实测踩到：
       * `Expected: <1> Actual: <0>`，而在位态同一条是绿的）。
       * ⇒ 缺件态也把数据目录指到隔离目录，两态只差
       *   「核心加载了没有」这**一个**变量。
       */
      ClipDownloader.debugSetDataDir(dataDir.absolute.path);
      return;
    }
    _preloadCoreDll();

    // ★ 每次跑前删净 ⇒ 绝不碰 Owner 的真实 profile
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    dataDir.createSync(recursive: true);
    try {
      final started = await SourinApi.start(dataDir.absolute.path);
      log('start() = $started');
    } catch (e) {
      log('★ SourinApi.start() 失败: $e');
    }

    // ★ 偏好从**空**开始（`debugResetForTest` 只清内存、不碰磁盘）
    //   —— 这样「并发=4」「双击=10 秒」这些读数才有确定性。
    UiPrefs.debugResetForTest();
    // ★ 数据目录指到隔离目录（`null` = 恢复自动解析，见 tearDownAll）
    ClipDownloader.debugSetDataDir(dataDir.absolute.path);
  });

  tearDownAll(() {
    ClipDownloader.debugSetDataDir(null);
    if (dataDir.existsSync()) {
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  A. 三端形态 × 一级页两个入口 × 两个二级页（Lead 裁决 B ①②）
  // ═══════════════════════════════════════════════════════════════════
  for (final kind in DeviceKind.values) {
    testWidgets('A.${kind.name} 一级页两个入口 → 二级页标题 → 返回一级页',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Device.overrideKind(kind);
      addTearDown(() => Device.overrideKind(null));
      UiPrefs.debugResetForTest();

      final tag = 'A.${kind.name}';
      await tester.pumpWidget(_host(const SettingsPage()));
      _claim(tester, '$tag|pump1');
      await tester.pump();
      _claim(tester, '$tag|pump2');
      log('$tag| 首屏转圈 = ${_count(find.byType(CircularProgressIndicator))}');
      await _settle(tester, rounds: 10);
      log('$tag| 加载后：转圈 = ${_count(find.byType(CircularProgressIndicator))}'
          '  ListView = ${_count(find.byType(ListView))}'
          '  ErrorWidget = ${_count(find.byType(ErrorWidget))}');

      // ★★ ① 一级页两个入口
      //   ★ 入口**不**按端隐藏（settings_page.dart:2016-2019 说明了理由：
      //     触摸手势页自己会渲染「仅在触摸端可用」，比藏掉入口更容易理解）
      //
      // ★★ 2026-10-04 修复（Lead 裁决：根因 = 测试滚动手法，不是产品缺陷）
      //   启动核心后一级页内容变高（Lead 独立实测 `maxScrollExtent
      //   368 → 649.5`，`.probe\t18_diag2_test.dart`），桌面端 `ListView`
      //   懒建只建到「播放与下载」为止 ⇒「触摸手势」那一行**根本没被建出来**，
      //   `find.text` 默认只遍历 onstage ⇒ 读到 0。滚到底后 = 1。
      //   ⇒ 两条入口断言之前**都**先滚到该行可见，不再赌懒建时机。
      await _scrollTo(tester, find.text('播放与下载'));
      expect(_count(find.text('播放与下载')), 1,
          reason: '$tag| 一级页必须有**恰好一个**「播放与下载」入口行');
      await _scrollTo(tester, find.text('触摸手势'));
      expect(_count(find.text('触摸手势')), 1,
          reason: '$tag| 一级页必须有**恰好一个**「触摸手势」入口行');

      // ★★ 反空转自检（Lead 裁决 B ④「断言必须能红」的最小形式）
      //   若下面这两条恒真，说明 finder 根本没接上树 ⇒ 后面所有 == 0 的
      //   断言都是**空转**（恒绿）。先证明 finder 有分辨力，再用它下判断。
      expect(_count(find.byType(SettingsPage)), 1,
          reason: '$tag| 自检：一级页本来就在树上（这条也红 = 仪器问题，不是入口问题）');
      expect(_count(find.text('★不存在的入口★')), 0,
          reason: '$tag| 自检：不存在的文案必须命中 0 —— 否则 _count/find.text 恒真');

      // ★★ ②a 「播放与下载」→ 二级页标题同名
      final e1 = find.text('播放与下载');
      await _scrollTo(tester, e1);
      log('$tag| 入口矩形 = ${tester.getRect(e1)}');
      await _tapAndSettle(tester, e1, '$tag|nav1');
      final f1 = await _pumpUntilGone(tester, find.byType(SettingsPage));
      log('$tag| nav1 补推 $f1 帧后：一级页 SettingsPage = ${_count(find.byType(SettingsPage))}'
          '  二级页 PlaybackSettingsPage = ${_count(find.byType(PlaybackSettingsPage))}'
          '  标题命中 = ${_count(find.text('播放与下载'))}'
          '  「返回设置」= ${_count(find.text('返回设置'))}');
      // ★★ 这条直指上面那段机制：转场跑完后一级页必须**离场**
      expect(_count(find.byType(SettingsPage)), 0,
          reason: '$tag| ★ 转场跑完后一级页必须离场（否则跨页同名文本会数成 2）');
      expect(_count(find.byType(PlaybackSettingsPage)), 1,
          reason: '$tag| 点入口必须真的推进到 PlaybackSettingsPage');
      expect(_count(find.text('播放与下载')), 1,
          reason: '$tag| 二级页标题 = 「播放与下载」（与入口名一致）');
      expect(_count(find.text('返回设置')), 1,
          reason: '$tag| 二级页必须有**恰好一个**返回入口'
              '（settings_sub_page.dart:423-431 的 OutlinedButton）');
      expect(_count(find.text('并发数')), 1,
          reason: '$tag| 二级页必须真的画出并发数滑杆那一行');
      /*
       * ★ 2026-10-09 改（Owner 第 20 条引入第二个滑杆之后）
       *
       * 原断言是 `expect(_count(find.byType(Slider)), 1)`，本意是
       * 「**片段**并发滑杆恰有一个」（防止误画成两个同类滑杆）。
       * 第 20 条给这一页**有意**加了第二个「整片下载并发」滑杆 ⇒
       * 全局计数天然变 2，这条会红 —— 但**红的不是行为，是断言的粒度**。
       *
       * 所以改成按语义定位：先锚到「片段下载并发」块，再断言它里面
       * 恰有一个 Slider，且这个 Slider 的档位就是 ClipDownloader 的档位。
       * ⇒ 原意（不多不少一个片段并发滑杆）**完整保留**，且不再被
       *   别的滑杆的增减误伤。
       */
      final clipSlider = find.descendant(
        of: find.ancestor(
          of: find.text('片段下载并发'),
          matching: find.byType(SettingsBlock),
        ),
        matching: find.byType(Slider),
      );
      expect(_count(clipSlider), 1,
          reason: '$tag| ★ 片段下载并发块里必须恰有一个滑杆'
              '（页面整体现在有两个滑杆：片段 + 整片，见 Owner 第 20 条）');
      final clipW = tester.widget<Slider>(clipSlider);
      expect(clipW.max, 8,
          reason: '$tag| ★ 这个滑杆必须真的是片段那个（档位 0..8）');

      /*
       * ★★★ T10（task-35）2026-10-10 新增：**缺件态**下这一页也必须有一条
       *   真能红的契约 —— 否则 CI 上整个文件是空转（旧版 `+0 ~5 skipped`）。
       *
       * 缺件态下 `SourinApi.version` ⇒ `SourinCore.version` ⇒ `_ensureBound()`
       * 抛 `Invalid argument(s): Failed to load dynamic library
       * 'sourin_core.dll': The specified module could not be found.
       * (error code: 126)`，被 `playback_page.dart:433-439` 的 catch 接住
       * ⇒「版本」那一行的值必须以「读不到（核心未加载：」开头。
       * 在位态下这一行必须是真版本号 ⇒ 反过来断言它**不**是降级文案。
       * 两种环境下这条都会红（改降级文案 / 改 catch 分支 / 让 version 不再抛）。
       *
       * ★ 值在 `SelectableText` 里（`settings_kit.dart:693-700`），
       *   不是 `Text` —— 用 `find.text` 找值会永远找不到（假红）。
       *
       * ★★ 为什么必须先 `_scrollTo`：这一页是高于 900px 的
       *   `CustomScrollView`（`settings_sub_page.dart`），「环境信息」卡片在底部
       *   ⇒ 不滚的话它根本没被建出来。第一次插进去时就是
       *   这么假红的（实测 `Expected: <1> Actual: <0>`）—— 工具问题，
       *   不是产品问题。先滚到它可见再读。
       */
      final verRow = find.ancestor(
        of: find.text('版本'),
        matching: find.byType(SettingsInfoRow),
      );
      await _scrollTo(tester, verRow);
      expect(_count(verRow), 1,
          reason: '$tag| ★ 二级页「环境信息」里必须有「版本」那一行');
      final verText = tester
          .widget<SelectableText>(find.descendant(
            of: verRow,
            matching: find.byType(SelectableText),
          ))
          .data!;
      log('$tag| 版本行 = $verText');
      if (!_dllReady) {
        expect(verText, startsWith('读不到（核心未加载：'),
            reason: '$tag| ★★ 缺件态：核心版本必须**如实降级**成'
                '「读不到（核心未加载：…）」，不许编一个版本号出来');
        expect(verText, contains('sourin_core.dll'),
            reason: '$tag| ★ 降级文案里必须带上是哪个库没加载');
      } else {
        expect(verText, isNot(startsWith('读不到')),
            reason: '$tag| ★★ 在位态：核心已加载，版本行不该再是降级文案');
      }

      // 返回一级页（闭环：入口可达 ⇒ 也能回来）
      await _tapAndSettle(tester, find.text('返回设置'), '$tag|back1');
      final f2 = await _pumpUntilGone(tester, find.byType(PlaybackSettingsPage));
      log('$tag| back1 补推 $f2 帧后：一级页 SettingsPage = ${_count(find.byType(SettingsPage))}'
          '  二级页 PlaybackSettingsPage = ${_count(find.byType(PlaybackSettingsPage))}'
          '  入口行 = ${_count(find.text('播放与下载'))}');
      expect(_count(find.byType(SettingsPage)), 1,
          reason: '$tag| 返回后一级页必须重新在台上');
      expect(_count(find.byType(PlaybackSettingsPage)), 0,
          reason: '$tag| 返回后二级页必须从树上消失');
      expect(_count(find.text('播放与下载')), 1,
          reason: '$tag| 返回后必须回到一级页（入口行还在）');

      // ★★ ②b 「触摸手势」→ 二级页标题**故意**叫「播放手势」
      final e2 = find.text('触摸手势');
      await _scrollTo(tester, e2);
      await _tapAndSettle(tester, e2, '$tag|nav2');
      final f3 = await _pumpUntilGone(tester, find.byType(SettingsPage));
      log('$tag| nav2 补推 $f3 帧后：一级页 SettingsPage = ${_count(find.byType(SettingsPage))}'
          '  二级页 TouchGesturesSettingsPage = ${_count(find.byType(TouchGesturesSettingsPage))}'
          '  「播放手势」= ${_count(find.text('播放手势'))}'
          '  「触摸手势」= ${_count(find.text('触摸手势'))}'
          '  「仅在触摸端可用」= ${_count(find.text('仅在触摸端可用'))}');
      expect(_count(find.byType(SettingsPage)), 0,
          reason: '$tag| ★ 转场跑完后一级页必须离场（同 nav1）');
      expect(_count(find.byType(TouchGesturesSettingsPage)), 1,
          reason: '$tag| 点入口必须真的推进到 TouchGesturesSettingsPage');
      // ★★★ 这条就是 android-phone 抓到的陷阱：入口名 ≠ 页面标题
      //   ★ 用 >= 1 而不是 == 2：标题 + 区块标题都是「播放手势」，但区块标题
      //     可能在视口外没被建出来（sliver 懒构建）⇒ == 2 会变成**假红**。
      //     真陷阱是下一条「二级页上不该出现入口名」，它保持 == 0 不放松。
      expect(_count(find.text('播放手势')), greaterThanOrEqualTo(1),
          reason: '$tag| ★ 二级页标题是「播放手势」（**故意**与入口名「触摸手势」不同）');
      expect(_count(find.text('触摸手势')), 0,
          reason: '$tag| ★★ 二级页上**不该**出现入口名「触摸手势」'
              '（find.text 是逐字相等，不会命中「都是触摸手势…」那句说明）');
      expect(_count(find.text('返回设置')), 1, reason: '$tag| 二级页返回入口');
      // 三端形态各走各的分支：触摸端有档位，桌面/电视端是「仅在触摸端可用」
      if (kind == DeviceKind.touchOnly) {
        expect(_count(find.text('仅在触摸端可用')), 0,
            reason: '$tag| 触摸端不该出现「仅在触摸端可用」');
        expect(_count(find.text('双击左右侧快进快退')), 1,
            reason: '$tag| 触摸端必须有双击开关');
      } else {
        expect(_count(find.text('仅在触摸端可用')), 1,
            reason: '$tag| 非触摸端必须给出「仅在触摸端可用」的说明'
                '（空白页会让用户以为坏了）');
        expect(_count(find.text('双击左右侧快进快退')), 0,
            reason: '$tag| 非触摸端不该画出触摸档位');
      }

      await _tapAndSettle(tester, find.text('返回设置'), '$tag|back2');
      final f4 = await _pumpUntilGone(tester, find.byType(TouchGesturesSettingsPage));
      log('$tag| back2 补推 $f4 帧后：一级页 SettingsPage = ${_count(find.byType(SettingsPage))}'
          '  二级页 TouchGesturesSettingsPage = ${_count(find.byType(TouchGesturesSettingsPage))}');
      expect(_count(find.byType(SettingsPage)), 1,
          reason: '$tag| 返回后一级页必须重新在台上');
      expect(_count(find.byType(TouchGesturesSettingsPage)), 0,
          reason: '$tag| 返回后二级页必须从树上消失');
      expect(_count(find.text('触摸手势')), 1,
          reason: '$tag| 返回后必须回到一级页');

      await _teardownTree(tester, tag);
    }, timeout: kTimeout);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  B. 二级页「播放与下载」：并发滑杆三要素 + 真的写进偏好（裁决 B ③）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('B. 并发滑杆 min/max/divisions/onChanged + 真手势真落盘', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    UiPrefs.debugResetForTest();

    log('B| 初始 concurrency = ${ClipDownloader.concurrency}'
        '  偏好 = ${UiPrefs.get(ClipDownloader.kConcurrencyKey)}');

    await tester.pumpWidget(_host(const PlaybackSettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    _claim(tester, 'B|pump');
    expect(_count(find.text('播放与下载')), 1, reason: 'B| 二级页标题');
    expect(_count(find.text('返回设置')), 1, reason: 'B| 返回入口');

    /*
     * ★ 2026-10-09 改（Owner 第 20 条）：定位方式与 A 组同一个理由 ——
     *   这一页现在有**两个**滑杆（片段下载并发 / 整片下载并发），
     *   所以按语义锚到「片段下载并发」块里那一个，而不是数全局个数。
     *   本用例要验的是**片段**滑杆的档位与落盘，锚点必须精确到它。
     */
    final sliderF = find.descendant(
      of: find.ancestor(
        of: find.text('片段下载并发'),
        matching: find.byType(SettingsBlock),
      ),
      matching: find.byType(Slider),
    );
    expect(_count(sliderF), 1,
        reason: 'B| ★ 片段下载并发块里必须恰有一个滑杆');
    await _scrollTo(tester, sliderF);

    final sl = tester.widget<Slider>(sliderF);
    log('B| Slider min=${sl.min} max=${sl.max} divisions=${sl.divisions}'
        ' value=${sl.value} onChanged=${sl.onChanged != null}');
    expect(sl.min, 0, reason: 'B| 0 = 不限制');
    expect(sl.max, 8, reason: 'B| 上限 8');
    expect(sl.divisions, 8, reason: 'B| 9 档整数（0..8）');
    expect(sl.value, ClipDownloader.defaultConcurrency.toDouble(),
        reason: 'B| 默认 4');
    expect(sl.onChanged, isNotNull,
        reason: 'B| ★ 不能是「看着能调其实调不动」的假滑杆');

    // ★ 真的驱动一次（走控件**自己的**回调 = 用户拖滑杆时走的那条路）
    sl.onChanged!(0);
    await tester.pump();
    log('B| 调到 0：concurrency=${ClipDownloader.concurrency}'
        '  偏好=${UiPrefs.get(ClipDownloader.kConcurrencyKey)}'
        '  右侧文案=${ClipDownloader.concurrencyLabel(ClipDownloader.concurrency)}');
    expect(ClipDownloader.concurrency, 0, reason: 'B| 滑杆 → 静态字段');
    expect(UiPrefs.get(ClipDownloader.kConcurrencyKey), '0',
        reason: 'B| 滑杆 → 偏好键（这就是「真的生效」，不是只改了个局部变量）');

    tester.widget<Slider>(sliderF).onChanged!(8);
    await tester.pump();
    expect(ClipDownloader.concurrency, 8, reason: 'B| 调到 8');
    expect(UiPrefs.get(ClipDownloader.kConcurrencyKey), '8');

    // ★ 再走一次**真手势**：证明手势层是通的（不是只有回调能调）
    final before = ClipDownloader.concurrency;
    await tester.drag(sliderF, const Offset(-300, 0));
    await tester.pump();
    final after = ClipDownloader.concurrency;
    log('B| 真拖拽 -300px：$before -> $after'
        '（偏好 = ${UiPrefs.get(ClipDownloader.kConcurrencyKey)}）');
    expect(after, lessThan(before),
        reason: 'B| 向左真拖拽必须让并发变小（手势层接上了）');

    // 越界保护：滑杆只给 0..8，静态字段也必须夹住
    ClipDownloader.setConcurrency(99);
    await tester.pump();
    log('B| setConcurrency(99) 后 = ${ClipDownloader.concurrency}');
    expect(ClipDownloader.concurrency, 8, reason: 'B| 静态字段自己夹到 0..8');

    await _teardownTree(tester, 'B');
  }, timeout: kTimeout);

  // ═══════════════════════════════════════════════════════════════════
  //  C. 二级页「播放手势」：标题陷阱 + 档位齐 + 双击步长真的落盘
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('C. 触摸手势页：标题陷阱 + 2.5x 档位 + 双击步长落盘', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Device.overrideKind(DeviceKind.touchOnly);
    addTearDown(() => Device.overrideKind(null));
    UiPrefs.debugResetForTest();

    await tester.pumpWidget(_host(const TouchGesturesSettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    _claim(tester, 'C|pump');
    log('C| 「播放手势」= ${_count(find.text('播放手势'))}'
        '  「触摸手势」= ${_count(find.text('触摸手势'))}'
        '  「返回设置」= ${_count(find.text('返回设置'))}');
    expect(_count(find.text('播放手势')), 2,
        reason: 'C| ★ 标题 + 区块标题，共 2 个（入口名是「触摸手势」）');
    expect(_count(find.text('触摸手势')), 0,
        reason: 'C| ★★ 二级页上不该出现入口名');
    expect(_count(find.text('返回设置')), 1, reason: 'C| 返回入口');

    // ① 双击：四档齐
    for (final s in PlayerGestures.doubleTapOptions) {
      expect(_count(find.text('$s 秒')), greaterThanOrEqualTo(1),
          reason: 'C| 双击步长 $s 秒 这一档必须在');
    }
    // ② 长按：四档齐，且 **2.5x** 是本次按 Owner 需求新增的
    for (final r in PlayerGestures.longPressRateOptions) {
      expect(_count(find.text('${r}x')), greaterThanOrEqualTo(1),
          reason: 'C| 长按倍率 ${r}x 这一档必须在');
    }
    expect(PlayerGestures.longPressRateOptions, contains(2.5),
        reason: 'C| ★ Owner 截图要求 1.5x/2x/**2.5x**/3x 四档');
    expect(_count(find.text('2.5x')), 1,
        reason: 'C| ★ 2.5x 必须画出来（且只画一次）');
    expect(_count(find.text('长按左侧每步（连续快退）')), 1,
        reason: 'C| 连续快退步长档位');

    // ③ 点「30 秒」—— 真的写进偏好键
    final pill = find.text('30 秒');
    await _scrollTo(tester, pill);
    await _tapAndSettle(tester, pill, 'C|tap30');
    log('C| 点「30 秒」后 doubleTapSeconds=${PlayerGestures.doubleTapSeconds}'
        '  偏好=${UiPrefs.get('player.gesture.doubleTap.seconds')}');
    expect(PlayerGestures.doubleTapSeconds, 30,
        reason: 'C| 点档位 → 静态 getter');
    expect(UiPrefs.get('player.gesture.doubleTap.seconds'), '30',
        reason: 'C| 点档位 → 偏好键（player_page 读的就是这个键）');

    // ④ 开关：关掉双击后档位整段收起（真渲染分支，不是文本断言）
    final sw = find.byType(Switch);
    log('C| 开关数量 = ${_count(sw)}');
    expect(_count(sw), greaterThanOrEqualTo(2), reason: 'C| 双击 + 长按两个开关');
    await _tapAndSettle(tester, sw.first, 'C|switch');
    log('C| 关掉双击开关后 doubleTapEnabled=${PlayerGestures.doubleTapEnabled}'
        '  「30 秒」= ${_count(find.text('30 秒'))}'
        '  偏好=${UiPrefs.get('player.gesture.doubleTap.enabled')}');
    expect(PlayerGestures.doubleTapEnabled, isFalse,
        reason: 'C| 点开关 → 静态 getter');
    expect(UiPrefs.get('player.gesture.doubleTap.enabled'), '0',
        reason: 'C| 点开关 → 偏好键');
    expect(_count(find.text('30 秒')), 0,
        reason: 'C| ★ 关掉之后档位整段收起（证明这条 if 分支是真渲染的）');

    await _teardownTree(tester, 'C');
  }, timeout: kTimeout);
}

// ═══════════════════════════════════════════════════════════════════════
//  变异记录（Lead 裁决 B ④：至少一条**能红**的断言）
// ═══════════════════════════════════════════════════════════════════════
//
// # 方法
// ```text
// ① 记下被改文件的 sha256[:16]（= Lead 冻结用的同一口径）
// ② 把**一处**源码字符串改掉（每次只改一处，避免「哪个变异造成的」说不清）
// ③ 跑本文件：& .probe\flutter_test_lock.ps1 -Paths 'test/task18_entry_test.dart'
// ④ **无论结果如何**把文件原字节写回，再核 sha256[:16] 与 ① 相同
// ```
// ★ 第 ④ 步是硬要求：变异后忘了还原 = 交付件被污染，比「测试没红」严重得多。
//
// # 结果（4 个变异全部 exit=1；还原后 sha256[:16] **逐字节相同**）
//
// | # | 变异点 | 冻结 sha16 → 变异 → 还原 | 红在哪行 | Expected/Actual |
// |---|---|---|---|---|
// | M1 | `lib/ui/settings_page.dart` 入口行 `title: '播放与下载'` → `'播放与下载X'` | C5678955C7737199 → 5B0CBEC0A3454979 → C5678955C7737199 ✔ | :284 | 1 / 0 |
// | M2 | `lib/ui/settings/playback_page.dart:287` 二级页 `title:` 加一个 X | 2958DF0E5FFF74A2 → … → 2958DF0E5FFF74A2 ✔ | :312（另 :403 同红） | 1 / 0 |
// | M3 | `lib/ui/settings/touch_gestures_page.dart:95` 触摸分支标题 `'播放手势'` → `'触摸手势'` | C2D5F94C26316C39 → … → C2D5F94C26316C39 ✔ | :355（另 :472 同红） | 0 / 1 |
// | M4 | 同 M1（独立复跑，验可复现） | C5678955C7737199 → … → C5678955C7737199 ✔ | :284 | 1 / 0 |
//
// ★ M3 信息量最大：把二级页标题改成**入口名**之后，`A.touchOnly` 与 `C.` 两个
//   用例**同时**红 —— android-phone 抓到的那个陷阱（入口叫「触摸手势」、页面
//   标题叫「播放手势」）被钉住了 ⇒ 下一个人「顺手把两处改成一致」会立刻被挡。
//
// # 哪些断言**不能**红（诚实标注，免得读者高估覆盖）
// ```text
// · 一级页那两条 `== 1`（:284/:286）只证明「一级页上有且只有一行」；
//   它**不**证明点进去是对的 —— 那由 :310/:347（二级页类型）负责。
// · 三端形态：DeviceKind 只影响一级页的**布局/矩形**（实测入口矩形
//   desktop=(41,279)-(121,295) / touchOnly=(41,0)-(121,16) / tv=(81,259)-(161,275)），
//   不影响两个入口是否存在 ⇒ A 组三条的差异是「三端都能走到」，
//   **不是**三种不同的检查。★ 写在这里，免得读者以为覆盖了三倍。
// · 「播放手势」用 `greaterThanOrEqualTo(1)` 而不是 `== 2`：标题 + 区块标题
//   共 2 个，但区块标题可能在视口外没被建出来（sliver 懒构建）⇒ == 2 会**假红**。
//   真陷阱由下一条「二级页上不该出现入口名」`== 0` 钉住（M3 证明它能红）。
// ```
//
// # 首跑 2 pass / 3 fail 的真实根因（假红，不是 lib 缺陷）
// ```text
// A.desktop / A.touchOnly / A.tv 三条**同一行**红：
//   expect(_count(find.text('播放与下载')), 1)  ⇒ Actual 2
// 根因：**路由转场没跑完**。
//   routes.dart:293-298   只在 AnimationStatus.completed 才把
//                         OverlayEntry.opaque 置真（forward/reverse 置假）
//   overlay.dart:888-917  _OverlayState.build 靠 opaque 决定 skipCount
//   overlay.dart:1061-1062 debugVisitOnstageChildren 只看 onstage
//   ⇒ 旧路由仍在 onstage ⇒ 一级页入口行 + 二级页标题**同时**可见 ⇒ 数成 2。
//     （用户眼里不存在这个问题：用户看到的是 1。）
// 转场时长 = 450ms（page_transitions_theme.dart:470-473
//   `static const int kTransitionMilliseconds = 450;`）> 原来只推的 400ms。
// 修法：`_pumpUntilGone(tester, 旧路由 finder)` 按帧推进到旧路由**真的离场**，
//   并把「离场」本身写成断言（:308 / :345）。实测只需**补推 1 帧**（50ms）——
//   450ms 那两帧已经把动画推完，缺的只是「置真后重建 Overlay」的那一帧。
// ```
//
// # 实测读数（2026-10-04，`flutter test --concurrency=1`，**exit code = 0**）
// ```text
// 00:11 +5: All tests passed!
// [T18E] A.desktop| 加载后：转圈 = 0  ListView = 1  ErrorWidget = 0
// [T18E] A.desktop| nav1 补推 1 帧后：一级页 = 0  二级页 = 1  标题命中 = 1  「返回设置」= 1
// [T18E] A.desktop| nav2 补推 1 帧后：一级页 = 0  「播放手势」= 2  「触摸手势」= 0  「仅在触摸端可用」= 1
// [T18E] A.touchOnly| nav2 补推 1 帧后：「播放手势」= 2  「触摸手势」= 0  「仅在触摸端可用」= 0
// [T18E] A.tv| nav2 补推 1 帧后：「播放手势」= 2  「触摸手势」= 0  「仅在触摸端可用」= 1
// [T18E] B| Slider min=0.0 max=8.0 divisions=8 value=4.0 onChanged=true
// [T18E] B| 调到 0：concurrency=0  偏好=0  右侧文案=不限制
// [T18E] B| 真拖拽 -300px：8 -> 2（偏好 = 2）
// [T18E] C| 点「30 秒」后 doubleTapSeconds=30  偏好=30
// [T18E] C| 关掉双击开关后 doubleTapEnabled=false  「30 秒」= 0  偏好=0
// ```

// ═══════════════════════════════════════════════════════════════════════
//  T10（task-35）两态门禁改造记录 —— 2026-10-10
// ═══════════════════════════════════════════════════════════════════════
//
// # 改了什么（为什么必须改）
// ```text
// CI 的测试步骤跑在**构建之前** ⇒ `sourin_core.dll` 还不存在 ⇒ `_dllReady=false`
// ⇒ 旧版本文件打印 `+0 ~5: All tests skipped.` 且 **exit 0** —— 门禁看着在跑，
//   实际一条断言都没执行（假绿）。
// 现在：`_dllReady` 只当**环境判别器**。两个环境都真渲染、真点击、真断言。
// ```
//
// # 两态原始读数（同一台机器，只切 dll 在不在）
// ```text
// 在位态（dll 在）：      flutter test test/task18_entry_test.dart ⇒ 00:11 +5: All tests passed!  exit=0
// 缺件态（改名 .hold）：  同命令                                ⇒ 00:12 +5: All tests passed!  exit=0
// 缺件态版本行读数：
//   [T18E] A.desktop|  版本行 = 读不到（核心未加载：Invalid argument(s): Failed to load dynamic library 'sourin_core.dll': The specified module could not be found.
//   [T18E] A.touchOnly| 版本行 = （同上）
//   [T18E] A.tv|        版本行 = （同上）
// ```
//
// # 缺件态为什么能读到「版本」行（踩过的坑，别踩第二遍）
// ```text
// `PlaybackSettingsPage._refreshEnv()`（playback_page.dart:466-474）走
// `_envFields()` ⇒ `ClipDownloader.dataDir()`（clip_download.dart:531-554）。
// 在位态它命中 setUpAll 灌进去的 `_dataDirCache`，微任务内就返回；
// 缺件态若**不**灌，它会去走 `Platform.environment['APPDATA']` +
// `Directory.create()` —— 真磁盘 I/O，而 widget 测试跑在 fake async 区里，
// 那个 future 永远不会完成 ⇒ 卡片永远停在「读取中…」⇒ 断言 `Expected: <1> Actual: <0>`
// （实测踩到，且在位态同一条是绿的 ⇒ 两态前置必须对齐）。
// 修法：缺件态也 `ClipDownloader.debugSetDataDir(dataDir.absolute.path)`。
// 另一个坑：这一页高于 900px，「环境信息」卡片在底部 ⇒ 读之前必须先 `_scrollTo`。
// ```
//
// # 阳性对照（改产品代码 ⇒ 必红 ⇒ 逐字节还原）
// ```text
// 口径：把 dll 改名 ⇒ 跑缺件态 ⇒ 改**一处**源码 ⇒ 跑 ⇒ 原字节写回 ⇒ 核 sha256[:16]
// | # | 变异点 | 冻结 sha16 → 还原后 | 红在哪行 | Expected/Actual |
// |---|---|---|---|---|
// | PC1 | `playback_page.dart` 降级文案 `version = '读不到（…'` 前加 `X` | E203F5864E0474AE → 同 ✔ | :470 | a string starting with '读不到（核心未加载：' / 'X读不到（… |
// | PC2 | `settings_page.dart:2657` 空态文案加 `X` | （另一文件，见 t53s 记录） | t53s:734 | 1 / 0 |
// | PC3 | `settings_page.dart:2546` `kCoreVersionFallbackLabel` 加 `X` | （同上） | t53s:540 | '核心未加载 · 架构与设备信息' / '核心未X加载 · …' |
// ⇒ PC1 三个端形态**同时**红（A.desktop / A.touchOnly / A.tv），exit=1。
// ⇒ 还原后 `lib/ui/settings/playback_page.dart` = e203f5864e0474ae（与冻结值逐字节相同）。
// ```
//
// # 本文件仍然**测不到**的（诚实标注，免得读者高估覆盖）
// ```text
// · 缺件态与在位态的差异**只有一处**：核心库加载与否。三端形态（DeviceKind）
//   在缺件态下也只影响布局矩形，不影响入口是否存在（与在位态同一条限制）。
// · 「版本」行只断言**前缀**（缺件态）与「不是降级文案」（在位态），
//   不断言版本号具体值 —— 版本号由 Rust 侧决定，钉死它会变成"改版本就红"。
// · 缺件态下 `SourinApi.start()` 从未被调用 ⇒ 任何依赖已启动核心的契约
//   （provider 列表、插件、直播分组）在本文件里**缺件态一律没测到**。
// · 首屏 `CircularProgressIndicator` 只在**在位态**为 1（缺件态 `loadAll()`
//   很快失败 ⇒ 首帧可能已经是 0）⇒ 该断言未放进两态公共路径。
// ```
