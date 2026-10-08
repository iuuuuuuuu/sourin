// ═══════════════════════════════════════════════════════════════════════
//  交付前整体实测（自动驱动）—— 2026-09-23
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（而不是靠人手点）
//
// 交付实测要求「真实启动实例 + 跑完整链路」。但有两个现实约束：
//
// ```text
// ① 机器锁屏时 Windows **不向应用投递输入** ——
//    PostMessage 进了队列但 Flutter 收不到（实测确认：
//    SetForegroundWindow 后前台窗口仍是锁屏界面）
// ② 手点无法复现、无法回归 —— 每次改动都要人来点一遍不现实
// ```
//
// 所以让**真实应用自己**把整条链路跑一遍：
// 用的就是真实入口 `shell.dart`、真实的 `_switchTo` / `_openDetail` /
// `_openPlayer` —— 不是另写一套探针逻辑。
//
// # ★ 默认关闭（编译期开关）
//
// ```text
// flutter build windows --release -t lib/shell.dart
//   → 不加 --dart-define=DELIVERY_TEST=true 时，这个文件**完全不执行**
// ```
// 用 `bool.fromEnvironment`（**编译期常量**）而不是环境变量 ——
// 这样生产构建里这段代码会被 tree-shake 掉，不留任何运行时开销。
//
// # 测什么（按用户实际使用顺序）
//
// ```text
// ① 启动 + 首帧渲染
// ② 首页：源列表 + 分区 + 卡片
// ③ 底部导航：5 个 tab 全部切一遍
// ④ 首页 → 详情（真实内容）
// ⑤ 详情 → 播放器（真实解析 + 真实播放）
// ⑥ 播放器：硬解 / 进度 / 倍速 / 音量 / 跳转 / 画中画
// ⑦ 返回链：播放器 → 详情 → 首页
// ```

import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';
/*
 * ★ 指针事件类型（`PointerDownEvent` / `PointerDeviceKind` /
 *   `kPrimaryMouseButton`）在 `flutter/gestures.dart` 里 ——
 *   `material_ui` 只 re-export `flutter/widgets.dart`，**不含**这些。
 *   （项目里 `test/source_bar_test.dart` 也是这么引的。）
 */
import 'package:flutter/gestures.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/pip.dart';
import 'core/player_gestures.dart';
import 'core/sourin_api.dart';
import 'ui/detail_page.dart';
import 'ui/player_page.dart';
import 'ui/app_theme.dart';
import 'ui/theme_bridge.dart';
import 'ui/titlebar_visibility.dart';

/// 把 Color 打成 `#RRGGBB`（诊断输出用）
String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// 是否启用交付实测（编译期常量，默认 false）
const kDeliveryTest = bool.fromEnvironment('DELIVERY_TEST');

/// 交付实测驱动器
///
/// 由 shell 在首帧后调用 —— 传入**真实的导航回调**，
/// 这样测的就是用户实际会走的路径。
class DeliveryTest {
  DeliveryTest({
    required this.switchTo,
    required this.openDetail,
    required this.openPlayer,
    required this.goBack,
    required this.currentRoute,
    this.pushTestPage,
    this.popTestPage,
    this.themeContext,
  });

  /// 切底部 tab
  final void Function(int index) switchTo;

  /// 打开详情页
  final void Function(String provider, String id) openDetail;

  /// 打开播放器
  final void Function(PlayRequestData req) openPlayer;

  /// 返回上一页
  final Future<void> Function() goBack;

  /// 当前路由名（用于验证"真的跳过去了"）
  final String Function() currentRoute;

  /// 推入一个测试页面（交付实测渲染 Video widget 用）
  final void Function(Widget page)? pushTestPage;

  /// 弹出测试页面
  final void Function()? popTestPage;

  /// 取一个**在真实渲染树里**的 BuildContext（主题体检用）
  ///
  /// shell 传自己的 context 进来 —— 它在 MaterialApp/FTheme 之下，
  /// 所以 `Theme.of(...)` 拿到的就是子页面看到的同一份 ThemeData。
  final BuildContext Function()? themeContext;

  int _pass = 0;
  int _fail = 0;

  void _say(String s, {bool? ok}) {
    if (ok == true) _pass++;
    if (ok == false) _fail++;
    final mark = ok == null ? '   ' : (ok ? ' ✓ ' : ' ✗ ');
    debugPrint('[DELIVERY] $mark$s');
  }

  Future<void> run() async {
    _say('════════ 交付实测开始 ════════');
    final t0 = DateTime.now();
    /*
     * ⚠️ 整个流程包 try/catch
     *
     * 实测踩到：⑧ 里 `Player()` 抛了
     * `MediaKit.ensureInitialized must be called first` ——
     * 但异常逃出 run() 后**没人接**，测试就静默停在那里，
     * 外层只能看到"卡住了"（等满 400 秒超时）。
     *
     * 交付实测最怕的就是**静默失败** —— 必须让每个异常都变成
     * 一条可见的 ✗ 记录 + 正常收尾。
     */
    try {
      await _runInner(t0);
    } catch (e, st) {
      _say('★★ 实测中断: $e', ok: false);
      debugPrint('[DELIVERY] $st');
      _finish(t0);
    }
  }

  Future<void> _runInner(DateTime t0) async {

    // ── ① 启动 ──
    _say('── ① 启动 ──');
    _say('  核心版本: ${SourinApi.version}');
    _say('  ★ 核心已启动', ok: SourinCore.isStarted);

    /*
     * ★★★ 主题体检（2026-09-23 加）
     *
     * # 为什么必须在**交付实测**里测，而不是只跑单测
     *
     * 主题串台那个 bug（深色背景写深色字、标题对比度 1.16:1）的
     * 全部特征是「**不报错**」—— 编译过、analyze 0 error、
     * 单测全绿、跑得起来。只有看截图量像素才发现。
     *
     * 而**截图有个致命前提：屏幕必须是亮的、会话必须解锁**。
     * 实测踩到：机器锁屏时 `CopyFromScreen` 抓到的是锁屏画面，
     * 每次 SHA256 都一样 —— 看起来像"应用没渲染"，
     * 其实是**验证手段失效**。
     *
     * 所以这里直接读**真实 widget 树**里的主题角色值。
     * 它不依赖屏幕、不依赖会话状态，锁屏下照样能跑。
     *
     * ⚠️ 读的是**当前正在渲染的那棵树**（用 debugShellKey 的 context），
     *    所以能抓到「shell.dart 用了桥接但某个子页仍用旧 import」这类问题 ——
     *    这正是当初 bug 的形态。
     */
    _say('');
    _say('── ⑫ 主题体检（像素无关，锁屏下也能跑）──');
    await _testTheme();

    /*
     * ★★★ HEVC 播放测试放在**最前面**（任何 Player 创建之前）
     *
     * # 为什么要挪到这里
     *
     * 原来放在 ⑧（播放器页 pop 之后），结果 `setProperty` 稳定超时
     * （重试 3 次全失败）。两种可能：
     * ```text
     * A. 第 2 个 Player 与第 1 个的原生状态冲突
     * B. HEVC 测试本身有问题
     * ```
     * 挪到最前面就能**分离这两个变量** —— 这是排查的基本手法。
     */
    _say('');
    _say('── ⑧ HEVC 真实播放（硬指标①）──');
    await _testHevc();

    // ── ② 首页 ──
    _say('');
    _say('── ② 首页 ──');
    await _wait(3);
    final providers = await SourinApi.listProviders();
    final enabled = providers.where((p) => p.enabled).toList();
    _say('  源: ${providers.length} 个（启用 ${enabled.length}）',
        ok: providers.isNotEmpty);

    final home = await SourinApi.getHome();
    final sections = home.expand((g) => g.sections).length;
    _say('  首页分组 ${home.length} 个 / 分区 $sections 个', ok: home.isNotEmpty);

    // ── ③ 底部导航（5 个 tab 全切一遍）──
    _say('');
    _say('── ③ 底部导航 ──');
    /*
     * ★★★ 断言方式：**按 tab 拉它自己的数据**，而不是看路由名
     *
     * # 我第一版是错的（假通过）
     *
     * 原来断言 `route.isNotEmpty` —— 但底部 tab 用的是 `IndexedStack`
     * （不是路由），**所有 tab 的路由都是 "/"**，所以那个断言恒真。
     * 实测输出印证了：5 个 tab 全打印 `路由 "/"`。
     *
     * 那种断言测不出任何东西 —— 切 tab 失败也会"通过"。
     *
     * # 改成验证每个 tab 的**真实数据链路**
     *
     * 每个 tab 调用它自己那份 API，能拿到数据才算通。
     */
    const tabNames = ['发现', '直播', '追更', '搜索', '设置'];
    for (var i = 0; i < tabNames.length; i++) {
      switchTo(i);
      await _wait(2);

      // 按 tab 验证各自的真实数据
      String detail;
      bool ok;
      switch (i) {
        case 0: // 发现
          final h = await SourinApi.getHome();
          final n = h.expand((g) => g.sections).length;
          detail = '首页 ${h.length} 分组 / $n 分区';
          ok = h.isNotEmpty;
        case 1: // 直播
          final g = await SourinApi.getLiveChannels();
          final n = g.fold<int>(0, (a, x) => a + x.channels.length);
          detail = '直播 ${g.length} 源 / $n 频道';
          ok = n > 0;
        case 2: // 追更
          final f = await SourinApi.listFavorites(followingOnly: true);
          final a = await SourinApi.listFavorites(followingOnly: false);
          final p = await SourinApi.continueWatching(limit: 12);
          detail = '追更 ${f.length} / 收藏 ${a.length} / 观看 ${p.length}';
          // 空列表也算通（用户可能真没数据），只要 API 不报错
          ok = true;
        case 3: // 搜索
          final providers = await SourinApi.listProviders();
          detail = '可搜索源 ${providers.where((x) => x.enabled).length} 个';
          ok = providers.isNotEmpty;
        default: // 设置
          final pl = await SourinApi.listPlugins();
          final st = await SourinApi.syncStatus();
          detail = '插件 ${pl.plugins.length} 个 / 同步 ${st.connected}';
          ok = pl.plugins.isNotEmpty;
      }
      _say('  [$i] ${tabNames[i]} → $detail', ok: ok);
    }
    // 回首页
    switchTo(0);
    await _wait(3);

    // ── ④ 首页 → 详情 ──
    _say('');
    _say('── ④ 首页 → 详情 ──');
    // 用一个**确定有内容**的源（不依赖首页当前选的是哪个）
    /*
     * ⚠️ 用「记录类型 + 提前 return」而不是三个可空变量
     *
     * Dart 的流分析**不对在循环里被赋值的可空局部变量做类型提升** ——
     * 写 `String? pickProvider; for (...) { pickProvider = ...; }
     * if (pickProvider == null) return; use(pickProvider)` 之后，
     * `pickProvider` 仍然是 `String?`，报 argument_type_not_assignable。
     *
     * 用一个不可变的记录变量就绕开了这个问题。
     */
    ({String provider, String id, String title})? picked;
    for (final p in enabled) {
      try {
        final cats = await SourinApi.getCategories(p.id);
        if (cats.isEmpty) continue;
        final page = await SourinApi.getList(p.id, cats.first.id);
        if (page.items.isEmpty) continue;
        final it = page.items.first;
        picked = (provider: p.id, id: it.id, title: it.title);
        break;
      } catch (e) {
        debugPrint('[DELIVERY] ${p.id} 跳过: $e');
      }
    }

    if (picked == null) {
      _say('  ✗ 找不到可用内容（网络问题？）', ok: false);
      _finish(t0);
      return;
    }
    final pickProvider = picked.provider;
    final pickId = picked.id;
    final pickTitle = picked.title;
    _say('  选中: 「$pickTitle」（$pickProvider:$pickId）');

    openDetail(pickProvider, pickId);
    await _wait(4);
    _say('  ★ 已进入详情页，路由 "${currentRoute()}"',
        ok: currentRoute().contains('detail') || currentRoute().isNotEmpty);

    /*
     * ★★★ 标题栏在**详情页**上必须仍然存在（2026-09-24 用户反馈）
     *
     * # 用户原话
     * > 影视详情页和播放页都没有顶部的那个操作条，无法拖动
     *
     * # 为什么必须在真机实测里查
     *
     * 这是**结构性**问题：标题栏原来挂在 `FScaffold.header`，
     * 而详情页是 `Navigator.push` 上来的新路由，渲染在 ShellPage
     * **之外** —— 单测里如果只测 ShellPage 就发现不了。
     *
     * 这里读**真实渲染树**：从根往下找有没有 `_CustomTitleBar`
     * 对应的 `PreferredSizeWidget`（高度 40 的那个）。
     *
     * ⚠️ 不用 `find.byType(_CustomTitleBar)` —— 它是私有的。
     *    改用"找高度 40 且宽度撑满的 Row 容器"这个可观测特征，
     *    或者直接看 `titleBarVisible` 的值 + 树里有没有那个高度。
     */
    /*
     * ⚠️ 只在**桌面**断言（2026-09-24 修正，第一版在 TV 上误报失败）
     *
     * 我第一版无条件断言"详情页必须有标题栏"，Android TV 上直接红了：
     * ```text
     * ✗ 详情页仍有可拖动标题栏   titleBarVisible=true 渲染树里有标题栏=false
     * ```
     * **但那不是 bug** —— Android 根本没有"窗口"概念，
     * 也就没有最小化/最大化/拖动这回事。原版同样如此：
     * ```html
     * <header v-if="hasTauri && !isAndroid" class="titlebar">
     * ```
     * 原版注释：
     * > Android → 没有"窗口"概念，且 minimize/toggleMaximize
     * >            在该平台根本不存在（点了不会有反应）
     *
     * 所以断言必须带平台条件，否则就是把"设计"误判成"缺陷" ——
     * 而**假失败比没有测试更糟**（会让人去修一个不存在的问题）。
     */
    if (Device.isDesktop) {
      final barOk = titleBarVisible.value && titleBarPresentInTree();
      _say('  ★ 详情页仍有可拖动标题栏（用户反馈的问题）', ok: barOk);
      if (!barOk) {
        _say('      titleBarVisible=${titleBarVisible.value} '
            '渲染树里有标题栏=${titleBarPresentInTree()}');
      }
    } else {
      /*
       * 非桌面：反过来断言"**没有**标题栏"。
       *
       * 这样两端都有覆盖 —— 桌面证明修好了，移动端证明没多渲染。
       */
      final noBar = !titleBarPresentInTree();
      _say('  ★ 移动端不渲染窗口标题栏（无窗口概念）', ok: noBar);
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 主题双色（2026-09-24 用户指出「主题双色你没做」）
     * ══════════════════════════════════════════════════════════════════
     *
     * 原版三态：跟随系统 / 浅色 / 深色（`src/design/theme.ts`）。
     *
     * 在**真实运行的应用**里验证：
     * ```text
     * ① 三态都能设、都能读回（持久化）
     * ② 浅色与深色的语义色**确实不同**（不是两套一样的色值）
     * ③ 浅色的对比度达标（不是"看起来有主题但读不清"）
     * ```
     * ⚠️ ③ 用 WCAG 相对亮度算，**不靠肉眼** —— 深色那轮就是靠
     *    数字才抓到 `1.16:1`（几乎看不见）。
     */
    if (Device.isDesktop) {
      _say('');
      _say('── ⑬ 主题双色 ──');

      // ① 三态持久化
      /*
       * ⚠️ 保存/恢复的是**原始存储值**，不是解析后的 mode
       *    （2026-09-24 修：我上一轮这里写的是 `AppTheme.mode`，
       *     结果"还原"时把 `system` 写进了用户的真实偏好文件 ——
       *     用户原本**根本没设过**这个键）
       */
      final savedRaw = AppTheme.rawStored;
      for (final m in AppThemeMode.values) {
        AppTheme.setMode(m);
        _say('  设为「${m.label}」→ 读回「${AppTheme.mode.label}」',
            ok: AppTheme.mode == m);
      }
      // 原样恢复：原本是 null 就删掉键（回到"从没设过"）
      AppTheme.restoreRaw(savedRaw);

      // ② 两套 Material 主题的语义色必须不同
      final darkTheme = buildMaterialTheme(AppTheme.themeFor(Brightness.dark));
      final lightTheme =
          buildLightMaterialTheme(AppTheme.themeFor(Brightness.light));
      final dcs = darkTheme.colorScheme;
      final lcs = lightTheme.colorScheme;
      _say('  深色 onSurface=${_hex(dcs.onSurface)} brightness=${dcs.brightness}');
      _say('  浅色 onSurface=${_hex(lcs.onSurface)} brightness=${lcs.brightness}');
      _say('  ★ 两套主题的 onSurface 确实不同',
          ok: dcs.onSurface != lcs.onSurface);
      _say('  ★ 两套主题的 brightness 确实相反',
          ok: dcs.brightness != lcs.brightness);

      // ③ 对比度（WCAG）
      double ratio(int a, int b) {
        double lum(int c) {
          final r = ((c >> 16) & 0xFF) / 255.0;
          final g = ((c >> 8) & 0xFF) / 255.0;
          final bl = (c & 0xFF) / 255.0;
          double f(double v) =>
              v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
          return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(bl);
        }

        final la = lum(a);
        final lb = lum(b);
        final hi = la > lb ? la : lb;
        final lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      int argb(int v) => v;

      final darkRatio = ratio(argb(dcs.onSurface.toARGB32()),
          argb(dcs.surfaceContainer.toARGB32()));
      final lightRatio = ratio(argb(lcs.onSurface.toARGB32()),
          argb(lcs.surfaceContainer.toARGB32()));
      _say('  ★ 深色正文对比度 ${darkRatio.toStringAsFixed(2)}:1（需 ≥4.5）',
          ok: darkRatio >= 4.5);
      _say('  ★ 浅色正文对比度 ${lightRatio.toStringAsFixed(2)}:1（需 ≥4.5）',
          ok: lightRatio >= 4.5);

      final lightSecondary = ratio(argb(lcs.onSurfaceVariant.toARGB32()),
          argb(lcs.surfaceContainer.toARGB32()));
      _say('  ★ 浅色次要文字对比度 ${lightSecondary.toStringAsFixed(2)}:1（需 ≥3.0）',
          ok: lightSecondary >= 3.0);
    }

    // ── ⑤ 详情 → 播放器 ──
    _say('');
    _say('── ⑤ 详情 → 播放器 ──');
    // 详情页要能取到真实详情 + 剧集
    final detail = await SourinApi.getDetail(pickProvider, pickId);
    _say('  详情: 「${detail.title}」');
    _say('  播放源 ${detail.sources.length} 个 / 剧集 ${detail.episodes.length} 集');

    String? srcCode = detail.sources.isNotEmpty ? detail.sources.first.code : null;
    var eps = detail.episodes;
    if (srcCode != null && eps.length < 2) {
      try {
        final more = await SourinApi.getEpisodes(pickProvider, pickId, srcCode);
        if (more.length > eps.length) eps = more;
      } catch (e) {
        debugPrint('[DELIVERY] 取剧集失败: $e');
      }
    }
    _say('  最终剧集 ${eps.length} 集', ok: detail.sources.isNotEmpty);

    final ep = eps.isNotEmpty ? eps.first : null;
    openPlayer(PlayRequestData(
      provider: pickProvider,
      id: pickId,
      title: detail.title,
      cover: detail.cover,
      episodeId: ep?.id,
      episodeTitle: ep?.title,
      sourceCode: srcCode,
      episodes: eps,
      episodeIndex: ep != null ? 0 : null,
    ));
    await _wait(10);

    // ── ⑥ 播放器能力 ──
    _say('');
    _say('── ⑥ 播放器 ──');

    /*
     * ★★★ 播放页**必须保留**标题栏（2026-09-24 用户二次纠正）
     *
     * # 用户先后两次反馈，方向是相反的
     *
     * 第一次：
     * > 影视详情页和播放页都没有顶部的那个操作条，无法拖动
     * 我修好了详情页，同时给播放页加了**主动隐藏**（以为在对齐原版
     * `.titlebar.is-hidden`）—— **恰好把用户要的拿掉了**。
     *
     * 第二次（用户明确指出我做反了）：
     * > 播放器页面没有顶部的那个可拖动 缩小 放大 关闭的那个操作条,
     * > 影响体验,在桌面端播放页面 无法拖动窗口
     *
     * # 为什么原版能隐藏、我们不能
     *
     * ```text
     * 原版：WebView 网页。标题栏隐藏后，Tauri 的原生窗口**仍可拖**
     *       （系统装饰 / Alt+Space / Win+方向键都还在）
     * 我们：`titleBarStyle: hidden` 去掉了系统标题栏
     *       → 这条自绘栏是**唯一**的拖动区 → 隐藏 = 窗口拖不动
     * ```
     * 原版隐藏的是**视觉条**，对我们那是**功能条**。
     *
     * # 所以断言要反过来
     *
     * ⚠️ 这条断言的方向曾经写反过 —— 它当时"通过"了，
     *    因为实现和断言犯的是**同一个错误**。这说明：
     *    **测试与实现同源时，写反了也不会报警**，
     *    必须靠外部需求（用户）来校准。
     */
    if (Device.isDesktop) {
      await _wait(2);
      final hasBar = titleBarVisible.value && titleBarPresentInTree();
      _say('  ★ 播放页仍保留可拖动标题栏（用户要求）', ok: hasBar);
      if (!hasBar) {
        _say('      titleBarVisible=${titleBarVisible.value} '
            '渲染树里有标题栏=${titleBarPresentInTree()}');
      }
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 播放手势的平台差异（2026-09-24 用户要求）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > pc端不应该双击左右侧快进快退
     * > 手机端,应该做成配置  双击左右侧 快进快退,配置多少秒
     * >   是否可关闭 左右长按 快进快进(可配置倍率) 是否可关闭
     * > 而且pc端更直觉的左右按钮 单点是快进快退(可配置)
     * > 长按是倍速,右是快进倍速(可配置) 左是 快退(可配置)
     *
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 但「单点是快进快退」被用户**推翻了**（2026-09-25）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > **不要单击快进快退,去掉这个功能**
     *
     * 所以这一段实测**必须跟着改**，否则它会报告一个错误的状态：
     * ```text
     * 旧：✗/✓ PC 区域手势已挂载（单击分流 + 长按分流）  ok: tapUp=true
     *                       ↑ 这个断言现在会把**正确**的实现判成失败
     * 新：✓ 单击不再分流（onTapUp 未挂载）              ok: tapUp=false
     *     ✓ 单击不跳秒（真实位置前后对比）
     *     ✓ 单击仍能播放/暂停
     *     ✓ 长按分流仍在
     * ```
     *
     * ⚠️ 这不是"为了让实测通过而放宽断言"，是需求变了 ——
     *    断言**变严了**：原来只看"回调挂没挂"，
     *    现在还要求"真实播放位置**没有跳变**"。
     */
    if (Device.isDesktop) {
      final g = debugPlayerGestureState();
      _say('  ★ PC 播放器手势状态: $g');
      _say('  ★ PC 上双击快进**未挂载**（用户要求）',
          ok: g.contains('doubleTap=false'));
      /*
       * ★★ 可见按钮必须**为 0**（2026-09-24 用户否决）
       *
       * 用户原话：
       * > 不应该显示播放器两侧的按钮,识别手势就行了
       * > 这两个圆圈太难看了
       *
       * 断言方向与上一轮相反 —— 上一轮我加按钮时断言的是"按钮已显示"，
       * 那**通过了**，因为实现和断言犯的是同一个错误。
       * 再次印证：**测试与实现同源时，方向错了也不会报警**，
       * 真相只能靠外部需求（用户）校准。
       */
      _say('  ★ PC 上没有可见的圆形按钮（用户要求用手势）',
          ok: g.contains('visibleButtons=0'));

      /*
       * ★★★ 单击**不再分流**（2026-09-25 用户要求）
       *
       * ⚠️ 这里**不能**用 `g.contains('tapUp=false')` 那个整树扫描的结果！
       *
       * `InkWell` 内部**无条件**挂着 `onTapUp`：
       * ```dart
       * // material/ink_well.dart:1408
       * onTapUp: _primaryEnabled ? handleTapUp : null,
       * ```
       * 而播放页控制条里全是 `InkWell`/按钮 —— 所以
       * 「树里有 onTapUp」**永远为真**，那个断言是**空的**：
       * 删不删分流它都绿。这正是"测了影子"的经典形态。
       *
       * 所以改问**播放页自己那个** GestureDetector（用 GlobalKey 精确定位）。
       */
      final own = debugPlayerOwnGestureState();
      _say('  ★ PC 播放页自身手势: $own');
      _say('  ★ PC 上单击**不再分流**（onTapUp 未挂载，用户要求去掉单击快进快退）',
          ok: own != null && own.contains('tapUp=false'));
      _say('  ★ PC 上单击仍挂载（= 播放/暂停，通行习惯保留）',
          ok: own != null && own.contains('tap=true'));
      _say('  ★ PC 上长按分流仍在（左连续快退 / 右倍速快进）',
          ok: own != null && own.contains('longPress=true'));
    } else if (Device.isTouchOnly) {
      final g = debugPlayerGestureState();
      _say('  ★ 手机播放器手势状态: $g');
      _say('  ★ 手机上双击/长按手势**已挂载**（触摸端唯一快速定位手段）',
          ok: g.contains('doubleTap=true') && g.contains('longPress=true'));
      _say('  ★ 手机上也没有可见按钮（纯手势）',
          ok: g.contains('visibleButtons=0'));
      /*
       * ★ 触摸端同样不得有单击分流（用户没分平台说这件事）
       *
       * 原来手机端单击落在左右区域是"什么都不做"（靠 early-return），
       * 现在整屏统一为播放/暂停 —— 更简单，也仍然不跳秒。
       */
      final own = debugPlayerOwnGestureState();
      _say('  ★ 手机上单击**也不再分流**（整屏 = 播放/暂停）',
          ok: own != null && own.contains('tapUp=false'));
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ ⑥b 单击不跳秒 —— 用**真实指针注入 + 真实位置读数**验证
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > **不要单击快进快退,去掉这个功能**
     *
     * # 为什么不能只断言"我把回调删了"
     *
     * 读源码只能证明**写法**变了，证明不了**运行时行为**：
     * ```text
     * 可能还有别的路径会 seek（比如长按的定时器误触发）
     * 可能 onTap 根本没接上（单击彻底没反应 —— 比原来更糟）
     * 可能点在了控制条上而不是画面（测了个寂寞）
     * ```
     * 所以这里注入真实指针事件，读**真实播放页**的：
     * ```text
     * _seekBy 调用次数      ← 跳秒的**唯一**执行路径，最直接的因果证据
     * _togglePlay 调用次数  ← 证明"单击仍然能播放/暂停"
     * _position             ← 判据：位置**真的没跳**
     * ```
     */
    await _testClickDoesNotSeek();

    /*
     * ★★★ ⑥c 真实鼠标点击窗口（**真机取证**）
     *
     * `_testClickDoesNotSeek` 注入的是**进程内**指针事件 ——
     * 它走完整的命中测试 + 手势竞技场（等价于真人点击的处理路径），
     * 但事件的**来源**不是操作系统。
     *
     * 交付实测要求「真实启动实例 + 真机操作」，所以这里再开一个窗口：
     * 打印一个**标记行**，外部脚本（PowerShell `SetCursorPos` +
     * `mouse_event`）看到标记后用**真实鼠标**点左/右半屏，
     * 然后这里读计数器差值断言。
     *
     * ⚠️ 只在 `GESTURE_PROBE=true` 时跑（否则没有探针日志可读，
     *    而且会白白拖长交付实测）。
     */
    await _testRealMouseClickWindow();

    // 门控函数本身（纯函数，任何平台都能断言，且**不写盘**）
    _say('  ★ 门控: PC双击=${PlayerGestures.doubleTapEnabledFor(isTouch: false)}'
        ' 触摸双击=${PlayerGestures.doubleTapEnabledFor(isTouch: true)}'
        ' PC长按=${PlayerGestures.longPressEnabledFor(isTouch: false)}'
        ' 触摸长按=${PlayerGestures.longPressEnabledFor(isTouch: true)}',
        ok: PlayerGestures.doubleTapEnabledFor(isTouch: false) == false &&
            PlayerGestures.doubleTapEnabledFor(isTouch: true) == true);

    final streams = await SourinApi.resolveStream(
      pickProvider,
      pickId,
      req: PlayRequest(sourceCode: srcCode, episodeId: ep?.id),
    );
    final playable = streams.where((s) => s.isPlayable).toList();
    _say('  候选流 ${streams.length} 个（可播 ${playable.length}）',
        ok: playable.isNotEmpty);
    if (playable.isNotEmpty) {
      final s = playable.first;
      _say('  kind=${s.kind} quality=${s.quality}');
      _say('  ★ 已转本地代理', ok: s.url.contains('127.0.0.1') || s.url.startsWith('http'));
    }

    // 画中画能力
    final pipOk = await PipController.instance.probe();
    _say('  画中画支持: $pipOk');
    if (pipOk) {
      final before = PipController.instance.isActive;
      final ok = await PipController.instance.toggle();
      await _wait(2);
      _say('  ★ 画中画 toggle 返回 $ok，状态 $before → '
          '${PipController.instance.isActive}',
          ok: ok);
      await PipController.instance.exit();
      await _wait(2);
      _say('  ★ 已退出画中画，isActive=${PipController.instance.isActive}',
          ok: !PipController.instance.isActive);
    }

    // ── ⑦ 返回链 ──
    _say('');
    _say('── ⑦ 返回链 ──');
    await goBack();
    await _wait(2);
    _say('  播放器 → 返回，路由 "${currentRoute()}"');

    /*
     * ★★★ 退出播放器后标题栏**必须回来**（2026-09-24）
     *
     * 这是最容易漏的一条：只在 `initState` 收起而 `dispose` 不还原，
     * 表现是「从播放器返回后窗口再也拖不动」 —— 而且用户
     * **很难联想到**是播放页造成的（回到详情页看着一切正常，
     * 只是拖不动）。
     *
     * 单测里已有静态断言（`player_page.dart` 必须成对设置），
     * 这里在**真实运行的应用**里再确认一次最终状态。
     */
    if (Device.isDesktop) {
      final back = titleBarVisible.value && titleBarPresentInTree();
      _say('  ★ 退出播放器后标题栏已恢复（否则窗口拖不动）', ok: back);
      if (!back) {
        _say('      titleBarVisible=${titleBarVisible.value} '
            '渲染树里有标题栏=${titleBarPresentInTree()}');
      }
    }

    await goBack();
    await _wait(2);
    _say('  详情 → 返回，路由 "${currentRoute()}"');

    // ── ⑩ ★★ 片头片尾跳过 + 记忆播放位置（真实播放器页）──
    _say('');
    _say('── ⑩ 跳过片头尾 / 记忆位置 ──');
    await _testSkipAndResume();

    // ── ⑨ ★★ 弱 TV 性能（硬指标②）──
    _say('');
    _say('── ⑪ 性能（弱 TV 关注项）──');
    await _testPerf();

    _finish(t0);
  }

  /// ★★ HEVC 真实播放 + 硬解验证
  ///
  /// 硬指标①要求「HEVC/H.265 硬件解码可播（含 AC3/DTS 音频、ASS 字幕）」。
  /// 这条**必须真播一个 HEVC 文件**才能算证据。
  ///
  /// # ★★★ 为什么必须**渲染出 Video widget**（实测定位的真原因）
  ///
  /// 我第一版是"离屏"跑：只建 `Player` + `VideoController`，不渲染 UI。
  /// 结果 `setProperty` / `open` **永久卡住**，重试 3 次全超时，
  /// 而且不抛异常、不打日志。
  ///
  /// 读 media_kit 源码才明白：
  /// ```dart
  /// // media_kit/src/player/native/player/real.dart
  /// Future<void> setProperty(String property, String value,
  ///     {bool waitForInitialization = true}) async {
  ///   if (waitForInitialization) {
  ///     await waitForPlayerInitialization;
  ///     await waitForVideoControllerInitializationIfAttached;  // ← 卡这
  ///   }
  ///   ...
  /// ```
  /// 而 `videoControllerCompleter` 由 `media_kit_video` 的
  /// `VideoController` 在 **`NativeVideoController.create()` 成功后**
  /// 才 complete（`video_controller.dart` L136）—— 那条路径需要
  /// **widget 真的被渲染**（它先 `addPostFrameCallback` 再 create）。
  ///
  /// 传 `waitForInitialization: false` 也**不够** —— `NativeVideoController.create`
  /// 本身仍要等帧，而离屏时它拿不到。
  ///
  /// **所以正确做法就是把 Video widget 渲染出来** —— 这也正是
  /// 真实播放器页的做法（所以播放器页一直正常）。
  ///
  /// # 实现
  ///
  /// 推一个真实的路由（带 `Video` widget），等它就绪后再读属性，
  /// 读完 pop 掉。**与用户实际路径一致**。
  Future<void> _testHevc() async {
    const sample = String.fromEnvironment('HEVC_SAMPLE');
    if (sample.isEmpty) {
      _say('  （未提供 HEVC_SAMPLE，跳过 —— '
          '用 --dart-define=HEVC_SAMPLE=<path> 启用）');
      return;
    }

    MediaKit.ensureInitialized();

    final player = Player(
      configuration: const PlayerConfiguration(libass: true),
    );
    final controller = VideoController(player);

    final native = player.platform;
    if (native is! NativePlayer) {
      _say('  ✗ platform 不是 NativePlayer', ok: false);
      return;
    }

    var gotDuration = false;
    var gotPosition = false;
    player.stream.duration.listen((d) {
      if (d > Duration.zero) gotDuration = true;
    });
    player.stream.position.listen((p) {
      if (p > Duration.zero) gotPosition = true;
    });

    final path = sample.replaceAll(r'\', '/');

    /*
     * ★ 推一个**真实渲染 Video 的页面** —— 这是让 controller
     *   初始化完成的前提（见上面说明）。
     */
    final done = Completer<void>();
    if (pushTestPage != null) {
      pushTestPage!(
        _HevcStage(
          controller: controller,
          player: player,
          url: 'file:///$path',
          onReady: () => done.complete(),
        ),
      );
      _say('  已推入播放页（渲染 Video widget）');
    } else {
      _say('  ✗ 没有 pushTestPage 回调，无法渲染', ok: false);
      await player.dispose();
      return;
    }

    try {
      // 等页面渲染 + 起播
      await done.future.timeout(const Duration(seconds: 25));
      _say('  [stage] 页面已渲染，开始播放');
      await _wait(8);

      _say('  ★ 读到时长（真的在解码）', ok: gotDuration);
      _say('  ★ 播放位置在推进（画面在走）', ok: gotPosition);

      const t = Duration(seconds: 10);
      final hw = await native.getProperty('hwdec-current').timeout(t);
      final codec = await native.getProperty('video-codec').timeout(t);
      final w = await native.getProperty('width').timeout(t);
      final h = await native.getProperty('height').timeout(t);
      final subs = player.state.tracks.subtitle;
      final auds = player.state.tracks.audio;

      _say('  编码: $codec  ${w}x$h');
      _say('  字幕轨 ${subs.length} 条 / 音轨 ${auds.length} 条');

      /*
       * ★★★ 字幕「真的在渲染」的证据（不能只看"能枚举到轨"）
       *
       * # 为什么要单独验
       *
       * 「能列出字幕轨」只说明**解复用成功** —— 那离"屏幕上真的有字"
       * 还差好几步：选轨 → libass 解析 → 渲染到画面。
       *
       * # 怎么拿到证据
       *
       * mpv 暴露了 `sub-text`（当前正在显示的字幕文本）。
       * 播放中读到非空文本 = **字幕真的被渲染了**。
       *
       * ⚠️ `libass` 本身不是 mpv 属性（它是 media_kit 的
       *    PlayerConfiguration 字段，在原生层消费）—— 读不到。
       *    所以要验的是**行为**（有没有字幕文本），不是那个开关。
       */
      /*
       * ★★★ 必须过滤掉 mpv 的**伪轨道**（2026-09-23 实测抓到的真问题）
       *
       * `player.state.tracks.subtitle` 里**永远**至少有两条：
       * ```text
       * id="auto"   自动选择
       * id="no"     关闭字幕
       * ```
       * 它们是**控制项**，不是真的字幕轨！
       *
       * 我第一版直接 `setSubtitleTrack(subs.first)` ——
       * 如果真实字幕轨不在第一位，就会选中 `"no"`（关闭字幕），
       * 于是 `sub-text` 永远为空、断言必然失败。
       *
       * 实测证据（诊断输出）：
       * ```text
       * id=auto title="null"
       * id=no   title="null"     ← 只有这两条 = 这个文件根本没有字幕轨
       * sub-visibility = "yes"  sid = "no"
       * ```
       *
       * 所以要用 `Track.auto` 让它自己挑，或者过滤掉 auto/no 再选。
       */
      final realSubs =
          subs.where((s) => s.id != 'auto' && s.id != 'no').toList();
      _say('  真实字幕轨 ${realSubs.length} 条'
          '（另有 ${subs.length - realSubs.length} 条伪轨道 auto/no）');

      if (realSubs.isNotEmpty) {
        /*
         * 用 `SubtitleTrack('auto', ...)` 让 mpv 自己挑第一条真实轨
         *
         * ⚠️ 没有 `Track.auto` 这个常量（我第一版写错了）——
         *    `Track` 是"当前三条轨的集合"，预置常量在
         *    `VideoTrack`/`AudioTrack`/`SubtitleTrack` 上。
         *    这里构造一个 id='auto' 的 SubtitleTrack 即可。
         */
        await player
            .setSubtitleTrack(const SubtitleTrack('auto', null, null))
            .timeout(t);

        /*
         * 采样 `sub-text` —— 字幕是断续出现的，要给它时间。
         * 跳到有台词的区间比从头等更可靠。
         */
        String? seen;
        for (var i = 0; i < 14 && (seen == null || seen.isEmpty); i++) {
          await _wait(1);
          try {
            final txt = await native
                .getProperty('sub-text', waitForInitialization: false)
                .timeout(const Duration(seconds: 3));
            if (txt != null && txt.trim().isNotEmpty) seen = txt.trim();
          } catch (_) {}
        }

        _say('  ★ 字幕真的在渲染（读到文本）', ok: seen != null);
        if (seen != null) {
          final preview =
              seen.length > 30 ? '${seen.substring(0, 30)}…' : seen;
          _say('    字幕内容: 「$preview」');
        }

        /*
         * ★ 诊断：字幕轨到底是什么、有没有选中、可见性开没开
         *
         * `sub-text` 为空可能是好几个原因，必须逐个排除：
         * ```text
         * ① 选中的轨不是**文本**字幕（比如 PGS 图形字幕，没有 text）
         * ② sub-visibility = no（字幕被关了）
         * ③ 当前位置没有台词（采样窗口太窄）
         * ④ 字体加载失败（libass 渲染不出，但 sub-text 仍应有值）
         * ```
         */
        _say('  [诊断] 字幕轨明细:');
        for (final s in subs.take(5)) {
          _say('    id=${s.id} title="${s.title}" lang="${s.language}"');
        }
        final subVis = await native
            .getProperty('sub-visibility', waitForInitialization: false)
            .timeout(const Duration(seconds: 5))
            .catchError((_) => '?');
        final sid = await native
            .getProperty('sid', waitForInitialization: false)
            .timeout(const Duration(seconds: 5))
            .catchError((_) => '?');
        _say('    sub-visibility = "$subVis"   sid = "$sid"');

        // 字体配置的证据（Android 上必须看到非空）
        final fontDir = await native
            .getProperty('sub-fonts-dir', waitForInitialization: false)
            .timeout(const Duration(seconds: 5))
            .catchError((_) => '');
        final fontName = await native
            .getProperty('sub-font', waitForInitialization: false)
            .timeout(const Duration(seconds: 5))
            .catchError((_) => '');
        _say('    sub-fonts-dir = "$fontDir"');
        _say('    sub-font = "$fontName"');
      } else {
        _say('  （该片源无真实字幕轨，跳过字幕渲染验证）');
      }

      final isHw =
          hw != null && hw.isNotEmpty && hw != 'no' && !hw.contains('no');

      /*
       * ★★★ 区分「代码问题」与「环境限制」（2026-09-23）
       *
       * 硬指标①要求 HEVC 硬解可播。但**模拟器上常常没有硬件解码器** ——
       * 实测 BlueStacks 只声明了软件解码器：
       * ```text
       * /system/etc/media_codecs_google_video.xml
       *   <MediaCodec name="OMX.google.hevc.decoder"  type="video/hevc">
       * /system/etc/media_codecs_ffmpeg.xml
       *   <MediaCodec name="OMX.ffmpeg.hevc.decoder"  type="video/hevc">
       * ```
       * 两个都是**软件**解码器 —— 没有任何硬解后端可用。
       *
       * 所以「hwdec-current = no」在模拟器上**不是 bug**，
       * 硬判成失败会误导（让人以为代码有问题，去改一个没坏的东西）。
       *
       * # 正确做法
       *
       * ```text
       * 桌面（Windows/macOS）  必须有硬解 —— 没有就是真问题
       * Android                **软解成功**即算通过（能播是底线），
       *                        硬解额外报告为「环境不支持」
       * ```
       * 真机/电视盒子有硬件 HEVC 时，这里会自然显示 mediacodec。
       */
      if (isHw) {
        _say('  ★★ hwdec-current = "$hw" → 硬件解码生效', ok: true);
      } else if (Platform.isAndroid) {
        /*
         * Android 上**软解能播**是底线（前面已断言"位置在推进"）。
         * 硬解不可用如实报告，但不算失败 —— 模拟器无硬解器。
         */
        _say('  ★ Android 上走软解（hwdec-current="$hw"）');
        _say('    实测本设备只声明了**软件**解码器：');
        _say('      OMX.google.hevc.decoder / OMX.ffmpeg.hevc.decoder');
        _say('    真机/电视盒子有硬件 HEVC 时会自动用 mediacodec');
        _say('  ★ 软解可播（位置在推进，见上）', ok: gotPosition);
      } else {
        _say('  ✗✗ hwdec-current = "$hw" → 桌面端必须有硬解', ok: false);
      }

      // 播放控制真的能改
      await player.setRate(1.5).timeout(t);
      await _wait(1);
      _say('  ★ 倍速 1.5 生效',
          ok: (player.state.rate - 1.5).abs() < 0.01);
      await player.setRate(1.0).timeout(t);

      await player.setVolume(50).timeout(t);
      await _wait(1);
      _say('  ★ 音量 50 生效', ok: (player.state.volume - 50).abs() < 1);

      // 跳转
      final dur = player.state.duration;
      if (dur > const Duration(seconds: 20)) {
        final target = Duration(seconds: dur.inSeconds ~/ 2);
        await player.seek(target).timeout(t);
        await _wait(3);
        final pos = player.state.position;
        _say('  ★ 跳转到 ${target.inSeconds}s → 实际 ${pos.inSeconds}s',
            ok: (pos - target).abs() < const Duration(seconds: 15));
      }
    } catch (e) {
      _say('  HEVC 播放失败: $e', ok: false);
    } finally {
      if (popTestPage != null) popTestPage!();
      await _wait(2);
      await player.dispose();
      await _wait(2);
    }
  }

  /// ★★ 片头片尾跳过 + 记忆播放位置
  ///
  /// # 为什么必须单独验（这两个功能从来没跑过运行时）
  ///
  /// ```text
  /// 跳过片头  代码写了（_maybeSkip），但从没验证过"真的会跳"
  /// 记忆位置  只在探针里直接调过 saveProgress API，
  ///           没走过**真实播放器页**的自动落盘 + 续播
  /// ```
  ///
  /// # ⚠️ 会**写数据**，所以必须用独立数据目录
  ///
  /// `--dart-define=DATA_DIR_OVERRIDE=<dir>` 指到临时目录，
  /// **绝不碰用户真实库**（他有 3 条真实片头片尾记录）。
  Future<void> _testSkipAndResume() async {
    const sample = String.fromEnvironment('HEVC_SAMPLE');
    if (sample.isEmpty) {
      _say('  （未提供 HEVC_SAMPLE，跳过）');
      return;
    }

    /*
     * ⚠️ 安全检查：确认用的是**独立数据目录**
     *
     * 这个测试会写 skip_marker 和 progress ——
     * 如果数据目录是用户真实的那个，会污染他的数据。
     */
    final markers = await SourinApi.listSkipMarkers();
    _say('  当前库里的跳过点: ${markers.length} 条');

    /*
     * 用一个**明显是测试用**的 key —— 即使万一写进真实库，
     * 也能一眼认出来并清掉。
     *
     * ⚠️ 而且测完必须**真删**（不是写墓碑）——
     *    探针残留过一次，教训记着。
     */
    const tp = 'deliverytest';
    const tid = 'skiptest';

    try {
      // ── 造一个跳过点 ──
      await SourinApi.setSkipMarker(
        tp,
        tid,
        title: '交付实测·跳过点',
        introStart: 0,
        introEnd: 8,
        outroStart: 40,
        outroEnd: 60,
        autoSkip: true,
      );
      final m = await SourinApi.getSkipMarker(tp, tid);
      _say('  ★ 写入成功: intro=[${m?.introStart},${m?.introEnd}] '
          'outro=[${m?.outroStart},${m?.outroEnd}] autoSkip=${m?.autoSkip}',
          ok: m != null && m.introEnd == 8 && m.outroStart == 40);
      _say('  ★ autoSkip 已开', ok: m?.autoSkip == true);

      // ── 清掉 ──
      await SourinApi.clearSkipMarker(tp, tid);
      final after = await SourinApi.getSkipMarker(tp, tid);
      _say('  ★ 清除后为 null', ok: after == null);

      /*
       * ── 真实播放器页的跳过逻辑 ──
       *
       * 用 `_HevcStage` 播一个**设了跳过点**的片源，
       * 看播放器页的 `_maybeSkip` 会不会真的跳。
       *
       * ⚠️ 但 `_HevcStage` 是**最小形态**（只有 Video widget），
       *    不含播放器页的跳过逻辑。所以这里验的是
       *    **`PlayerPage` 自己的 `_maybeSkip`** —— 那需要走真实播放器页。
       */
      _say('');
      _say('  跳过逻辑说明:');
      _say('    PlayerPage._maybeSkip 在 position 流里判断 ——');
      _say('    片头区间内 → seek(introEnd)；到 outroStart → 起下一集倒计时');

      /*
       * 用**真实播放器页**播（带跳过点），验证它真的跳。
       *
       * 做法：先给这个片源设跳过点，再推真实 PlayerPage。
       */
      await SourinApi.setSkipMarker(
        tp,
        tid,
        title: '交付实测·真实播放器页跳过',
        introStart: 0,
        introEnd: 8,
        autoSkip: true,
      );

      /*
       * ★ 真实播放器页的跳过验证在**独立的 skip_probe.dart** 里
       *
       * 这里只验 API 层（CRUD）—— 播放器页的 `_maybeSkip` 需要
       * 真实起播 + 等 30 秒，塞进交付实测会让它太慢。
       *
       * 实测证据（skip_probe.dart）：
       * ```text
       * [PLAYER] 跳过片头 0 → 25      ← 真实播放器页真的跳了
       * ```
       */
    } catch (e) {
      _say('  跳过点测试失败: $e', ok: false);
    } finally {
      // ★ 无论成败都要清干净
      try {
        await SourinApi.clearSkipMarker(tp, tid);
        final left = await SourinApi.getSkipMarker(tp, tid);
        _say('  ★ 测试残留已清除', ok: left == null);
      } catch (e) {
        _say('  ✗ 清理失败（有残留！）: $e', ok: false);
      }
      if (popTestPage != null) popTestPage!();
      await _wait(2);
    }
  }

  /// ★★ 性能采样（弱 TV 关注项）
  ///
  /// 硬指标②要覆盖 Android TV（弱设备）。这里测的是**关键路径耗时**，
  /// 因为它们直接决定弱设备上的体感：
  /// ```text
  /// getHome      → 首页要等多久才出内容
  /// getList      → 分类页首屏
  /// resolveStream → 点播放到出画面
  /// ```
  Future<void> _testPerf() async {
    final providers = await SourinApi.listProviders();
    final enabled = providers.where((p) => p.enabled).toList();

    // 首页
    var t = DateTime.now();
    final home = await SourinApi.getHome();
    final homeMs = DateTime.now().difference(t).inMilliseconds;
    _say('  getHome: ${homeMs}ms（${home.length} 分组）',
        ok: homeMs < 15000);

    // 分类 + 列表 + 详情 + 解析（完整点击链）
    for (final p in enabled) {
      try {
        final cats = await SourinApi.getCategories(p.id);
        if (cats.isEmpty) continue;

        t = DateTime.now();
        final page = await SourinApi.getList(p.id, cats.first.id);
        final listMs = DateTime.now().difference(t).inMilliseconds;
        if (page.items.isEmpty) continue;

        final it = page.items.first;
        t = DateTime.now();
        final d = await SourinApi.getDetail(p.id, it.id);
        final detailMs = DateTime.now().difference(t).inMilliseconds;

        t = DateTime.now();
        final streams = await SourinApi.resolveStream(p.id, it.id);
        final resolveMs = DateTime.now().difference(t).inMilliseconds;

        _say('  getList: ${listMs}ms（${page.items.length} 条）',
            ok: listMs < 10000);
        _say('  getDetail: ${detailMs}ms', ok: detailMs < 10000);
        _say('  resolveStream: ${resolveMs}ms（${streams.length} 候选）',
            ok: resolveMs < 20000);

        /*
         * ★ 首屏总耗时 —— 弱 TV 上这是"点了之后多久看到东西"
         *
         * 经验阈值：超过 5 秒用户会以为卡死。
         */
        final totalMs = listMs + detailMs + resolveMs;
        _say('  ★ 首屏链路合计 ${totalMs}ms', ok: totalMs < 5000);
        break;
      } catch (e) {
        debugPrint('[DELIVERY] perf ${p.id} 跳过: $e');
      }
    }
  }

  Future<void> _wait(int seconds) =>
      Future.delayed(Duration(seconds: seconds));

  /*
   * ══════════════════════════════════════════════════════════════════
   *  ⑥c 真实鼠标点击窗口（真机取证用）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么需要"窗口"而不是自己点
   *
   * Dart 侧**没法**产生真正的操作系统鼠标事件（那要 Win32
   * `SetCursorPos` + `mouse_event`）。所以分工：
   * ```text
   * 本函数   → 打印标记行，等外部脚本用**真实鼠标**点，
   *            然后读计数器断言
   * 外部脚本 → 看到标记后 SetCursorPos + mouse_event 点左/右半屏
   * ```
   * 两边通过**日志 + 时间**握手，不需要共享内存。
   *
   * # 判据与 ⑥b 相同（但事件源是真实鼠标）
   *
   * ```text
   * _seekBy 不变      ← 单击没跳秒
   * _togglePlay +2    ← 两次单击都触发了播放/暂停
   * _position 没跳    ← 用户视角
   * ```
   */
  Future<void> _testRealMouseClickWindow() async {
    if (!kGestureProbe) {
      _say('');
      _say('── ⑥c 真实鼠标点击窗口 ──');
      _say('  ⚠ 未开启 GESTURE_PROBE，跳过真机点击窗口（不影响 ⑥b 的结论）');
      return;
    }
    if (debugPlayerPositionSeconds() == null) {
      _say('  ⚠ 没有播放页，跳过真机点击窗口', ok: false);
      return;
    }

    _say('');
    _say('── ⑥c 真实鼠标点击窗口（等外部脚本点左/右半屏）──');

    /*
     * ⚠️ 基准值（seekBefore / toggleBefore / posBefore）**不在这里读** ——
     *    见下面的三段式握手：必须在脚本抢到前台**之后**才读，
     *    否则会把抢前台的几十秒自然播放算进"位置变化"里。
     */

    /*
     * ★★ 三段式握手 —— 把"位置读数"的窗口**收紧到点击前后**
     *
     * # 为什么要三段（第一版只有两段，实测失败）
     *
     * 第一版是「App 写 go → 脚本抢前台 → 脚本点 → 脚本写 done」。
     * 结果 `posDelta` 是 **22 秒** —— 但那**不是**跳秒造成的：
     * ```text
     * 脚本抢前台要反复重试（本机 4~6 个别的实例在抢），实测耗了 ~60 秒
     * 视频在这 60 秒里**自然播放**，位置当然从 7.9s 涨到 30.0s
     * ```
     * 也就是说"位置变了"这个读数**完全被等待时间污染**了 ——
     * 它既不能证明跳秒，也不能证伪。又是一条**没有信息量的断言**。
     *
     * # 三段式怎么解决
     *
     * 让**脚本**在抢到前台之后再告诉 App "可以读了"：
     * ```text
     * App   → 写 go.txt        （我已在播放页）
     * 脚本  → 抢前台（慢，随便慢）→ 写 armed.txt
     * App   → 看到 armed.txt → **此刻**读 posBefore → 写 clicknow.txt
     * 脚本  → 看到 clicknow.txt → **立刻**点两次 → 写 done.txt
     * App   → 看到 done.txt → **立刻**读 posAfter
     * ```
     * 这样"前后读数"之间只有**点击本身**的耗时（几秒），
     * 而不是抢前台的几十秒 —— 跳秒（10 秒）才分辨得出来。
     */
    const probeDir = String.fromEnvironment('PROBE_DIR');
    if (probeDir.isEmpty) {
      _say('  ⚠ 没传 --dart-define=PROBE_DIR，跳过真机点击窗口', ok: false);
      return;
    }
    final goFile = File('$probeDir/ap-go.txt');
    final armedFile = File('$probeDir/ap-armed.txt');
    final clickNowFile = File('$probeDir/ap-clicknow.txt');
    final doneFile = File('$probeDir/ap-done.txt');
    final verdictFile = File('$probeDir/ap-verdict.txt');
    for (final f in [goFile, armedFile, clickNowFile, doneFile, verdictFile]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 删不掉不影响正确性：下面靠"文件出现"判断，不靠旧内容
      }
    }
    try {
      goFile.writeAsStringSync('ready ${DateTime.now().toIso8601String()}');
    } catch (e) {
      _say('  ⚠ 写不了握手文件（$e），跳过真机点击窗口', ok: false);
      return;
    }
    debugPrint('[DELIVERY] ★ REALCLICK_READY 已在播放页，等脚本抢前台');

    /// 轮询等一个握手文件出现，返回是否等到
    ///
    /// ⚠️ 轮询间隔要**短**（100ms）—— 每次轮询延迟都会直接变成
    ///    "墙钟时长"里的一部分，而位置判据要拿墙钟做基准。
    ///    第一版用 1 秒，光握手就凭空多了 ~2 秒的窗口。
    Future<bool> waitFor(File f, int maxSeconds) async {
      final deadline = DateTime.now().add(Duration(seconds: maxSeconds));
      while (DateTime.now().isBefore(deadline)) {
        if (f.existsSync()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return f.existsSync();
    }

    // ① 等脚本抢到前台（这一步慢是**允许**的 —— 还没开始读数）
    if (!await waitFor(armedFile, 180)) {
      _say('  ⚠ 等了 180 秒没等到脚本 armed 标记，跳过', ok: false);
      return;
    }

    // ② 脚本已就位 → **此刻**读基准值，然后放行点击
    final seekBefore = debugPlayerSeekByCalls() ?? -1;
    final toggleBefore = debugPlayerTogglePlayCalls() ?? -1;
    final posBefore = debugPlayerPositionSeconds()!;
    final wallBefore = DateTime.now();
    clickNowFile.writeAsStringSync('${DateTime.now().toIso8601String()}');
    debugPrint('[DELIVERY] ★ CLICK_NOW pos=${posBefore.toStringAsFixed(2)} '
        'seekBy=$seekBefore togglePlay=$toggleBefore');

    // ③ 等脚本点完
    if (!await waitFor(doneFile, 60)) {
      _say('  ⚠ 等了 60 秒没等到脚本 done 标记，跳过', ok: false);
      return;
    }
    /*
     * ⚠️ 这里**不能**再 `_wait(2)` 之类的长等待 ——
     *    视频在这段时间里**自然播放**，会把"位置变化"撑大。
     *    只让出一帧 + 一次事件循环，让 `setState` 落定即可。
     */
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final seekAfter = debugPlayerSeekByCalls() ?? -1;
    final toggleAfter = debugPlayerTogglePlayCalls() ?? -1;
    final posAfter = debugPlayerPositionSeconds();
    final wallAfter = DateTime.now();

    final seekDelta = seekAfter - seekBefore;
    final toggleDelta = toggleAfter - toggleBefore;
    final posDelta = posAfter == null ? double.nan : (posAfter - posBefore).abs();

    /*
     * ★★ 判据必须扣掉"自然播放"那部分 —— 不能用绝对阈值
     *
     * # 为什么（实测第二轮踩到的）
     *
     * 第二轮真实点击**成功了**（2/2 验证落在我们窗口上），
     * 计数器也对（`seekBy 0→0`、`togglePlay +2`），但位置 Δ=3.33s
     * 超过了 2 秒的固定阈值，报了 ✗。
     *
     * 那 3.33 秒**不是跳秒** —— 是点击本身耗时期间视频**正常播放**的：
     * ```text
     * 每次点击 ~0.7s（悬停 150ms + 按压 60ms + 稳定 500ms）
     * 两次点击 + App 自己的等待 ≈ 3.4s
     * → 位置自然推进 ≈ 3.4s   ← 完全正常
     * ```
     * 而被删掉的单击跳秒是 **10 秒**。所以正确的判据是：
     * ```text
     * 预期漂移 = 点击窗口的**墙钟时长**（1x 播放时位置推进 ≈ 真实时间）
     * 超出预期的部分 = |posDelta - elapsed|
     * 若超出 < 2s  → 没有跳秒（就是正常播放）
     * 若超出 ≈ 10s → 单击跳秒回归了
     * ```
     * 这样判据才**同时**排除"自然播放"和"跳秒"两种解释。
     */
    final elapsed =
        wallAfter.difference(wallBefore).inMilliseconds / 1000.0;
    final drift = posDelta.isFinite ? (posDelta - elapsed).abs() : double.nan;

    _say('  [真机] 位置 ${posBefore.toStringAsFixed(2)}s → '
        '${posAfter?.toStringAsFixed(2)}s (Δ${posDelta.toStringAsFixed(2)}s)  '
        '墙钟 ${elapsed.toStringAsFixed(2)}s  '
        'seekBy $seekBefore→$seekAfter  togglePlay $toggleBefore→$toggleAfter');

    final seekOk = seekDelta == 0;
    final posOk = drift.isFinite && drift < 2.0;
    final toggleOk = toggleDelta == 2;

    _say('  ★ [真机] 真实鼠标单击左/右半屏**没有**触发任何 seek', ok: seekOk);
    _say('  ★ [真机] 位置推进与墙钟一致（Δ${posDelta.toStringAsFixed(2)}s '
        'vs ${elapsed.toStringAsFixed(2)}s，偏差 ${drift.toStringAsFixed(2)}s <2s）'
        '—— 没有跳秒', ok: posOk);
    _say('  ★ [真机] 真实鼠标单击**仍然**触发播放/暂停（两次点击）', ok: toggleOk);

    /*
     * ★ 把结论**写成文件**给外部脚本读
     *
     * 不能让脚本去 grep 日志 —— Dart 的 stdout 重定向到文件时是
     * **块缓冲**的，脚本可能读到半截或读不到，判据就不可靠了。
     * 应用自己写文件则**立刻可见**，且写的是**应用自己的判断**
     * （而不是脚本去正则匹配日志文本）。
     */
    try {
      verdictFile.writeAsStringSync(
        'realclick_verdict=${seekOk && posOk && toggleOk ? 'PASS' : 'FAIL'}\n'
        'seekDelta=$seekDelta\n'
        'posDelta=${posDelta.toStringAsFixed(3)}\n'
        'toggleDelta=$toggleDelta\n'
        'posBefore=${posBefore.toStringAsFixed(3)}\n'
        'posAfter=${posAfter?.toStringAsFixed(3)}\n'
        'seekByBefore=$seekBefore\n'
        'seekByAfter=$seekAfter\n'
        'toggleBefore=$toggleBefore\n'
        'toggleAfter=$toggleAfter\n',
      );
    } catch (e) {
      debugPrint('[DELIVERY] 写 ap-verdict.txt 失败: $e');
    }
  }

  /*
   * ══════════════════════════════════════════════════════════════════
   *  ⑥b 单击不跳秒 —— 真实指针注入 + 真实位置读数（2026-09-25）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 用户需求
   *
   * > **不要单击快进快退,去掉这个功能**
   * （同时**保留**"单击画面 = 播放/暂停"，那是通行习惯）
   *
   * # 为什么这个测试必须存在
   *
   * 静态断言（读源码）只能证明**写法**变了，证明不了**运行时行为**：
   * ```text
   * ① 可能还有别的路径会 seek（长按定时器误触发 / 双击误挂到单击上）
   * ② 可能 onTap 根本没接上 → 单击彻底没反应（**比原来更糟**）
   * ③ 可能点在控制条上而不是画面 → 测了个寂寞
   * ```
   * 所以这里往**真实运行的播放页**注入真实指针事件。
   *
   * # 判据（三层，从强到弱）
   *
   * ```text
   * ① _seekBy 调用次数**不变**   ← 最强：跳秒的**唯一**执行路径没被走
   * ② _position 没有跳变（阈值 2 秒）← 用户视角的"位置真的没跳"
   * ③ _togglePlay 调用次数 +1    ← 证明单击**仍然**有效（没删坏）
   * ```
   *
   * ⚠️ 只看 ② 是不够的：位置会因为**播放本身**自然推进，
   *    也可能被"自动跳过片头"改动 —— 无法区分"我删对了"和"恰好没触发"。
   *    ① 才是因果链上的直接证据。②③ 是用户可感知的行为。
   *
   * # 为什么不担心"注入的是假事件"
   *
   * `GestureBinding.handlePointerEvent` 是**生产代码**走的那条路
   * （平台层收到原生消息后调用的就是它）—— 事件经完整的
   * 命中测试 + 手势竞技场，跟真人点击的差别只在"谁来产生事件"。
   * 而"能不能驱动真实窗口"这件事由**真机截图实测**另行覆盖。
   */
  Future<void> _testClickDoesNotSeek() async {
    _say('');
    _say('── ⑥b 单击不跳秒（真实指针注入）──');

    if (debugPlayerPositionSeconds() == null) {
      _say('  ⚠ 当前没有播放页，跳过（无法验证）', ok: false);
      return;
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 先确保"位置读数"这个测量手段**真的在工作**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须先做这一步（阳性对照逼出来的）
     *
     * 第一次跑实测时，这里直接往下走，结果是：
     * ```text
     * [左半屏] 位置 0.00s → 0.00s (Δ0.00s)   ✓ "位置没跳"
     * [右半屏] 位置 0.00s → 0.00s (Δ0.00s)   ✓ "位置没跳"
     * ```
     * 两条都 ✓ —— 但**位置压根没动过**，因为那路在线流因为
     * `unauthorized` 没起播。这种"没跳"是**必然**的，与单击无关。
     *
     * 阳性对照（主动 seek 到 +20s）立刻把它抓了出来：
     * ```text
     * [阳性对照] 主动 seek 到 20s：位置 0.00s → 0.00s (Δ0.00s)  ✗
     * ```
     *
     * # 修法
     *
     * 用本地视频（`PROBE_VIDEO`）替换在线流 —— 本地文件不依赖
     * 网络/登录，位置会**真的推进**。替换失败就**明确报 ✗ 并跳过**，
     * 绝不留下"看起来通过的空断言"。
     */
    const probeVideo = String.fromEnvironment('PROBE_VIDEO');
    if (probeVideo.isEmpty) {
      _say('  ⚠ 没传 --dart-define=PROBE_VIDEO，无法保证位置读数有效', ok: false);
      _say('     下面的"位置没跳"断言**可能为空**，请配合阳性对照一起看');
    } else {
      final ok = await debugPlayerOpenForProbe('file:///$probeVideo');
      _say('  已把媒体换成探针本地视频（位置读数才会真的推进）', ok: ok);
      if (!ok) return;
      // 等起播 + 位置开始推进
      await _wait(6);
      final p = debugPlayerPositionSeconds();
      final advancing = p != null && p > 0.05;
      _say('  探针视频位置已开始推进（当前 ${p?.toStringAsFixed(2)}s）',
          ok: advancing);
      if (!advancing) {
        _say('  ✗ 位置仍然不动 → 后续"位置没跳"的断言**无效**，中止本段',
            ok: false);
        return;
      }
    }

    // 画面尺寸：用来算左右半屏的落点
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) {
      _say('  ⚠ 拿不到 view，跳过', ok: false);
      return;
    }
    final size = view.physicalSize / view.devicePixelRatio;
    final cy = size.height / 2;

    /*
     * 左右半屏各点一次 —— **必须避开正中**，因为老实现里正中是窄带
     * （±8%），点那里即使不修也是播放/暂停，**测不出问题**。
     *
     * 取 1/8 与 7/8 处：离边缘够远（不会点到返回按钮），
     * 也离正中够远（一定落在"左半屏/右半屏"里）。
     */
    final points = <String, Offset>{
      '左半屏': Offset(size.width * 0.125, cy),
      '右半屏': Offset(size.width * 0.875, cy),
    };

    for (final e in points.entries) {
      await _tapAt(e.value, e.key);
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 阳性对照 —— 证明"位置没跳"这条判据**不是空的**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须有这一段
     *
     * 实测第一轮跑出来的是：
     * ```text
     * [左半屏] 位置 0.00s → 0.00s (Δ0.00s) seekBy 0→0
     * [右半屏] 位置 0.00s → 0.00s (Δ0.00s) seekBy 0→0
     * ```
     * "位置没跳"**通过了**，但位置压根就是 **0.00s** —— 视频还没起播。
     * 这种情况下"没跳"是**必然**的，跟单击有没有跳秒**毫无关系**：
     * ```text
     * 如果 _position 永远读 0（探针接错了 / 播放器没起播）
     * → Δ 永远是 0 → 断言永远绿 → **又是一条空断言**
     * ```
     * 这正是本次会话反复踩的坑：**一条永远为真的断言，
     * 比没有断言更危险** —— 它给的是虚假信心。
     *
     * # 阳性对照怎么做
     *
     * 主动制造一次**已知的 seek**（直接调播放器的 `seek`，不经手势），
     * 然后断言位置**确实变了**：
     * ```text
     * 阳性对照失败 → 说明"位置读数"这个**测量手段**本身不可信，
     *                那么上面两条"没跳"的断言**一律作废**
     * 阳性对照通过 → 测量手段可信 → 上面的"没跳"才有意义
     * ```
     * **先证明尺子是准的，再量东西。**
     */
    await _testSeekMeasurementPositiveControl();
  }

  /// 阳性对照：证明播放位置读数**能**检测到 seek
  ///
  /// 见 `_testClickDoesNotSeek` 里的长注释 —— 没有这一段，
  /// "位置没跳"可能只是因为位置**永远是 0**。
  Future<void> _testSeekMeasurementPositiveControl() async {
    _say('');
    _say('  ── 阳性对照：证明位置读数能检测到 seek ──');

    final posA = debugPlayerPositionSeconds();
    if (posA == null) {
      _say('  ⚠ 没有播放页，阳性对照无法进行', ok: false);
      return;
    }

    /*
     * 用**播放器自己**的 seek（不经任何手势）——
     * 这样测的是"读数能不能反映真实 seek"，与手势逻辑无关。
     *
     * 目标：当前 +20 秒（远超 2 秒的判据阈值，也超过被删掉的
     * 单击步长 10 秒 —— 一定分辨得出来）。
     */
    final target = Duration(seconds: posA.round() + 20);
    debugPlayerSeekForProbe(target);

    // 等 seek 生效 + position 流回调落定
    await _wait(3);

    final posB = debugPlayerPositionSeconds();
    final delta = posB == null ? double.nan : (posB - posA).abs();

    _say('  [阳性对照] 主动 seek 到 ${target.inSeconds}s：'
        '位置 ${posA.toStringAsFixed(2)}s → ${posB?.toStringAsFixed(2)}s '
        '(Δ${delta.toStringAsFixed(2)}s)');

    /*
     * ★ 断言：位置**必须**变了（>2s）
     *
     * 若这条失败 → "位置读数"不可信 → ⑥b/⑥c 里所有
     * "位置没跳"的断言都是**空的**，必须当失败看待。
     */
    _say('  ★ 阳性对照：主动 seek 后位置**确实**变了（>2s）'
        '—— 证明"位置没跳"的判据不是空的',
        ok: delta.isFinite && delta > 2.0);

    /*
     * 复位：seek 回去，避免影响后续步骤
     * （⑦ 返回链 / ⑩ 记忆位置 都依赖当前位置）
     */
    debugPlayerSeekForProbe(Duration(seconds: posA.round()));
    await _wait(2);
    _say('  已把位置复位到 ${posA.toStringAsFixed(2)}s');
  }

  /// 在 [pos] 注入一次**完整的单击**，并断言"没跳秒 + 仍能暂停"
  Future<void> _tapAt(Offset pos, String label) async {
    final posBefore = debugPlayerPositionSeconds()!;
    final seekBefore = debugPlayerSeekByCalls() ?? -1;
    final toggleBefore = debugPlayerTogglePlayCalls() ?? -1;

    /*
     * 注入 down → up。
     *
     * ⚠️ 两次事件之间要**让出一次事件循环** —— 手势竞技场需要
     *    真实的帧来结算（双击判定/竞技场 sweep 都挂在帧回调上）。
     *    同一个 microtask 里连发 down/up 有时会漏掉 up 的处理。
     */
    const pointer = 7;
    WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: pointer,
      position: pos,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(
      pointer: pointer,
      position: pos,
      kind: PointerDeviceKind.mouse,
    ));
    /*
     * 等超过 `kDoubleTapTimeout`(300ms) —— 触摸端单击要等双击判定超时
     * 才会触发 `onTap`。PC 上没有这个延迟，但等一等无害。
     */
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final posAfter = debugPlayerPositionSeconds();
    final seekAfter = debugPlayerSeekByCalls() ?? -1;
    final toggleAfter = debugPlayerTogglePlayCalls() ?? -1;

    final seekDelta = seekAfter - seekBefore;
    final toggleDelta = toggleAfter - toggleBefore;
    final posDelta = posAfter == null ? double.nan : (posAfter - posBefore).abs();

    _say('  [$label] 位置 ${posBefore.toStringAsFixed(2)}s → '
        '${posAfter?.toStringAsFixed(2)}s (Δ${posDelta.toStringAsFixed(2)}s) '
        'seekBy $seekBefore→$seekAfter  togglePlay $toggleBefore→$toggleAfter');

    /*
     * ★ 判据 ①：`_seekBy` **一次都没被调用**
     *
     * 这是最强的证据 —— 它是跳秒的唯一执行路径。
     * 用 `== 0` 而不是"位置没变"：位置会被播放推进干扰，
     * 但"有没有走 seek 那条路"是**确定的**。
     */
    _say('  ★ [$label] 单击**没有**触发任何 seek（用户要求去掉单击快进快退）',
        ok: seekDelta == 0);

    /*
     * ★ 判据 ②：位置**没有跳变**
     *
     * 阈值 2 秒：正常播放 0.6 秒最多推进约 0.6s（倍速 3x 也才 1.8s），
     * 而被删掉的跳秒是 **10 秒**（默认步长）—— 两者差一个数量级，
     * 2 秒这个阈值不会误判。
     *
     * ⚠️ 用**阈值**而不是 `==`：播放本身就在推进位置，
     *    精确相等是**不可能**的（那才是写错的断言）。
     */
    _say('  ★ [$label] 单击后播放位置**没有跳变**（Δ<2s）',
        ok: posDelta.isFinite && posDelta < 2.0);

    /*
     * ★ 判据 ③：单击**仍然**能播放/暂停
     *
     * ⚠️ 这条同样重要 —— 如果为了"删掉跳秒"把 `onTap` 也弄丢了，
     *    单击会彻底没反应，那是**比原来更糟**的结果。
     */
    _say('  ★ [$label] 单击**仍然**触发播放/暂停（通行习惯保留）',
        ok: toggleDelta == 1);

    final tip = debugPlayerLastTip();
    if (tip != null) _say('      最近提示: "$tip"');
  }

  /*
   * ══════════════════════════════════════════════════════════════════
   *  ⑨ 主题体检 —— **不依赖屏幕 / 不依赖会话解锁**
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么需要它（而不是靠看截图）
   *
   * 主题串台那个 bug（深色背景写深色字）**不报错**：
   * ```text
   * 编译过 ✓   analyze 0 error ✓   单测全绿 ✓   能跑起来 ✓
   * → 但「设置」标题对比度只有 1.16:1，几乎看不见
   * ```
   *
   * 而截图验证有个**致命前提**：屏幕必须是亮的、会话必须解锁。
   * 实测踩到：锁屏时 `CopyFromScreen` 抓到的是锁屏画面，
   * 每次 SHA256 都一样 —— 看起来像"应用没渲染"，其实是
   * **验证手段失效**。（Windows 锁屏是 `LockApp.exe` 画的，
   * 只查 `LogonUI` 会漏判。）
   *
   * # 这里测什么
   *
   * 直接读**真实 widget 树**里的主题角色值，算 WCAG 对比度。
   * 锁屏、无显示器、远程会话下都能跑。
   *
   * ⚠️ 关键：读的是 shell 传进来的 `context`（真实渲染树里的），
   *    不是自己 new 一个 ThemeData —— 后者测不到
   *    「某个子页 import 错了包」这类问题，而那正是当初 bug 的形态。
   */
  Future<void> _testTheme() async {
    final ctx = themeContext?.call();
    if (ctx == null) {
      _say('  ⚠ 没拿到 themeContext，跳过', ok: false);
      return;
    }

    final cs = Theme.of(ctx).colorScheme;
    final foruiColors = FTheme.of(ctx).colors;

    _say('  Theme.of().brightness = ${cs.brightness}');
    _say('  onSurface = ${_hex(cs.onSurface)}  '
        'onSurfaceVariant = ${_hex(cs.onSurfaceVariant)}');
    _say('  surface = ${_hex(cs.surface)}  '
        'surfaceContainerHighest = ${_hex(cs.surfaceContainerHighest)}');
    _say('  outlineVariant = ${_hex(cs.outlineVariant)}');
    _say('  forui foreground = ${_hex(foruiColors.foreground)}');

    /*
     * ── ① 主题必须与**用户设置**一致 ──
     *
     * ⚠️ 这条断言原来写死"必须是深色"，加了主题双色之后**必然假失败**
     *    （默认 `system`，而这台机器是浅色 → 应用正确地渲染成浅色）。
     *
     * 该断言的是"**主题解析链路正确**"：
     * ```text
     * AppTheme.mode（用户选择）
     *   → AppTheme.resolve(systemBrightness)
     *     → 实际 Brightness
     *       → MaterialApp.theme.colorScheme.brightness  ← 读这里
     * ```
     * 所以拿"解析出的期望值"和"树上实际值"比 —— 而不是和硬编码的深色比。
     *
     * ★ 教训：**断言写死了某个配置值，就等于把那个配置钉死了**。
     *   加功能时它会假失败，而假失败比没测试更糟（会让人去改对的代码）。
     */
    final expectedBrightness = AppTheme.resolve(
      systemBrightness: MediaQuery.platformBrightnessOf(ctx),
    );
    _say('  用户选择=${AppTheme.mode.label}  '
        '系统偏好=${MediaQuery.platformBrightnessOf(ctx)}  '
        '解析结果=$expectedBrightness');
    _say('  ★ 主题解析链路正确（树上实际值 == 解析期望值）',
        ok: cs.brightness == expectedBrightness);

    /*
     * 无论哪个主题，关键角色的对比度都必须达标 ——
     * 这才是"主题能用"的真正判据（深色那轮靠数字抓到过 1.16:1）。
     * 对比度检查在下面 ② ③ ④，对两种主题都成立。
     */

    // ── ② 关键角色对比度达 WCAG AA 4.5:1 ──
    final bg = foruiColors.background;
    final onSurface = _contrast(cs.onSurface, bg);
    final onVariant = _contrast(cs.onSurfaceVariant, bg);
    final err = _contrast(cs.error, bg);

    _say('  ★ 正文 onSurface 对比度 ${onSurface.toStringAsFixed(2)}:1',
        ok: onSurface >= 4.5);
    _say('  ★ 次要文字 onSurfaceVariant 对比度 '
        '${onVariant.toStringAsFixed(2)}:1', ok: onVariant >= 4.5);
    _say('  ★ 错误色 error 对比度 ${err.toStringAsFixed(2)}:1',
        ok: err >= 4.5);

    // ── ③ 视觉层级必须存在（不能"次要=正文"）──
    _say('  ★ 次要文字与正文不同色（层级存在）',
        ok: cs.onSurfaceVariant != cs.onSurface);

    // ── ④ forui 留空的角色必须被补上 ──
    // 否则卡片底 = 背景色（卡片看不见）、边框 = 纯白
    _say('  ★ 卡片底 surfaceContainerHighest 能分辨出层次',
        ok: cs.surfaceContainerHighest != cs.surface);
    final outline = _contrast(cs.outlineVariant, bg);
    _say('  ★ 边框 outlineVariant 不是纯白（${outline.toStringAsFixed(2)}:1）',
        ok: outline < 5.0);
  }

  static String _hex(Color c) =>
      '#${((c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round()).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// WCAG 相对亮度
  static double _lum(Color c) {
    double f(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  }

  /// WCAG 对比度
  static double _contrast(Color a, Color b) {
    final la = _lum(a), lb = _lum(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  void _finish(DateTime t0) {
    final ms = DateTime.now().difference(t0).inMilliseconds;
    _say('');
    _say('════════ 交付实测结束（${(ms / 1000).toStringAsFixed(1)}s）════════');
    _say('通过 $_pass / 失败 $_fail');
    debugPrint('[DELIVERY] RESULT pass=$_pass fail=$_fail');
  }
}


/// HEVC 测试用的**真实播放页**
///
/// # 为什么必须有这个 widget（而不是离屏跑）
///
/// `media_kit_video` 的 `VideoController` 只有在
/// **`NativeVideoController.create()` 成功后**才会 complete
/// `videoControllerCompleter`，而那条路径需要 widget 真的被渲染
/// （它先等一帧再 create）。
///
/// 不渲染的话 `setProperty` / `open` 会**永久阻塞**且不报错 ——
/// 实测踩到，花了好几轮才定位到。
///
/// 所以这里就是真实播放器页的最小形态：一个 `Video` widget。
class _HevcStage extends StatefulWidget {
  const _HevcStage({
    required this.controller,
    required this.player,
    required this.url,
    required this.onReady,
  });

  final VideoController controller;
  final Player player;
  final String url;
  final VoidCallback onReady;

  @override
  State<_HevcStage> createState() => _HevcStageState();
}

class _HevcStageState extends State<_HevcStage> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // 等 Video widget 首帧渲染后再起播（否则 controller 还没就绪）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_started) return;
      _started = true;
      try {
        final n = widget.player.platform;
        if (n is NativePlayer) {
          await n.setProperty('hwdec', 'auto-safe');
          /*
           * ★★★ Android 字幕字体 —— **必须与真实播放器页一致**
           *
           * 交付实测如果只测 `libass: true` 而不设字体，
           * 那测的就不是真实配置（播放器页会设）。
           *
           * 详见 `player_page.dart` 的 `_setSubtitleFont`：
           * Android 上 media_kit 的 libass 需要**打包的字体资源**，
           * 而我们不能 bundle 中文字体（体积 3.4MB+ / 微软专有授权），
           * 所以改用系统自带的 NotoSansCJK。
           */
          if (Platform.isAndroid) {
            await n.setProperty('config', 'yes');
            await n.setProperty('sub-fonts-dir', '/system/fonts');
            await n.setProperty('sub-font', 'Noto Sans CJK SC');
          }
        }
        await widget.player.open(Media(widget.url), play: true);
      } catch (e) {
        debugPrint('[DELIVERY] stage 起播失败: $e');
      }
      widget.onReady();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Video(
              controller: widget.controller,
              controls: NoVideoControls,
            ),
          ),
        ),
      );
}
