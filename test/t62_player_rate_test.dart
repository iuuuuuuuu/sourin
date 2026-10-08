// ═══════════════════════════════════════════════════════════════════════
//  task-21 P1-8 —— 播放设置面板里的「播放速度」一行
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件测什么
//
// 用户目标（yamby 抄作业）第 P1-8 条：**面板里要有倍速**。
// 本次在 lib/ui/widgets/player_settings_sheet.dart 新增了 _rateSection()
// （一行 _chip，7 档），宿主 player_page.dart 把 rate: _rate 与
// onSetRate: (r) => _player.setRate(r) 传进去。
//
// 本文件只覆盖「面板这一侧」：
// ```text
// ① 7 档真的渲染出来（真渲染，不是读源码）
// ② 真点一下真的回调出正确的 double（真点击，不是读源码）
// ③ 高亮真的跟着 rate 走（含**阴性对照**：非当前档必须不高亮）
// ④ 面板**不写**偏好、**不碰** _lastRateRequest（源码级 + 唯一写入点）
// ⑤ 面板**没有**新增 Slider（守住两条既有断言）
// ⑥ 档位与控制条 PopupMenuButton 逐字一致（源码级）
// ```
//
// # ⚠️ 为什么 `_rate` 的回填不在本文件里断言
//
// 面板点完之后，宿主 _rate 的新值来自 _player.stream.rate 广播
// （player_page.dart:2159-2163）。而 player_page.dart:674-687 的注释已写明：
// **`flutter test` 里原生 media_kit 不发任何事件** ⇒ 在单测里断言 _rate
// 变了是**空断言**（永远红或永远绿，测不到东西）。所以这里断言的是
// 「面板回调出了正确的值」，宿主那一跳由 .probe/yamby/ 的真机取证负责。
//
// # ⚠️ 面板在默认 800x600 视口里是**折叠**的
//
// 面板是固定 560 宽 + maxHeight 620 的卡片（player_settings_sheet.dart:541-542，
// task-25 D 之后这两行**刻意未动**，安全区内缩加在卡片外层的 Padding 上），
// 在 flutter_test 默认的 800x600 视口里，靠下的行会落在折叠线以下 ——
// 这时 t.tap 会打印 "derived an Offset ... that would not hit test on the
// specified widget" 然后**静默点空**（回调计数 0，看起来像产品坏了）。
// 这不是产品缺陷，是测试没滚。本项目 player_capability_test.dart:1106-1119
// 已经踩过同一个坑（它的注释原话：「音轨那一段在**折叠线以下**」）。
// 所以本文件一律用 _tapChip() 点档位：先滚进视口，再**核对中心点真在视口内**，
// 最后才 tap —— 免得某天面板长高之后这里变成假绿。
//
// # ⚠️ 断言前必须剥掉注释行
//
// 本项目的既定铁律（至少踩过 3 次）：代码里大量中文注释会**原样引用**
// 被断言的片段 ⇒ 静态断言匹配到注释 ⇒ 假通过。
// 下面的 _stripComments 逐字照抄 player_capability_test.dart:61-110
// 那个已被反向验证过的实现，不自己另写一个版本。

import 'dart:io';

// 注：RenderBox 不需要 import 'package:flutter/rendering.dart' ——
// material_ui 已经把 rendering 的公开类型带出来了（analyzer 实测：
// 单独 import 会报 unnecessary_import）。
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';

// ═══════════════════════════════════════════════════════════════════════
//  注释剥离器（逐字照抄 player_capability_test.dart:61-110）
// ═══════════════════════════════════════════════════════════════════════

String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;

  while (i < src.length) {
    final c = src[i];

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

    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }

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

String _codeOf(String path) => _stripComments(File(path).readAsStringSync());

// ═══════════════════════════════════════════════════════════════════════
//  夹具
// ═══════════════════════════════════════════════════════════════════════

/// 把控件套进真实的壳（与 player_capability_test.dart:120-127 同构）
Widget _host(Widget child) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Stack(children: [child])),
  );
}

/// 面板里那 7 档（与控制条 player_page.dart:10149-10157 逐字一致）
const List<String> _labels = <String>[
  '0.5x',
  '0.75x',
  '1x',
  '1.25x',
  '1.5x',
  '2x',
  '3x',
];

PlayerSettingsSheet _sheet({
  bool isLive = false,
  List<PlayerTrackOption> subtitleTracks = const [
    PlayerTrackOption(id: 'auto', label: '自动'),
    PlayerTrackOption(id: 'no', label: '关闭'),
    PlayerTrackOption(id: '1', label: '简体中文', hint: 'chi'),
  ],
  List<PlayerTrackOption> audioTracks = const [
    PlayerTrackOption(id: 'auto', label: '自动'),
    PlayerTrackOption(id: 'no', label: '关闭'),
    PlayerTrackOption(id: '1', label: '国语', hint: 'aac'),
  ],
  String currentSubtitleId = '1',
  String currentAudioId = '1',
  String? externalSubtitleName,
  Map<String, String> mpvStyle = const {
    'sub-ass-override': 'no',
    'sub-font': 'Microsoft YaHei',
    'sub-font-size': '55',
    'sub-color': '1.00/1.00/1.00',
    'sub-border-color': '0.00/0.00/0.00',
    'sub-border-size': '1.65',
    'sub-margin-y': '0',
  },
  PlayEndAction endAction = PlayEndAction.autoNext,
  bool countdownBeforeNext = true,
  bool keepSourceOnNext = true,
  bool autoSkip = true,
  bool isPlaying = true,
  bool clipDownloading = false,
  bool clipDownloaded = false,
  String? clipDownloadError,
  ValueChanged<int>? onSetConcurrency,
  VoidCallback? onDownloadClip,
  VoidCallback? onOpenClipDir,
  ValueChanged<String>? onPickSubtitle,
  ValueChanged<String>? onPickAudio,
  ValueChanged<String>? onLoadSubtitleFile,
  VoidCallback? onRemoveExternalSubtitle,
  void Function(String, String)? onSetMpvProperty,
  ValueChanged<PlayEndAction>? onSetEndAction,
  ValueChanged<bool>? onSetCountdown,
  ValueChanged<bool>? onSetKeepSource,
  ValueChanged<bool>? onSetAutoSkip,
  // ── task-21 P1-8（面板倍速）──
  double rate = 1.0,
  ValueChanged<double>? onSetRate,
  VoidCallback? onClose,
}) {
  return PlayerSettingsSheet(
    isLive: isLive,
    subtitleTracks: subtitleTracks,
    audioTracks: audioTracks,
    currentSubtitleId: currentSubtitleId,
    currentAudioId: currentAudioId,
    externalSubtitleName: externalSubtitleName,
    mpvStyle: mpvStyle,
    endAction: endAction,
    countdownBeforeNext: countdownBeforeNext,
    keepSourceOnNext: keepSourceOnNext,
    autoSkip: autoSkip,
    rate: rate,
    isPlaying: isPlaying,
    clipDownloading: clipDownloading,
    clipDownloaded: clipDownloaded,
    clipDownloadError: clipDownloadError,
    onSetConcurrency: onSetConcurrency ?? (_) {},
    onDownloadClip: onDownloadClip ?? () {},
    onOpenClipDir: onOpenClipDir ?? () {},
    onPickSubtitle: onPickSubtitle ?? (_) {},
    onPickAudio: onPickAudio ?? (_) {},
    onLoadSubtitleFile: onLoadSubtitleFile ?? (_) {},
    onRemoveExternalSubtitle: onRemoveExternalSubtitle ?? () {},
    onSetMpvProperty: onSetMpvProperty ?? (_, __) {},
    onSetEndAction: onSetEndAction ?? (_) {},
    onSetCountdown: onSetCountdown ?? (_) {},
    onSetKeepSource: onSetKeepSource ?? (_) {},
    onSetAutoSkip: onSetAutoSkip ?? (_) {},
    onSetRate: onSetRate ?? (_) {},
    onClose: onClose ?? () {},
  );
}

/// 取某个 chip 的**边框颜色** —— 高亮的唯一判据
///
/// _chip 的实现是 InkWell → Container(decoration: BoxDecoration(border: ...))。
/// 这里在 chip 子树里找**唯一**那个带边框的 Container，避免顺序依赖。
Color _chipBorderColor(WidgetTester t, String label) {
  final ink = find.ancestor(of: find.text(label), matching: find.byType(InkWell));
  expect(ink, findsOneWidget,
      reason: '★ 找不到该 chip 的 InkWell ⇒ 后面的断言全是恒真（假绿）');

  final found = <Color>[];
  for (final e in find.descendant(of: ink, matching: find.byType(Container)).evaluate()) {
    final w = e.widget as Container;
    final d = w.decoration;
    if (d is BoxDecoration && d.border is Border) {
      found.add((d.border! as Border).top.color);
    }
  }
  expect(found.length, 1,
      reason: '★ chip 里应当恰好 1 个带边框的 Container（_chip 的实现）');
  return found.single;
}

/// 点某个倍速档位 —— **先滚进视口，再核对中心点真在视口内，最后才 tap**
///
/// 不这么做的话，面板靠下的行会落在 800x600 视口的折叠线以下，
/// tap 打印一条 Warning 就点空了（回调计数 0）—— 那是测试的错，不是产品的错。
/// 这里的 expect 用与 WidgetController.tap 相同的判据（中心点落在视口矩形内），
/// 这样"点空了"会以**明确的原因**红掉，而不是一个孤零零的 Actual: <0>。
Future<void> _tapChip(WidgetTester t, String label) async {
  final f = find.text(label);
  expect(f, findsOneWidget, reason: '★ 面板里找不到档位「$label」');

  await t.ensureVisible(f);
  await t.pumpAndSettle();

  final box = t.renderObject<RenderBox>(f);
  final center = box.localToGlobal(box.size.center(Offset.zero));
  final view = t.view.physicalSize / t.view.devicePixelRatio;
  expect((Offset.zero & view).contains(center), isTrue,
      reason: '★★ 档位「$label」的中心点 $center 还在视口 $view 之外 ⇒ '
          '这一下 tap 会点到空气（与 WidgetController.tap 同一判据）');

  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  late String sheetSrc;
  late String pageSrc;

  setUpAll(() {
    sheetSrc = _codeOf('lib/ui/widgets/player_settings_sheet.dart');
    pageSrc = _codeOf('lib/ui/player_page.dart');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  1. 真渲染
  // ═══════════════════════════════════════════════════════════════════

  group('1. 倍速一行真渲染', () {
    testWidgets('★ 「播放速度」段落 + 「倍速」行 + 7 个档位 chip 都在', (t) async {
      await t.pumpWidget(_host(_sheet()));
      await t.pumpAndSettle();

      expect(find.text('播放速度'), findsOneWidget);
      expect(find.text('倍速'), findsOneWidget,
          reason: '★ 行标签必须是「倍速」—— 与控制条 tooltip 同一个词');

      for (final l in _labels) {
        expect(find.text(l), findsOneWidget, reason: '★ 档位没渲染出来：$l');
      }
      // 阴性对照：档位表之外的标签不该凭空出现
      expect(find.text('4x'), findsNothing);
      expect(find.text('1.75x'), findsNothing);
    });

    testWidgets('★ 直播态也显示倍速（与底栏倍速菜单一致，不被 isLive 藏掉）', (t) async {
      await t.pumpWidget(_host(_sheet(isLive: true, rate: 1.25)));
      await t.pumpAndSettle();

      expect(find.text('播放速度'), findsOneWidget);
      expect(find.text('1.25x'), findsOneWidget);
      // ★ 阴性对照：「连播」在直播下确实被藏了 ⇒ 证明 isLive 真的生效，
      //    而不是这个用例根本没进 isLive 分支
      expect(find.text('连播'), findsNothing,
          reason: '★ 直播下「连播」必须消失（面板原有行为）—— 若它还在，'
              '说明 isLive 没生效，上面那条断言就是空断言');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  2. 真点击 → 真回调
  // ═══════════════════════════════════════════════════════════════════

  group('2. 真点击倍速档位', () {
    testWidgets('★★ 点 1.5x ⇒ onSetRate 收到 1.5（真 widget 点击）', (t) async {
      final got = <double>[];
      await t.pumpWidget(_host(_sheet(onSetRate: got.add)));
      await t.pumpAndSettle();

      await _tapChip(t, '1.5x');

      expect(got, <double>[1.5],
          reason: '★ 必须回调**恰好一次** 1.5 —— 面板把「用户选了哪一档」原样交回宿主');
      // ★ 阴性对照：点倍速**不能**把面板关掉
      expect(find.text('播放设置'), findsOneWidget,
          reason: '★ 点倍速不该关闭面板（_chip 只回调 onSetRate）');
    });

    testWidgets('★★ 7 档逐一点一遍 ⇒ 回调值逐个对上', (t) async {
      final got = <double>[];
      await t.pumpWidget(_host(_sheet(onSetRate: got.add)));
      await t.pumpAndSettle();

      for (final l in _labels) {
        await _tapChip(t, l);
      }

      expect(got, <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0],
          reason: '★ 7 档的顺序与值必须与控制条 PopupMenuButton 一致');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  3. 高亮（含阴性对照）
  // ═══════════════════════════════════════════════════════════════════

  group('3. 当前档位高亮', () {
    testWidgets('★★ rate=2.0 ⇒ 2x 高亮、1x 不高亮（同一帧的阴性对照）', (t) async {
      await t.pumpWidget(_host(_sheet(rate: 2.0)));
      await t.pumpAndSettle();

      expect(_chipBorderColor(t, '2x'), Colors.lightBlueAccent,
          reason: '★ 当前倍速那一档必须高亮（_chip 的 active 分支）');
      expect(_chipBorderColor(t, '1x'), Colors.white24,
          reason: '★★ 阴性对照：非当前档必须**不高亮** —— '
              '若这里也是 lightBlueAccent，说明高亮是写死的（假功能）');
    });

    testWidgets('★★ rate 不在 7 档里（1.75）⇒ 一档都不高亮', (t) async {
      await t.pumpWidget(_host(_sheet(rate: 1.75)));
      await t.pumpAndSettle();

      for (final l in _labels) {
        expect(_chipBorderColor(t, l), Colors.white24,
            reason: '★ rate=1.75 不在档位里 ⇒ 任何档都不该高亮'
                '（证明高亮是数据驱动的，不是「第一个永远亮」）');
      }
    });

    testWidgets('★ 浮点回显容差：rate=1.5000000001 仍高亮 1.5x', (t) async {
      await t.pumpWidget(_host(_sheet(rate: 1.5000000001)));
      await t.pumpAndSettle();

      expect(_chipBorderColor(t, '1.5x'), Colors.lightBlueAccent,
          reason: '★ _rate 由 mpv 的 speed 属性回显，未必逐位相等 —— '
              '比较必须带容差，否则「明明选了 1.5x 却没高亮」');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  4. 面板的边界（不许越界的事）
  // ═══════════════════════════════════════════════════════════════════

  group('4. 面板边界', () {
    test('★★ 面板不写 lastSpeed 偏好（宿主是唯一写入点）', () {
      expect(sheetSrc.contains('lastSpeed'), isFalse,
          reason: '★ 面板**不写**偏好：player_page.dart:2163 的 stream.rate '
              '监听已无条件写了一次，再写就是两个真相');
      expect(sheetSrc.contains('_savePlayPref'), isFalse,
          reason: '★ 面板不该出现宿主私有方法名');
      expect(sheetSrc.contains('UiPrefs'), isFalse,
          reason: '★ 面板不直接落偏好存储');

      expect(pageSrc.split("_savePlayPref('lastSpeed'").length - 1, 1,
          reason: '★★ lastSpeed 全宿主**只允许一个写入点** —— '
              '出现第二个就说明面板那条路漏进来了');
      expect(pageSrc.contains("_savePlayPref('lastSpeed', v.toString())"), isTrue,
          reason: '★ 唯一写入点必须在 stream.rate 回调里（:2163）');
    });

    test('★★ 面板不碰 _lastRateRequest（PC 长按快进探针）', () {
      expect(sheetSrc.contains('_lastRateRequest'), isFalse,
          reason: '★ _lastRateRequest 是 PC 长按快进的探针字段，'
              'test/pc_arrow_keys_test.dart 有 15 处断言它 —— 面板碰它就是改语义');
      expect(sheetSrc.contains('_rateBy'), isFalse,
          reason: '★ 面板不做「加减 0.25」那种相对改法，只交回选中的档位');
    });

    test('★ 宿主接线：rate / onSetRate 与底栏 onRate 落点逐字一致', () {
      expect(pageSrc.contains('rate: _rate,'), isTrue,
          reason: '★ 面板必须拿到宿主真源 _rate');
      expect(pageSrc.contains('onSetRate: (r) => _player.setRate(r),'), isTrue,
          reason: '★ 面板回调必须落到 _player.setRate');
      expect(pageSrc.contains('onRate: (r) => _player.setRate(r),'), isTrue,
          reason: '★ 底栏那条（:7881）必须还在 —— 两个入口同一个落点');
    });

    test('★ 新段落插在 _audioSection() 之后、if (!isLive) 之前', () {
      final iAudio = sheetSrc.indexOf('_audioSection(),');
      final iRate = sheetSrc.indexOf('_rateSection(),');
      final iLive = sheetSrc.indexOf('if (!widget.isLive) ...[');
      expect(iAudio, greaterThan(0), reason: '★ 找不到 _audioSection() 调用点');
      expect(iRate, greaterThan(iAudio),
          reason: '★★ 倍速段落必须在音轨之后 —— '
              'player_capability_test.dart:1094 会**不滚动**直接点「关闭」，'
              '插到前面会把那一行挤出折叠线');
      expect(iLive, greaterThan(iRate),
          reason: '★ 必须在 isLive 门控**之外** ⇒ 直播也显示倍速');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  5. 不许新增 Slider（守住两条既有断言）
  // ═══════════════════════════════════════════════════════════════════

  group('5. 没有新增滑杆', () {
    testWidgets('★★ mpvStyle 全缺时，全面板只有一根可动滑杆（并发那根）', (t) async {
      await t.pumpWidget(_host(_sheet(mpvStyle: const {})));
      await t.pumpAndSettle();

      var movable = 0;
      for (final e in find.byType(Slider).evaluate()) {
        if ((e.widget as Slider).onChanged != null) movable++;
      }
      expect(movable, 1,
          reason: '★★ 只允许「并发」那一根可动滑杆'
              '（player_capability_test.dart:1260-1306 钉死这条）—— '
              '倍速必须用 _chip，不许用 Slider');
    });

    test('★ 面板源码里没有倍速滑杆', () {
      final i = sheetSrc.indexOf('Widget _rateSection() {');
      expect(i, greaterThan(0), reason: '★ 找不到 _rateSection() 定义');
      final body = sheetSrc.substring(i, i + 900);
      expect(body.contains('Slider'), isFalse,
          reason: '★ 倍速段落里不许出现 Slider（会抢走 '
              'player_capability_test.dart:1252 的 find.byType(Slider).first）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  6. 档位与控制条逐字一致
  // ═══════════════════════════════════════════════════════════════════

  group('6. 档位一致性', () {
    test('★ 面板 7 档 = 控制条 PopupMenuItem 7 档（逐字）', () {
      expect(
        sheetSrc.contains(
            'const _rateOptions = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];'),
        isTrue,
        reason: '★ 档位表必须与控制条逐字一致（两个入口看到的必须是同一组值）',
      );
      for (final v in const ['0.5', '0.75', '1.0', '1.25', '1.5', '2.0', '3.0']) {
        expect(pageSrc.contains('PopupMenuItem(value: $v, child: Text('),
            isTrue, reason: '★ 控制条里没有这一档：$v');
      }
    });

    test('★ 7 档都在宿主的合法区间内（0.25–4.0）', () {
      expect(pageSrc.contains('(_rate + delta).clamp(0.25, 4.0)'), isTrue,
          reason: '★ 宿主 _rateBy 的 clamp 区间变了 ⇒ 下面这条推断要重算');
      for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
        expect(v >= 0.25 && v <= 4.0, isTrue);
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  7. 面板不改偏好（Lead 要求钉死的那条差异）
  // ═══════════════════════════════════════════════════════════════════

  group('7. 面板改倍速不写偏好', () {
    setUp(() => UiPrefs.debugResetForTest());

    testWidgets('★★ 点 3x 之后 UiPrefs 里 lastSpeed 一个字节都没被写', (t) async {
      var called = 0;
      await t.pumpWidget(_host(_sheet(
        rate: 1.0,
        onSetRate: (v) {
          called++;
        },
      )));
      await t.pumpAndSettle();

      await _tapChip(t, '3x');

      expect(called, 1, reason: '★ 必须先确认这一下真点到了（否则下面恒真）');
      expect(UiPrefs.get('lastSpeed'), isNull,
          reason: '★★ 面板**不写**偏好 —— 写偏好是宿主 stream.rate 回调的事'
              '（player_page.dart:2163）。面板若也写，就是两个真相。');
      expect(UiPrefs.get('dsh.playprefs.lastSpeed'), isNull,
          reason: '★★ 同理，带前缀的键也不许出现');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  8. 布局不溢出
  // ═══════════════════════════════════════════════════════════════════

  group('8. 布局', () {
    testWidgets('★ 1280x800 下面板无 RenderFlex overflow', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(_host(_sheet()));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull,
          reason: '★ 面板是固定 560 宽 + maxHeight 620 的卡片'
              '（player_settings_sheet.dart:541-542，task-25 D 之后未动），'
              '1280x800 下不该有任何 overflow');
    });
  });
}
