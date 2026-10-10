// ═══════════════════════════════════════════════════════════════════════
//  task-25 —— Owner m01887 第②条「设置没适配安卓端」的 C / D / E 三项
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的三处（真机 1080x2400 @480dpi = 360x800dp，emulator-5554）
//
// ```text
// C  「打开缓存目录」在安卓上是**死代码**
//     点下去只弹「当前平台不支持打开目录」—— 既没打开也没给路径。
// D  设置面板被夹在**视频盒**里（360x202.67dp）
//     标题压在状态栏下、正文只剩几十 dp（`.probe/t24/pan3.txt` / `pan3.png`）。
// E  底栏内容固有宽约 400dp > 手机 360dp
//     齿轮 / 相机被推到最右端，用户要左滑 3 次才摸得到（`.probe/t24/s1.png`）。
// ```
//
// # ⚠️ 为什么**不加** `@Tags(['native-media'])`
//
// 加了它就会被 `dart_test.yaml` 默认 **skip** 掉（默认套件看不到这三项）。
// 而不加它的前提是：**本文件不挂真 `PlayerPage`** ——
// `test/player_episode_nav_boundary_test.dart:120-131` 已记录：挂 `PlayerPage`
// 会真的去加载 libmpv，`flutter_tester` 里偶发 c0000005（exit 79）。
// 所以本文件只用三种**不碰 libmpv** 的手段：
// ```text
// ① 纯函数直测        `clipDirOpenStrategy` 本来就是抽出来给单测的
// ② 源码字面量判据    读 lib/ 下的 .dart 文本（先剥注释，见下）
// ③ 单独挂面板         `PlayerSettingsSheet` 是纯 UI，29 个参数全是回调
// ```
//
// # ⚠️ 断言前必须剥掉注释（本仓铁律，至少踩过 3 次）
//
// 代码里的中文注释会**原样引用**被断言的片段（我这次就在 D 的注释里写了
// `Icons.tune`、`compactRow` 这些词）⇒ 静态断言匹配到注释 ⇒ **假通过**。
// 下面的 [stripComments] 逐字照抄 `player_capability_test.dart:61-110`
// 那个已被反向验证过的实现，不自己另写一个版本。
//
// # ⚠️ 几何判据必须用 `t.view.*`，不能用 `setSurfaceSize`
//
// `setSurfaceSize` 只改**布局约束**，不改 `FlutterView` 的 metrics；
// 安全区内缩来自 `MediaQuery.paddingOf(context)`，只有 `t.view.padding`
// 才喂得到它。顺序照抄 `test/shell_safe_area_test.dart:114-122`。
//
// 跑法：
// ```powershell
// & .probe\flutter_test_lock.ps1 -Paths 'test/t68_android_adapt_test.dart' -Agent player-features
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/player_page.dart' show clipDirOpenStrategy;
import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════
//  注释剥离器（逐字照抄 player_capability_test.dart:61-110）
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释
///
/// ⚠️ 只剥注释、**保留字符串字面量**里的内容 —— 有些断言就是要匹配
///    用户可见的文案（`'更多'` / `'弹幕设置'` / `'已复制路径'`）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 当前是否在字符串里（' 或 "）

  while (i < src.length) {
    final c = src[i];

    // ── 字符串字面量：整段照抄（但要处理转义）──
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }

    // ── 行注释：吃到行尾 ──
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }

    // ── 块注释：吃到 `*/` ──
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
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

const String _pagePath = 'lib/ui/player_page.dart';
const String _sheetPath = 'lib/ui/widgets/player_settings_sheet.dart';
const String _barPath = 'lib/ui/player/player_bottom_bar.dart';

/// 剥注释后的 `player_page.dart`（**只读一次**，多处复用）
final String _page = stripComments(File(_pagePath).readAsStringSync());

/// 剥注释后的 `player_settings_sheet.dart`
final String _sheetSrc = stripComments(File(_sheetPath).readAsStringSync());

/// 断言 `needle` 在 `src` 里**恰好**出现 [want] 次，并返回首次下标
///
/// ⚠️ 不用 `contains` 而用**计数**：`contains` 在「改错了地方」时照样绿
///    （比如把 `Icons.settings` 从 compactRow 挪进菜单，总数仍是 1）。
int indexOfExactly(String src, String needle, {int want = 1, String? why}) {
  final hits = <int>[];
  var from = 0;
  while (true) {
    final i = src.indexOf(needle, from);
    if (i < 0) break;
    hits.add(i);
    from = i + needle.length;
  }
  expect(
    hits.length,
    want,
    reason: why ?? '「$needle」应恰好出现 $want 次，实测 ${hits.length} 次',
  );
  return hits.isEmpty ? -1 : hits.first;
}

/// 取 `start` 之后第一次出现 `open` 到**配平**的 `close` 之间的文本
///
/// 用来把「某个 widget 的整棵子树」切出来 —— 只按固定字数切片会在
/// 以后有人往里面加注释时**静默切错**（本项目踩过）。
String sliceBalanced(String src, int start, String open, String close) {
  final begin = src.indexOf(open, start);
  expect(begin, greaterThanOrEqualTo(0), reason: '找不到「$open」');
  var depth = 0;
  for (var i = begin; i < src.length; i++) {
    if (src.startsWith(open, i)) {
      depth++;
      i += open.length - 1;
      continue;
    }
    if (src.startsWith(close, i)) {
      depth--;
      if (depth == 0) return src.substring(begin, i + close.length);
      i += close.length - 1;
    }
  }
  fail('括号没配平：从 $begin 起');
}

// ═══════════════════════════════════════════════════════════════════════
//  面板夹具（与 t62_player_rate_test.dart:119-220 同构）
// ═══════════════════════════════════════════════════════════════════════

/// 把控件套进真实的壳（forui 主题 + material_ui 的 MaterialApp）
///
/// ⚠️ `Stack` 不能省：面板第一行是 `Positioned.fill`，没有 Stack 会抛。
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Stack(children: [child])),
  );
}

PlayerSettingsSheet makeSheet() {
  return PlayerSettingsSheet(
    isLive: false,
    subtitleTracks: const [
      PlayerTrackOption(id: 'auto', label: '自动'),
      PlayerTrackOption(id: 'no', label: '关闭'),
      PlayerTrackOption(id: '1', label: '简体中文', hint: 'chi'),
    ],
    audioTracks: const [
      PlayerTrackOption(id: 'auto', label: '自动'),
      PlayerTrackOption(id: 'no', label: '关闭'),
      PlayerTrackOption(id: '1', label: '国语', hint: 'aac'),
    ],
    currentSubtitleId: '1',
    currentAudioId: '1',
    externalSubtitleName: null,
    mpvStyle: const {
      'sub-ass-override': 'no',
      'sub-font': 'Microsoft YaHei',
      'sub-font-size': '55',
      'sub-color': '1.00/1.00/1.00',
      'sub-border-color': '0.00/0.00/0.00',
      'sub-border-size': '1.65',
      'sub-margin-y': '0',
    },
    endAction: PlayEndAction.autoNext,
    countdownBeforeNext: true,
    keepSourceOnNext: true,
    autoSkip: true,
    rate: 1.0,
    isPlaying: true,
    clipDownloading: false,
    clipDownloaded: false,
    clipDownloadError: null,
    onSetConcurrency: (_) {},
    onDownloadClip: () {},
    onOpenClipDir: () {},
    onPickSubtitle: (_) {},
    onPickAudio: (_) {},
    onLoadSubtitleFile: (_) {},
    onRemoveExternalSubtitle: () {},
    onSetMpvProperty: (_, __) {},
    onSetEndAction: (_) {},
    onSetCountdown: (_) {},
    onSetKeepSource: (_) {},
    onSetAutoSkip: (_) {},
    onSetRate: (_) {},
    onClose: () {},
  );
}

/// 面板卡片：`player_settings_sheet.dart` 里**唯一**那个 `maxHeight: 620`
/// 的 `Container`。
///
/// ★ 用「约束」而不是「宽 560」来找它：360dp 的窗口会把 560 夹成 360，
///   那时按宽度找会找不到（然后几何断言全变成恒真的假绿）。
final Finder _card = find.byWidgetPredicate(
  (w) => w is Container && w.constraints?.maxHeight == 620,
  description: '设置面板卡片（constraints.maxHeight == 620）',
);

// ═══════════════════════════════════════════════════════════════════════
//  手机实测常量（全部来自真机 `dumpsys window displays`，不是估的）
// ═══════════════════════════════════════════════════════════════════════

const double _phoneDpr = 3.0; // 1080 / 360
const double _phoneW = 1080.0;
const double _phoneH = 2400.0;

/// 状态栏 `InsetsSource type=statusBars frame=[0,0][1080,144]`
const double _statusBarPhysical = 144.0;

/// 手势条 `InsetsSource type=navigationBars frame=[0,2280][1080,2400]`
const double _gestureBarPhysical = 120.0;
const double _statusBarLogical = _statusBarPhysical / _phoneDpr; // 48.0
const double _gestureBarLogical = _gestureBarPhysical / _phoneDpr; // 40.0
const double _phoneLogicalW = _phoneW / _phoneDpr; // 360.0
const double _phoneLogicalH = _phoneH / _phoneDpr; // 800.0

/// 把视口设成真机尺寸 + 真机内缩（顺序照抄 shell_safe_area_test.dart:114-122）
void _setPhoneView(
  WidgetTester t, {
  double heightPhysical = _phoneH,
  double topPhysical = _statusBarPhysical,
  double bottomPhysical = _gestureBarPhysical,
}) {
  t.view.devicePixelRatio = _phoneDpr;
  t.view.physicalSize = Size(_phoneW, heightPhysical);
  t.view.padding = FakeViewPadding(
    top: topPhysical,
    bottom: bottomPhysical,
    left: 0,
    right: 0,
  );
  addTearDown(t.view.reset);
}

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  C：「打开缓存目录」在安卓上不再是一句「不支持」
  // ═════════════════════════════════════════════════════════════════════
  group('★ C 打开缓存目录：四平台策略', () {
    test('C① clipDirOpenStrategy 四分支返回值', () {
      /*
       * ★ 红度证明：把 `clipDirOpenStrategy` 里的 else 改回
       *   `return 'unsupported';`（旧行为）⇒ 第 4 条立刻红。
       */
      expect(
        clipDirOpenStrategy(isWindows: true, isMacOS: false, isLinux: false),
        'explorer',
      );
      expect(
        clipDirOpenStrategy(isWindows: false, isMacOS: true, isLinux: false),
        'open',
      );
      expect(
        clipDirOpenStrategy(isWindows: false, isMacOS: false, isLinux: true),
        'xdg-open',
      );
      expect(
        clipDirOpenStrategy(isWindows: false, isMacOS: false, isLinux: false),
        'copy-path',
        reason:
            '★ 安卓 / iOS 没有文件管理器入口 ⇒ 必须落到「复制路径」，'
            '而不是旧行为「什么都不做」。',
      );
    });

    test('C①b 优先级：Windows 先于 macOS / Linux（三分支互不吞）', () {
      expect(
        clipDirOpenStrategy(isWindows: true, isMacOS: true, isLinux: true),
        'explorer',
      );
      expect(
        clipDirOpenStrategy(isWindows: false, isMacOS: true, isLinux: true),
        'open',
      );
    });

    test('C② _openClipDir 真的按策略分派，且 else 分支会复制路径', () {
      /*
       * ★ 为什么能在这里断言源码：`Platform.isAndroid` 在 flutter_tester 里
       *   恒为 false（宿主是 Windows）⇒ 安卓那一支**跑不到**，只能钉住它的形状。
       * ★ 红度证明：把 `else` 分支的 `Clipboard.setData(...)` 删掉 ⇒ 第 3 条红。
       */
      final i = indexOfExactly(
        _page,
        'Future<void> _openClipDir() async {',
        why: '_openClipDir 的签名变了',
      );
      final body = sliceBalanced(_page, i, '{', '}');
      indexOfExactly(body, 'final strategy = clipDirOpenStrategy(');
      indexOfExactly(body, "if (strategy == 'explorer')");
      indexOfExactly(body, "else if (strategy == 'open')");
      indexOfExactly(body, "else if (strategy == 'xdg-open')");
      indexOfExactly(body, "Process.run('explorer', [d.path])");
      indexOfExactly(body, "Process.run('open', [d.path])");
      indexOfExactly(body, "Process.run('xdg-open', [d.path])");
      indexOfExactly(
        body,
        'await Clipboard.setData(ClipboardData(text: d.path));',
        why: '★ else 分支必须把路径塞进剪贴板 —— 这是「可用行为」的全部内容',
      );
      expect(
        body.contains("已复制路径"),
        isTrue,
        reason: '★ 复制之后要告诉用户「复制了什么」（_flash 文案）',
      );
    });

    test('C③ 旧文案「当前平台不支持打开目录」已彻底消失', () {
      /*
       * ★ 判据对象是**剥注释后**的全文 —— 改动的注释里仍然会引用这句
       *   旧文案（说明「改前是这么写的」），用原文断言会**假红**。
       * ★ 红度证明：把 else 分支换回 `_flash('当前平台不支持打开目录：$dir')` ⇒ 红。
       */
      final raw = File(_pagePath).readAsStringSync();
      expect(
        _page.contains('当前平台不支持打开目录'),
        isFalse,
        reason: '★ 代码里不许再有这句 —— 用户点了按钮只看到「不支持」就是这次的 bug',
      );
      expect(
        raw.contains('当前平台不支持打开目录'),
        isTrue,
        reason:
            '★ 反向对照：注释里**应当**留着旧文案（解释改前是什么样）。'
            '它不见了说明剥注释器没生效，或注释被误删。',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  D：设置面板不再被夹在视频盒里
  // ═════════════════════════════════════════════════════════════════════
  group('★ D 设置面板：挂到 rootOverlay + 自带安全区', () {
    test('D① 挂载点是 OverlayPortal(rootOverlay)，_settingsOpen 仍是唯一开关', () {
      /*
       * ★ 症状：面板原来是 `if (_settingsOpen) PlayerSettingsSheet(...)`
       *   直接挂在**视频盒**那个 Stack 里 ⇒ `Positioned.fill` 拿到的约束是
       *   360x202.67dp ⇒ 卡片被夹成 202.67 高。
       * ★ 红度证明：把 `overlayLocation: OverlayChildLocation.rootOverlay,`
       *   那一行删掉 ⇒ 第 2 条红（默认是 `OverlayChildLocation.nearestOverlay`，
       *   仍会被夹）。
       */
      indexOfExactly(
        _page,
        'OverlayPortal(',
        want: 1,
        why: '★ 只该有**一处** OverlayPortal —— 多一处说明面板被挂了两次',
      );
      indexOfExactly(
        _page,
        'overlayLocation: OverlayChildLocation.rootOverlay,',
      );
      indexOfExactly(_page, 'controller: _settingsPortal,');
      indexOfExactly(
        _page,
        'overlayChildBuilder: (ctx) => _buildSettingsPortalChild(ctx),',
      );
      // 门控：`_settingsOpen == false` 时 portal child 不渲染
      indexOfExactly(
        _page,
        'if (!_settingsOpen) return const SizedBox.shrink();',
      );
      // 面板只被构造一次（在 `_buildSettingsPortalChild` 里）
      indexOfExactly(_page, 'PlayerSettingsSheet(', want: 1);
      // `onClose` 仍写回 `_settingsOpen`（唯一真值源，不是 portal 的可见性）
      //
      // ★ 2026-10-08（Owner 第 3 条收尾）：它从**一行 lambda** 改成了**块** ——
      //   关面板现在要做三件事：真源 + `_hideSettingsPortal()` + 底栏自愈。
      //   ⚠️ 所以不能再钉整行字面量（那等于钉住"不许自愈"）；改钉
      //   「块头 + 块内第一句」，语义（onClose 写回唯一真值源）不变。
      final closeAt = indexOfExactly(_page, 'onClose: () {');
      expect(
        _page
            .substring(closeAt, closeAt + 200)
            .contains('setState(() => _settingsOpen = false);'),
        isTrue,
        reason: '★ 面板的 onClose 必须写回唯一真值源 _settingsOpen',
      );
      // 关面板要顺手把 portal 收起来（否则可见性镜像与真值源不同步）
      // ★ 恰好 **2** 处**调用**：`_closeSettingsFromEsc()` 助手 + 面板 X 的 onClose
      //   （`void _hideSettingsPortal() {` 那行是**定义**，不含 `;`，不计入）
      indexOfExactly(
        _page,
        '_hideSettingsPortal();',
        want: 2,
        why:
            '★ 关面板的两条路（Esc / 面板 X）都必须把 portal 收起来，'
            '否则可见性镜像与真值源不同步',
      );
    });

    test('D② 面板外壳自带安全区 Padding（top + bottom），且尺寸两行未动', () {
      /*
       * ★ 为什么安全区加在**面板内部**：面板第一行是 `Positioned.fill`，
       *   它只被**最近的 Stack** 认；在它外面再套 `Positioned`/`Padding`，
       *   两个 ParentDataWidget 会争同一个 `StackParentData`，内层后应用 ⇒
       *   外层设的 top/bottom 被覆盖成 0（`t57_sheet_scrim_geometry_test.dart:63`）。
       * ★ 红度证明：把 `top: MediaQuery.paddingOf(context).top,` 删掉 ⇒ 第 1 条红。
       */
      indexOfExactly(_sheetSrc, 'top: MediaQuery.paddingOf(context).top,');
      indexOfExactly(
        _sheetSrc,
        'bottom: MediaQuery.paddingOf(context).bottom,',
      );
      // 尺寸两行**刻意未动**（Lead 裁决：rootOverlay 之后 560 会被 360 自然夹住）
      indexOfExactly(_sheetSrc, 'width: 560,');
      indexOfExactly(
        _sheetSrc,
        'constraints: const BoxConstraints(maxHeight: 620),',
      );
    });

    testWidgets('D③ 真渲染：手机视口下卡片高 620（不再被视频盒夹成 202.67）', (t) async {
      /*
       * ★ 这条是 D 的**核心读数**。
       *   改前面板的父盒是视频盒（360x202.67dp）⇒ 卡片高 202.67；
       *   现在挂 rootOverlay ⇒ 卡片拿到整窗，`maxHeight: 620` 才真的生效。
       * ★ 红度证明：把 `overlayLocation` 那行删掉、并把面板挂回视频盒 ⇒ 红。
       */
      _setPhoneView(t);
      await t.pumpWidget(_host(makeSheet()));
      await t.pump();

      expect(_card, findsOneWidget, reason: '★ 找不到卡片 ⇒ 下面全是恒真的假绿（先修夹具）');
      final card = t.getRect(_card);
      expect(
        card.height,
        closeTo(620, 0.01),
        reason:
            '★ 卡片高必须 == maxHeight(620)。202.67 就是**改前**那个症状'
            '（父盒是视频盒）；被夹成别的数说明面板又被塞回小盒子里了。',
      );
      expect(
        card.width,
        closeTo(_phoneLogicalW, 0.01),
        reason: '★ 360dp 的窗口要把 560 夹到 360（Lead 裁决：这两行尺寸不许改）',
      );
      // 整块卡片必须落在窗口内（不许有半截在屏幕外）
      expect(card.left, greaterThanOrEqualTo(-0.01));
      expect(card.right, lessThanOrEqualTo(_phoneLogicalW + 0.01));
      expect(card.top, greaterThanOrEqualTo(-0.01));
      expect(card.bottom, lessThanOrEqualTo(_phoneLogicalH + 0.01));
      expect(t.takeException(), isNull, reason: '手机视口下不该有任何 overflow');
    });

    testWidgets('D④ 矮窗口下卡片正好缩进安全区（红度证明：不加 Padding 会顶到 0）', (t) async {
      /*
       * ★ 为什么要换个**矮窗口**：800dp 高的手机上 `maxHeight: 620` 本来就
       *   撑不到状态栏 ⇒ 内缩在数值上「看不出来」。换成 420dp 高的窗口，
       *   可用高 = 420 - 48 - 40 = 332 < 620 ⇒ 卡片被压到 332，
       *   此时 `top` **恰好等于**状态栏高度 —— 这条等式就是内缩生效的证明。
       * ★ 红度证明：把面板里那个 `Padding` 删掉 ⇒ `top` 变 0、高变 420 ⇒ 两条都红。
       */
      const double hPhysical = 420 * _phoneDpr; // 1260
      _setPhoneView(t, heightPhysical: hPhysical);
      await t.pumpWidget(_host(makeSheet()));
      await t.pump();

      expect(_card, findsOneWidget);
      final card = t.getRect(_card);
      const double available =
          420 - _statusBarLogical - _gestureBarLogical; // 332
      expect(
        card.height,
        closeTo(available, 0.01),
        reason: '★ 卡片应被压到「窗口高 - 状态栏 - 手势条」= $available dp',
      );
      expect(
        card.top,
        closeTo(_statusBarLogical, 0.01),
        reason:
            '★ 卡片顶边必须**恰好**让开状态栏（$_statusBarLogical dp）；'
            '顶到 0 就是没让，改前就是这样。',
      );
      expect(
        card.bottom,
        closeTo(420 - _gestureBarLogical, 0.01),
        reason: '★ 底边同理要让开手势条（$_gestureBarLogical dp）',
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('D⑤ 面板可滚动区里真的能摸到「打开缓存目录」', (t) async {
      /*
       * ★ 这是用户实际要点的那个按钮（C 的入口）。
       *   `hitTestable()` 是关键 —— `findsOneWidget` 对「存在但在视口外」
       *   照样绿，而用户点不到（本项目已踩过：t62 的 chip 就栽在这）。
       * ★ 红度证明：把卡片高度改回 202.67（挂回视频盒）⇒ 滚到底也够不到。
       */
      _setPhoneView(t);
      await t.pumpWidget(_host(makeSheet()));
      await t.pump();

      final open = find.text('打开缓存目录');
      expect(open, findsOneWidget, reason: '★ 按钮本身必须在');

      // 面板内部唯一那根滚动条（`_clipSection` 里没有滚动，见 D 组源码判据）
      final scroller = find.byType(SingleChildScrollView).first;
      for (
        var i = 0;
        i < 12 && !open.hitTestable().evaluate().isNotEmpty;
        i++
      ) {
        await t.drag(scroller, const Offset(0, -120));
        await t.pump();
      }
      expect(
        open.hitTestable(),
        findsOneWidget,
        reason: '★ 滚到底都点不到「打开缓存目录」⇒ 面板可用高度不够（D 的症状）',
      );
      // 字面量随 Owner 第 5 条文案同步：'下载到缓存' → '下载本集到缓存'
      // （旧文案让用户以为下的是片段，实际是整集）
      expect(
        find.text('下载本集到缓存').hitTestable(),
        findsOneWidget,
        reason: '★ 同一行的另一半（下载）也要能点',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  E：底栏在手机上换形（不再靠横滑找齿轮）
  // ═════════════════════════════════════════════════════════════════════
  group('★ E 底栏重做（Owner 2026-10-09 第 12 条）：新结构', () {
    const barPath = 'lib/ui/player/player_bottom_bar.dart';
    final String bar = stripComments(File(barPath).readAsStringSync());

    test('E① 底栏本体已搬进 ui/player/player_bottom_bar.dart（旧大文件里不再有它）', () {
      /*
       * ★ 红度证明：把 `PlayerBottomBar` 的 build 再塞回 `_BottomBar` 里
       *   （即恢复"底栏本体在 player_page.dart"）⇒ 本条红。
       */
      expect(
        File(_barPath).readAsStringSync().contains('class PlayerBottomBar'),
        isTrue,
        reason:
            '★★ 新底栏必须在 ui/player/player_bottom_bar.dart —— '
            '本轮把 1300 多行底栏实现从 player_page.dart 搬出来了。',
      );
      // 旧的三档结构（compactRow / miniBar / row）**不该**再出现
      indexOfExactly(
        _page,
        'final compactRow = Column(',
        want: 0,
        why: '★ 旧的三档宽度结构已整体替换 —— 判据挪到了新文件上',
      );
      indexOfExactly(
        _page,
        'final miniBar = Column(',
        want: 0,
        why: '★ 同上（中档）',
      );
    });

    test('E② 新底栏：常驻高频项在任何宽度都在第一行', () {
      /*
       * ★ Owner 的原话是「底部的按钮超级多」—— 本条钉的是**收敛**：
       *   常驻的只有 播放/音量/倍速，其余（选集/清晰度/字幕/弹幕/更多/下一集）
       *   是条件项，低频项（截图/设置/投屏/缩放/片头片尾）进了「更多」浮层。
       * ★ 红度证明：把 `_moreMenuGroups` 里的项删光 ⇒ E③ 红。
       */
      indexOfExactly(bar, 'class PlayerBottomBar');
      expect(
        bar.contains('PlayerPopoverIds.more'),
        isTrue,
        reason: '★「更多」入口必须还在底栏上（它是低频项的唯一出口）',
      );
      expect(
        bar.contains('PlayerPopoverIds.rate'),
        isTrue,
        reason: '★ 倍速必须是 popover 入口（B 站那一档），不是弹窗',
      );
      expect(
        bar.contains('PlayerPopoverIds.quality'),
        isTrue,
        reason: '★ 清晰度/线路必须是 popover 入口 —— Owner 点名要的那个',
      );
      expect(
        bar.contains('PlayerPopoverIds.tracks'),
        isTrue,
        reason: '★ 字幕/音轨也走 popover',
      );
    });

    test('E③ 低频功能一个没删：全部进了「更多」分组浮层', () {
      /*
       * ★ 这一条是 Owner 要求的**底线**：「只重组入口，不删功能」。
       *   下面每一项在改前都是底栏上的一枚可见入口。
       * ★ 红度证明：从 `_moreMenuGroups` 里删掉任意一个 label ⇒ 本条红。
       */
      final i = _page.indexOf('List<MoreMenuGroup> _moreMenuGroups(');
      expect(i, greaterThan(0), reason: '★「更多」浮层的分组清单不见了');
      final body = sliceBalanced(_page, i, '{', '}');
      for (final label in [
        '截图', // 改前：底栏相机按钮
        '播放设置', // 改前：底栏齿轮
        '换源', // 改前：底栏「换源」文字按钮
        '片头片尾', // 改前：底栏文字按钮（直播时不显示）
        '弹幕设置', // 改前：底栏 tune 图标
        '画中画', // 改前：底栏图标
        '画面缩放', // 改前：底栏缩放按钮 / 紧凑档「更多」菜单项
        '字幕搜索', // 改前：设置面板里的入口，仍然可达
        '上一集', // 改前：底栏上一集按钮
        // ★ 2026-10-10（Owner 第 6 条）「下一集」从这份清单里移除：
        //   底栏 ⎓ 常驻就是它的全部入口，「更多」里再放一个就是重复。
        //   能力没删（底栏仍可点、仍接 _gotoNextEpisode），删的是重复项。
      ]) {
        expect(
          body.contains("'$label'"),
          isTrue,
          reason:
              '★★「$label」在改前是底栏上的可见入口，'
              '本轮**只允许换入口、不许删功能**',
        );
      }
      // ★ 对应 Owner 第 6 条的反向门禁：下一集的入口必须唯一。
      expect(
        body.contains("label: '下一集'"),
        isFalse,
        reason: '★★「更多」里不得再有「下一集」——它与底栏 ⎓ 重复'
            '（两处都调 _gotoNextEpisode）',
      );
      // ★ 底栏那一枚在 `lib/ui/player/player_bottom_bar.dart`里（本测试不引用它，直接读文件）。
      expect(
        stripComments(File(_barPath).readAsStringSync()).contains('Icons.skip_next'),
        isTrue,
        reason: '★★ 底栏 ⎓ 仍须在（入口唯一 ≠ 功能没了）',
      );
      // ★ 投屏那一项由 `castEntry` 这个 getter 提供（它要放**真的 CastButton**，
      //   那个控件自己管代理与电视扫描，见 cast_button.dart 的类文档），
      //   所以它在 `_moreMenuGroups` 外面 —— 判据也跟着分开写。
      expect(
        _page.contains("label: '投屏'"),
        isTrue,
        reason: '★★「投屏」在改前是底栏上的可见入口，不许删',
      );
      expect(
        _page.contains('CastButton('),
        isTrue,
        reason: '★ 投屏要用**真的 CastButton**，不是一枚自己画的图标',
      );
    });

    test('E④ 音量滑杆仍然恰好一根，且是 0..100', () {
      /*
       * ★ 这是硬约束（`player_capability_test` 用 `find.byType(Slider).first`
       *   钉「全页恰好一根 0..8/8 滑杆」）。
       * ★ 红度证明：在底栏里再加一根 Slider ⇒ 本条红。
       */
      // ★ 只数 `_VolumeControl` 那一段：缩放滑条（PlayerZoomSliderCard）
      //   与进度拖条（PlayerProgressSlider 是自定义手势，不是 Slider）不算。
      final iv = bar.indexOf('class _VolumeControl');
      expect(iv, greaterThan(0), reason: '★ `_VolumeControl` 不见了');
      final vol = sliceBalanced(bar, iv, '{', '}');
      indexOfExactly(vol, 'Slider(', want: 1, why: '★ 音量控件里恰好一根滑杆');
      indexOfExactly(vol, 'max: 100,');
      indexOfExactly(bar, 'max: 100,', want: 1, why: '★ 全底栏只有音量那一处用 0..100 量程');
    });

    test('E⑤ 选集入口仍是底栏上的**第一个**条件项（首屏够得到）', () {
      /*
       * ★ 承自 2026-10-05 那条反转过的判据：恒存在的入口必须排在条件项前面，
       *   否则在窄屏上会被挤出视口点不到。
       * ★ 红度证明：把「选集」那枚挪到条件项列表末尾 ⇒ 本条红。
       */
      final iEp = bar.indexOf("label: '选集'");
      expect(iEp, greaterThan(0), reason: '★ 底栏上要有「选集」入口');
      for (final other in <String>["label: '更多'", "label: '弹幕'"]) {
        final i = bar.indexOf(other);
        expect(i, greaterThan(0), reason: '★ 条件项 $other 必须在');
        expect(iEp, lessThan(i), reason: '★「选集」要排在其它条件项**之前**（窄屏首屏可达）');
      }
    });

    test('E⑥ popover 层由**页面**整屏 Stack 承载，不是底栏的子件', () {
      /*
       * ★★★ 这条是本轮踩过的**真坑**，写下来防止回退：
       * ```text
       * 底栏在页面里是 Positioned(bottom:0)、高约 106px 的盒子。
       * 面板挂在它内部时，能长到的上界被那 106px 卡死 ——
       * 实测（无头截图）：popover 展开后的 PNG 与「没展开」的 PNG
       * **md5 完全相同**，一像素都没画出来。
       * ⇒ 提到页面那个整屏 Stack 里当兄弟（`buildPopoverLayer()`）。
       * ```
       * ★ 红度证明：把挂载点挪回 `_BottomBar` 内部 ⇒ 本条红。
       */
      indexOfExactly(bar, 'Widget buildPopoverLayer()');
      // ⚠️ 判据用「两段都出现」而不是**整行逐字**匹配：
      //   `dart format` 会把 `=>` 后面那行折断，整行匹配会假红。
      expect(
        _page.contains('Widget buildPopoverLayer()'),
        isTrue,
        reason: '★ 页面要有 popover 层的构造入口',
      );
      expect(
        _page.contains('buildPopoverLayer(),'),
        isTrue,
        reason: '★★ 页面必须在整屏 Stack 里挂那一层（`ListenableBuilder` 的 builder）',
      );
      expect(
        _page.contains('bottom: _kPlayerBottomBarHeight'),
        isTrue,
        reason: '★ 面板要从底栏上沿往上长，不是贴着屏幕底',
      );
      indexOfExactly(
        _page,
        'const double _kPlayerBottomBarHeight = 96;',
        why: '★ 面板定位用的底栏高度必须是命名常量（两处要能对得上）',
      );
    });
  });
}
