// ═══════════════════════════════════════════════════════════════════════
//  task-66：④ 片头片尾 —— 黑竖条去留 + 四按钮显示对应帧 + 整段预览
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 为什么片头片尾设置，这里有一个黑色的竖着的东西？没有用的话就给删了，
// > 然后片头片尾这里预览还要支持预览片头 片尾整段，以确保自己没截取错误，
// > 点击片头片尾那四个按钮可以显示出对应的停止的那一帧的画面，
// > 方便确认自己没有截取错
//
// # 本文件测什么
//
// ```text
// A  黑竖条 = 播放头：**保留**但改成"一眼认得出是播放头"
//      ★ 先量清作用再决定 —— 它是时间轴上**唯一**的"当前预览在哪"指示
// B  四个按钮：**各自** seek 到**自己的**那一秒，且**停住**（显示那一帧）
//      ★ 不是"某个按钮会 seek" —— 那样写等于只测了一个按钮
// C  整段预览：片头 [introStart,introEnd] / 片尾 [outroStart,outroEnd]
// D  高度预算：新增一行**必须**同步 kMidRestH（否则第四行被挤出视口）
// ```
//
// ⚠️ 本文件**不挂真 `Player`** —— 会留真实定时器 ⇒ fake-async 排不干 ⇒
//    整个测试挂 10 分钟（本仓已踩过两次）。
//    用**源码结构断言** + **真 widget 树**（弹窗的 UI 不依赖预览加载成功）。
//
// 跑法：
//   powershell -File .probe\flutter_test_lock.ps1 `
//     -Paths 'test/t66_skip_preview_test.dart' -Agent lead

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

/// 剥掉注释（保留字符串字面量）—— 本仓铁律⑤
///
/// ⚠️ 必须剥：源码注释里**刻意引用**了 `colors.foreground` 等来记录
///    "为什么改掉它"。不剥的话"不许出现"类断言会被**注释**弄成假红。
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
      } else if (c == quote) {
        quote = null;
      }
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

/// 取一个**方法体**（按大括号配平）
///
/// ★ 用方法体而不是整个文件：本仓铁律⑤的同族 ——
///   先缩小范围再断言，否则"别处合法地用了 X"会造成假红/假绿。
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-02：修一个**工具 bug** —— 命名参数里的 `{` 被当成函数体
/// ══════════════════════════════════════════════════════════════════════
///
/// # 改前
/// ```dart
/// for (var i = src.indexOf('{', at); ...)   // ← 第一个 `{`
/// ```
/// 对**没有命名参数**的签名（如 `void _applyEdge(int? want, SkipEdge e)`）
/// 是对的。但一旦签名里有命名参数：
/// ```dart
/// void _previewRange(int from, int to, {SkipEdge? which}) {
///                                    ↑ ★ 这个 `{` 是**参数表**的
/// ```
/// ⇒ `bodyOf` 从参数表开始截，**函数体根本没进来**
/// ⇒ 里面所有断言（`play()` / `Timer.periodic`）**必然假红**。
///
/// ★ 这正是本仓那条纪律的又一个实例：
///   **判据必须落在它要判的那个东西上** ——
///   我拿"第一个 `{`"当"函数体的 `{`"，两个不同的量。
///
/// # 修法：先跳过**配平的参数表**，再找函数体的 `{`
/// ```text
/// ① 从签名起点往后找第一个 `(`
/// ② 配平圆括号 ⇒ 参数表结束位置
/// ③ 从那之后找第一个 `{` ⇒ 那才是函数体
/// ```
/// ⚠️ 兼容没有 `(` 的签名（如 `class X {`）：直接找 `{`。
String bodyOf(String src, String signature) {
  final at = src.indexOf(signature);
  expect(at, greaterThan(0), reason: '★ 找不到 `$signature` —— 断言会失效');

  // ① 跳过配平的**参数表**（若签名里有 `(`）
  var scanFrom = at;
  final parenAt = src.indexOf('(', at);
  final braceAt = src.indexOf('{', at);
  if (parenAt > 0 && (braceAt < 0 || parenAt < braceAt)) {
    var pd = 0;
    for (var i = parenAt; i < src.length; i++) {
      if (src[i] == '(') pd++;
      if (src[i] == ')') {
        pd--;
        if (pd == 0) {
          scanFrom = i;
          break;
        }
      }
    }
  }

  // ② 从参数表之后找函数体的 `{`
  var depth = 0;
  for (var i = src.indexOf('{', scanFrom); i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(at, i);
    }
  }
  fail('`$signature` 的大括号不配平');
}

late String tlRaw; // skip_timeline.dart 原文
late String tlSrc; // 剥注释后
late String dlgRaw; // skip_marker_dialog.dart 原文
late String dlgSrc; // 剥注释后

/// 挂真实弹窗（走真实 `showDialog`）—— 与生产同一条约束链
Future<void> openDialog(WidgetTester t) async {
  t.view.physicalSize = const Size(1280, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final theme = FTheme.neutral.light.desktop;
  await t.pumpWidget(MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () => showDialog<SkipMarkerResult>(
            context: ctx,
            barrierDismissible: false,
            builder: (_) => const SkipMarkerDialog(
              provider: 'tyyszy',
              id: '70260',
              title: '怒鲨狂潮',
              // ★ 不需要真流：预览失败走 `_previewError`，其余照常渲染
              streamUrl: 'file:///nonexistent.mp4',
              duration: Duration(seconds: 600),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() {
    tlRaw = File('lib/ui/widgets/skip_timeline.dart').readAsStringSync();
    tlSrc = stripComments(tlRaw);
    dlgRaw = File('lib/ui/widgets/skip_marker_dialog.dart').readAsStringSync();
    dlgSrc = stripComments(dlgRaw);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  A —— 黑竖条（播放头）的去留
  // ═══════════════════════════════════════════════════════════════════
  group('A 播放头**已删除**（Owner 第三次提，2026-10-01 拍板删掉）', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 这一组在 2026-10-01 **被反过来了** —— 记清楚为什么
     * ══════════════════════════════════════════════════════════════════
     *
     * # 原来（2026-09-27 task-66）断言的是「**保留**」
     * ```text
     * Owner：「为什么片头片尾设置，这里有一个黑色的竖着的东西？
     *         没有用的话就给删了」
     * 当时的决定：有用（它是"当前预览到第几秒"的唯一指示）⇒ 保留但改进
     * ⇒ 这一组四条断言全是"它必须还在"（`contains('_drawPlayhead')` 等）
     * ```
     *
     * # 现在（2026-10-01）Owner 明确要求删
     * ```text
     * Owner：「片头片尾设置那里,有一个黑色的竖着的线,给删除了这个」
     * Owner：「删除掉那个黑色的,然后只保留片头片尾的四个箭头就行了」
     * ```
     * ★ 为什么这次的决定是对的（与上次不矛盾）：
     * ```text
     * 上次"它有用"的判断没错 —— 但它有用**只因为**当时它是唯一的位置指示。
     * 而 Owner 的实际使用方式是：**看时间轴上方那块视频预览**判断位置
     *   （`_previewBox` 就在时间轴正上方，画面比一根线直观得多）。
     * ⇒ 他不需要那根线 ⇒ 对他而言它就是"一根黑色的竖线"。
     * ```
     * ★★ 元教训：**同一个东西被 Owner 提三次（09-24 / 09-27 / 10-01），
     *    前两次我都在"怎么把它做好看"（先调绘制顺序、后加 caret + 换色），
     *    而他要的是"不要它"。** 反复被提的 UI 元素，先问"要不要删"，
     *    再问"怎么改好"。
     *
     * ⚠️ 本组断言现在守的是**删除**，且必须包含**阳性对照**
     *    （四个箭头还在）—— 否则"删过头"（把时间轴整个删了）也会绿。
     */

    test('★★★ 播放头必须**已删除**（定义与调用都不许留）', () {
      expect(tlSrc.contains('_drawPlayhead'), isFalse,
          reason: '★★★ Owner 2026-10-01 明确要求删掉那根黑竖线 —— '
              '`_drawPlayhead` 的定义与调用都必须消失。'
              '（前一轮的断言是"必须保留"，本次**反过来**，见本组的说明）');

      // ★ 阴性对照的另一半：不能只是"不调用"，定义也得删 ——
      //   留一个死方法，下一个人会以为它还在用，或者顺手又接回去。
      expect(tlSrc.contains('void _drawPlayhead('), isFalse,
          reason: '★ 方法定义也必须删（不是只删调用）—— '
              '死方法会被后来人当成"还在用"而接回去');
    });

    test('★★★ 阳性对照：**四个箭头**仍然全部画出来（防"删过头"）', () {
      /*
       * ★ 没有这条，"把整个时间轴删掉"也会让上面那条绿 ——
       *   而 Owner 要的是"只保留四个箭头"，不是"什么都不要"。
       */
      final paint = bodyOf(tlSrc, 'void paint(Canvas canvas, Size size)');
      for (final edge in const [
        'SkipEdge.introStart',
        'SkipEdge.introEnd',
        'SkipEdge.outroStart',
        'SkipEdge.outroEnd',
      ]) {
        expect(paint.contains('drawArrow($edge'), isTrue,
            reason: '★★★ 四个箭头里的 `$edge` 不见了 —— '
                'Owner 要的是"只保留片头片尾的四个箭头"，'
                '删播放头**不能**连带删掉箭头');
      }
    });

    test('★ 轨道与区间高亮仍在（删的只是播放头，不是整条时间轴）', () {
      final paint = bodyOf(tlSrc, 'void paint(Canvas canvas, Size size)');
      expect(paint.contains('drawRRect'), isTrue,
          reason: '★ 轨道（`drawRRect`）必须还在');
      expect(paint.contains('drawRange'), isTrue,
          reason: '★ 两个区间的"会被跳过"高亮必须还在');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B —— 四个按钮**各自**显示对应的那一帧
  // ═══════════════════════════════════════════════════════════════════
  group('B 四个按钮：各自 seek 到自己的那一秒，且**停住**', () {
    test('★★★ 四个端点**全部**用同一个"显示该帧"入口（不许混用两种行为）', () {
      /*
       * ★ 改前是**混用**的：
       * ```text
       * 片头开始 → _previewSeek(v)              纯 seek
       * 片头结束 → _previewRange(_introStart,v) 区间循环
       * 片尾开始 → _previewRange(v,_outroEnd)   区间循环
       * 片尾结束 → _previewSeek(v)              纯 seek
       * ```
       * ⇒ "点四个按钮"得到**两种完全不同的行为**，
       *   而 Owner 要的是四个都"显示对应的那一帧"。
       */
      final rows = bodyOf(dlgSrc, 'Widget _rows(FColors colors)');
      final n = RegExp(r'onPreview: \(v\) => _previewFrame\(v\)')
          .allMatches(rows)
          .length;
      expect(n, 4,
          reason: '★★★ 四个端点**都**要用 `_previewFrame` —— 实测到 $n 个。'
              '少一个就说明那一个还是老行为（区间循环或纯 seek）');
      expect(rows.contains('_previewRange'), isFalse,
          reason: '★★★ `_rows` 里不得再出现 `_previewRange` —— '
              '区间循环已挪到独立的「整段」按钮（见 C 组）');
    });

    test('★★★ 四个按钮各自绑到**自己的**字段（不是同一个）', () {
      /*
       * ★ 防"四个都 seek 到同一个值"这类变异。
       *   逐个断言 `value:` 绑定的字段，且顺序必须是 开始→结束→开始→结束。
       */
      final rows = bodyOf(dlgSrc, 'Widget _rows(FColors colors)');
      final labels = RegExp(r"label: '([^']+)'")
          .allMatches(rows)
          .map((m) => m.group(1))
          .toList();
      expect(labels, ['片头开始', '片头结束', '片尾开始', '片尾结束'],
          reason: '★★★ 四行的标签与顺序必须完整（少一行 = 用户看不到那个端点）');

      final values = RegExp(r'value: (_\w+)')
          .allMatches(rows)
          .map((m) => m.group(1))
          .toList();
      expect(values,
          ['_introStart', '_introEnd', '_outroStart', '_outroEnd'],
          reason: '★★★ 四行必须各绑**自己的**字段 —— '
              '绑成同一个的话四个按钮会 seek 到同一秒（这正是变异 M1 要抓的）');
    });

    test('★★★ "显示该帧"必须**暂停**（否则画面一闪而过）', () {
      /*
       * ★ 为什么必须有 pause：
       *   用户上一步很可能是点了「整段」（⇒ `play()`）—— 那时播放器**正在播**，
       *   seek 过去之后画面**继续往前走**，用户根本来不及看那一帧。
       *   ⇒ 观感是"点了预览，画面一闪而过"，与 Owner 要的"停在那一帧"相反。
       */
      final f = bodyOf(dlgSrc, 'Future<void> _previewFrame(num seconds)');
      expect(f.contains('pause()'), isTrue,
          reason: '★★★ 必须 `pause()` —— 否则从"整段"切过来时画面不会停住，'
              'Owner 要的"显示那一帧"就做不到');
      expect(f.contains('_previewSeek('), isTrue,
          reason: '★ 定位仍要走既有的 `_previewSeek`（它已处理"等时长 + 核对"）');
    });

    test('★★★ 点某一帧必须**退出区间循环**（否则被拽回区间里）', () {
      /*
       * 用户点了"片尾结束"那一帧，若 `_loopTimer` 还在跑，
       * 200ms 后会把画面**拽回片头** —— "我点的是片尾，它却把我拉回片头"，
       * 比不响应更糟。
       */
      final f = bodyOf(dlgSrc, 'Future<void> _previewFrame(num seconds)');
      expect(f.contains('_loopTimer?.cancel()'), isTrue,
          reason: '★★★ 必须取消区间循环定时器 —— 否则点单帧后会被拉回区间');
      expect(f.contains('_loopFrom = null') && f.contains('_loopTo = null'), isTrue,
          reason: '★ 循环区间要一并清空（只 cancel 定时器会留下陈旧区间）');
    });

    test('★★★ 暂停**不能**塞进 `_previewSeek`（会掐死整段预览）', () {
      /*
       * ⚠️ 这条是"防后人图省事"的：
       *   `_previewRange` 内部也调 `_previewSeek`，然后紧接着 `play()`。
       *   若把 `pause()` 塞进 `_previewSeek`，它会**晚于** `play()` 落地
       *   （`_previewSeek` 是 async，要先 await 等时长）
       *   ⇒ **把区间循环播放直接掐死**（点了「整段」却一动不动）。
       */
      final seek = bodyOf(dlgSrc, 'Future<void> _previewSeek(num seconds)');
      expect(seek.contains('pause()'), isFalse,
          reason: '★★★ `_previewSeek` 里**不许** pause —— '
              '`_previewRange` 依赖它之后还能 play()，'
              '塞进来会让「整段」点了不动');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C —— 整段预览
  // ═══════════════════════════════════════════════════════════════════
  group('C 整段预览：片头 / 片尾各一个入口', () {
    test('★★★ 必须存在「整段」入口，且片头片尾**各一个**', () {
      /*
       * Owner：「预览还要支持预览片头 片尾**整段**」
       * ★ 这与"四个按钮显示那一帧"是**两个不同诉求**，必须各有入口：
       *   点 = 那一帧（静止）／段 = 循环播放（看运动）
       */
      expect(dlgSrc.contains('Widget _rangePreviewRow(FColors colors)'), isTrue,
          reason: '★★★ 必须有独立的「整段」行');
      final row = bodyOf(dlgSrc, 'Widget _rangePreviewRow(FColors colors)');
      final n = RegExp(r"label: '片[头尾]'").allMatches(row).length;
      expect(n, 2,
          reason: '★★★ 片头、片尾各一个「整段」按钮 —— 实测到 $n 个');
    });

    test('★★★ 片头整段 = [introStart, introEnd]，片尾整段 = [outroStart, outroEnd]', () {
      /*
       * ★ 逐个断言**配对正确** —— 防"片头按钮传了片尾的区间"这类变异。
       */
      final row = bodyOf(dlgSrc, 'Widget _rangePreviewRow(FColors colors)');
      // 片头那个必须传 _introStart / _introEnd
      expect(
          RegExp(r'label: .片头.,[\s\S]*?from: _introStart,[\s\S]*?to: _introEnd,')
              .hasMatch(row),
          isTrue,
          reason: '★★★ 「片头整段」必须传 [_introStart, _introEnd]');
      // 片尾那个必须传 _outroStart / _outroEnd
      expect(
          RegExp(r'label: .片尾.,[\s\S]*?from: _outroStart,[\s\S]*?to: _outroEnd,')
              .hasMatch(row),
          isTrue,
          reason: '★★★ 「片尾整段」必须传 [_outroStart, _outroEnd] —— '
              '传成片头的区间就是"点了片尾却在放片头"');
    });

    test('★★★ 整段走**循环播放**（不是"抓一帧"）+ 支持**暂停**', () {
      /*
       * Owner 原话里的「**并且可以预览的**」指的是这个：
       * 预览要能**播**（看到运动），不是一张静止图。
       * ★ task-57 一度被改成"抓一帧"，已回退 —— 这条防它再次退化。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02：Owner 又说「预览的时候不支持暂停」
       * ══════════════════════════════════════════════════════════════
       * 改前按钮直接调 `_previewRange` ⇒ 点了就循环播，**停不下来**。
       * ⇒ 现在按钮调 `_toggleRange`（播放 ⇄ 暂停切换），
       *   它内部**仍然**调 `_previewRange`（循环播放的能力没丢）。
       * ★ 所以判据改成两条：
       * ```text
       * ① 按钮必须走 `_toggleRange`（能暂停）
       * ② `_toggleRange` 必须调 `_previewRange`（仍然循环播，没退化成抓帧）
       * ```
       */
      final row = bodyOf(dlgSrc, 'Widget _rangePreviewRow(FColors colors)');
      expect(row.contains('_toggleRange('), isTrue,
          reason: '★★★ 「整段」必须走 `_toggleRange` —— '
              'Owner：「预览的时候不支持暂停」（点一下要能停住）');
      expect(row.contains('Icons.pause'), isTrue,
          reason: '★★★ 播放中必须显示暂停图标（用户要看得出"正在播"）');

      // ★ 阴性对照：循环播放的能力**没丢**
      final toggle = bodyOf(dlgSrc, 'void _toggleRange(SkipEdge which, int from, int to)');
      expect(toggle.contains('_previewRange('), isTrue,
          reason: '★★★ `_toggleRange` 必须调 `_previewRange` —— '
              '不能为了加暂停而把"整段循环播放"退化成抓一帧');

      final range = bodyOf(dlgSrc, 'void _previewRange(int from, int to');
      expect(range.contains('play()'), isTrue,
          reason: '★★★ `_previewRange` 必须真的 `play()` —— '
              '不播的话"整段预览"就是一张静止图，违反 Owner 的要求');
      expect(range.contains('Timer.periodic'), isTrue,
          reason: '★ 循环靠定时器回卷到区间开头（既有实现）');
    });

    test('★★★ 暂停语义：**停在当前帧**，不回区间开头', () {
      /*
       * ★ Owner 要的是"停下来让我看清这一帧" ——
       *   回开头等于把他刚看到的东西弄丢了。
       *   `_previewFrame` 正是"退循环 + pause + seek 到指定位置"。
       */
      final toggle = bodyOf(dlgSrc, 'void _toggleRange(SkipEdge which, int from, int to)');
      expect(toggle.contains('_previewFrame('), isTrue,
          reason: '★★★ 暂停必须走 `_previewFrame`（停住 + seek）—— '
              '它内部会 `_loopTimer.cancel()` + `pause()` + `seek`');
      expect(toggle.contains('_stopRange()'), isTrue,
          reason: '★★★ 暂停必须先 `_stopRange()` 退出循环 —— '
              '否则 `_loopTimer` 还在跑，会把画面**拽回区间开头**');
    });

    test('★★★ 「整段」未设全时**仍可点**（自动给默认区间）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02：这条**反过来了**，记清楚为什么
       * ══════════════════════════════════════════════════════════════
       *
       * # 改前（旧判据守的）
       * ```text
       * `from`/`to` 有 null ⇒ 按钮**置灰** + Tooltip 说明原因
       * 理由："静默失效会被用户当成按钮坏了"
       * ```
       *
       * # 为什么那个理由是错的
       * ★ 用户打开弹窗时**四个点都没设**（新剧集）⇒ **两个按钮全是灰的**
       *   ⇒ 他**根本没法预览**（Owner 截图里就是这样）。
       * ⇒ "置灰 + 说明原因" 只解决了"不知道为什么不能点"，
       *    **没解决"想预览但没得点"**。
       *
       * # Owner 的裁决
       * ```text
       * 「E. 「整段」未设置时也能点（自动给默认值）」
       * ```
       * ⇒ 未设时用**合理默认**（片头 0-30s、片尾 末尾 30s）先播起来，
       *   用户拖箭头后区间就变成他自己的了。
       *
       * ⚠️ 但"不静默失效"这条**仍然成立**：
       *    按钮仍带 Tooltip 说明"未设置，用默认范围"。
       */
      final row = bodyOf(dlgSrc, 'Widget _rangePreviewRow(FColors colors)');
      expect(row.contains('fallback'), isTrue,
          reason: '★★★ 未设全时要用 `fallback` 默认区间 —— '
              'Owner：「「整段」未设置时也能点（自动给默认值）」');
      expect(row.contains('usingDefault'), isTrue,
          reason: '★ 但 Tooltip 必须**说明**用的是默认范围 —— '
              '"不静默失效"这条仍然成立');
      // ★ 阴性对照：不能再有"因为有 null 就置灰"的逻辑
      expect(row.contains('missingHint'), isFalse,
          reason: '★★★ 旧的 `missingHint` 置灰逻辑必须去掉 —— '
              '它让用户打开弹窗时两个按钮全是灰的、根本没法预览');
    });

    testWidgets('★★★ 真 widget 树：两个「整段」按钮真的渲染出来了', (t) async {
      /*
       * ★ 源码断言只能证明"写了"，这条证明"真的渲染出来"。
       *   本仓铁律⑲：断言**结构**，不要只断言符号存在。
       */
      await openDialog(t);

      expect(find.text('片头整段'), findsOneWidget,
          reason: '★★★ 「片头整段」必须真的在树上');
      expect(find.text('片尾整段'), findsOneWidget,
          reason: '★★★ 「片尾整段」必须真的在树上');
      // 阳性对照：弹窗真的开了（否则上面两条可能是"树上什么都没有"）
      expect(find.text('片头开始'), findsOneWidget,
          reason: '★ 阳性对照：弹窗必须真的打开了');
      expect(find.text('片尾结束'), findsOneWidget,
          reason: '★ 阳性对照：四行必须都在（用户上次报的"只看到两行"）');
    });

    testWidgets('★★★ 真 widget 树：四个"预览"按钮都在（没被新行挤掉）', (t) async {
      await openDialog(t);
      // 1280 宽 ⇒ 非紧凑形态 ⇒ 四个都是带文字的「预览」
      expect(find.text('预览'), findsNWidgets(4),
          reason: '★★★ 四个端点各有一个「预览」按钮 —— '
              '新增「整段」行**不许**把其中任何一个挤掉');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  D —— 高度预算（新增一行必须同步常量）
  // ═══════════════════════════════════════════════════════════════════
  group('D 高度预算：新增一行必须同步 kMidRestH', () {
    test('★★★ `kMidRestH` 必须已把新行算进去', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★ 为什么这条是**硬约束**而不是"洁癖"
       * ══════════════════════════════════════════════════════════════
       *
       * `previewHeightFor` = `boxH - kChromeH - kMidRestH` ——
       * 它把"中段里除预览外的开销"整个扣掉，剩下的全给预览。
       *
       * 若新加了一行却**不加** `kMidRestH`：
       * ```text
       * 预览会多算 (新行高) ⇒ 中段真实总高 > 视口高
       * ⇒ ★ 第四行「片尾结束」被挤出滚动视口
       * ⇒ 正是用户 2026-09-24 报的「只看到片头设置的两个箭头」
       * ```
       * ★ 也就是：**漏改这个常量 = 把修好的 bug 原样请回来**。
       */
      // 旧基线 300 + 新行(kRowH=32) + 它与四行之间的间距(Sp.x2=8)
      const oldBaseline = 300.0;
      const added = kRowH + 8.0; // kRowH=32, Sp.x2=8
      expect(kMidRestH, greaterThanOrEqualTo(oldBaseline + added),
          reason: '★★★ `kMidRestH`($kMidRestH) 必须 >= '
              '${oldBaseline + added}（旧基线 $oldBaseline + 新行 $added）—— '
              '漏算会让预览多占高度，把第四行挤出视口');
    });

    test('★★★ 预览高度仍然 >= 最小值（新行没把画面压没）', () {
      /*
       * ★ 阳性对照式的边界：加了 40px 开销之后，
       *   740 高的弹窗里预览还剩多少？必须仍 >= kPreviewMinH。
       */
      final h = previewHeightFor(kDialogMaxH);
      // ignore: avoid_print
      print('[T66] 弹窗 ${kDialogMaxH.toInt()} 高 ⇒ 预览 ${h.toStringAsFixed(0)}px'
          '（改前 ${(kDialogMaxH - kChromeH - 300).toStringAsFixed(0)}px）');
      expect(h, greaterThanOrEqualTo(kPreviewMinH),
          reason: '★ 加了「整段」行之后预览仍不得低于最小值 '
              '（$kPreviewMinH）—— 低于它用户看不清画面，'
              '而"看清画面"是这个弹窗的核心诉求');
    });

    test('★★★ 新增行在 build 里真的被挂上（不是只定义了方法）', () {
      /*
       * ★ 防"写了 `_rangePreviewRow` 却没插进布局" ——
       *   那时源码断言全绿，但用户根本看不到按钮。
       */
      final build = bodyOf(dlgSrc, 'Widget build(BuildContext context)');
      expect(build.contains('_rangePreviewRow(colors)'), isTrue,
          reason: '★★★ `_rangePreviewRow` 必须**在 build 里被挂上** —— '
              '只定义不挂 = 用户看不到（源码断言却全绿）');
    });
  });
}
