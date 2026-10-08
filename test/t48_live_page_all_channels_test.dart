// ═══════════════════════════════════════════════════════════════════════
//  task-48【C】直播页「所有直播」面板 + 上下键切台
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（task-48 第 3 条）
//
// ```text
// 「直播页面可以看所有的直播,**就跟选集逻辑一样**,点击出来所有的直播,
//   然后**上下按键在这里**替换为切换直播」
// ```
//
// # ★★★ 为什么这个文件是**静态契约**而不是行为测试
//
// ```text
// 行为层有**结构墙**（已被独立确认两次，不是我的推测）：
//
//   ① `LivePageState._groups` 只由 `loadAll()` 从 FFI 填
//      （`live_page.dart:851`）⇒ `flutter test` 里没有核心 DLL
//      ⇒ FFI 抛错被 catch ⇒ `_groups` **恒为空**
//   ② 面板的入口 `onShowAll` 在 `allEpisodes.isEmpty` 时**就是 null**
//      （`live_page.dart:1848-1850`）⇒ 空数据下**没有入口可点**
//   ③ `_groups` 没有任何测试注入缝
//      （全仓搜 `debugInject|debugSetGroups|LivePage.debug|liveGroupsOverride` 零命中）
//
// 独立证据（不是我一个人说的）：
//   · `test/t74_perf_synth_test.dart:544-546` 逐字：
//     「★ 局限：无核心 DLL ⇒ `_groups` 为空 ⇒ `_probeAll` 的逐频道
//       setState 路径走不到，本文件测不到它」
//   · `test/zz_t42_gate_verification_test.dart:451-478` 记着同一道墙
//     （`_onKey` 在 flutter test 里结构不可达 ⇒ 用静态契约兜住）
//   · `lib/core/ffi.dart:169 DynamicLibrary.open('sourin_core.dll')`
//     —— 是 **FFI**，不是 MethodChannel ⇒ `setMockMethodCallHandler`
//     **注入不了**假频道
//
// ⇒ ★ 唯一可行的守法：**剥注释后读源码**，把"接线在不在"钉死。
//   这与 `zz_t42_gate_verification_test.dart` 的处置**同源**。
// ```
//
// # ⚠️⚠️ 每条断言都带**阳性对照**（否则"通过"可能只是"没匹配到"）
//
// ```text
// 只断言 `src.contains('...')` 是不够的 —— 若 `_codeOnly` 把整个文件剥空了，
// 断言会**全部失败**（那还好）；但若断言写成 `isNot(contains(...))` 这类
// 反向形式，"剥空了"就会**静默变绿**。
// ⇒ 本文件每个 group 都先证明"提取器真的工作"：
//    · `_functionBody` 取到的函数体非空
//    · `_codeOnly` 之后**注释里的词消失**（阴性对照）、
//      **代码里的词还在**（阳性对照）
//   ★ 这正是铁律 2：阳性对照失败 ⇒ 判据无效 ⇒ 结论作废。
// ```
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 只读一次，全局复用（4 个 group 都用同一份源码）
  final raw = _readFile('lib/ui/live_page.dart');
  final code = _codeOnly(raw);

  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检（**必须最先跑** —— 否则下面全是假绿）
  // ═══════════════════════════════════════════════════════════════════
  group('task-48【C】⓪ 仪器自检', () {
    test('★ 阳性对照：源码读到了，且是直播页', () {
      // ★★ 单位说明（我第一版在这里**写错了单位**，被这条断言自己抓住）：
      //   Dart 的 `String.length` 是 **UTF-16 码元数**，不是字节数。
      //   `live_page.dart` = 126,796 **字节**，但只有 87,608 **码元**
      //   —— 中文一个字 3 字节 / 1 码元。
      //   ⇒ 拿"12 万字节"去卡"码元数"必然假红（实测 rawLen=87608）。
      //   实测：rawLen=87608（码元）/ codeLen=40092（剥注释后）。
      expect(raw.length, greaterThan(80000),
          reason: '★ 前置：`live_page.dart` 是 12 万**字节**级的大文件'
              '（= 8.7 万**码元**，见上）。\n'
              '  若读到的很小 ⇒ 路径错了（读成了别的文件）⇒ 下面全是假绿。');
      expect(raw, contains('class LivePageState'),
          reason: '★ 前置：确认读到的**就是**直播页');
    });

    test('★★ 阴性对照：剥注释后，注释里的词**必须消失**', () {
      // `用户原话` 在本文件里**只**出现在注释里（`//` 与 `///` 与块注释）
      // —— 实测 8 处命中，逐处都是注释（行 75/162/167/719/1685/1886/2510/2550）
      expect(raw, contains('用户原话'),
          reason: '★ 前置：剥之前**必须**能搜到（否则下面的"消失"没意义）');
      expect(
        code,
        isNot(contains('用户原话')),
        reason: '★★★ 阴性对照：剥注释后**不该**还能搜到注释里的词。\n'
            '  若这条失败 ⇒ `_codeOnly` 没在剥注释 ⇒\n'
            '  下面所有 `contains` 断言都可能匹配到**注释文本**\n'
            '  ⇒ 全部是假通过（本项目已踩过 3 次，见 `live_page_test.dart` 文件头）。',
      );
    });

    test('★ 阳性对照：剥注释后，代码里的词**还在**', () {
      expect(code, contains('class LivePageState'),
          reason: '★ 阳性对照：剥注释不能把代码也剥掉');
      expect(code, contains('cycleChannel('));
    });

    test('★ 阳性对照：`_functionBody` 能取到两个键入口的函数体', () {
      final onKey = _functionBody(code, 'KeyEventResult _onKey(');
      final onHw = _functionBody(code, 'bool _onHardwareKey(');
      expect(onKey, isNotEmpty,
          reason: '★ 前置：定位不到 `_onKey` 函数体 ⇒ 下面那些断言全是空的');
      expect(onHw, isNotEmpty,
          reason: '★ 前置：定位不到 `_onHardwareKey` 函数体 ⇒ 下面全是空的');
      // 配平检查：函数体必须以 `}` 结尾且内部有内容
      expect(onKey.endsWith('}'), isTrue);
      expect(onHw.endsWith('}'), isTrue);
      debugPrint('VERDICT C0 instrument_ok '
          'rawLen=${raw.length} codeLen=${code.length} '
          'onKeyLen=${onKey.length} onHwLen=${onHw.length}');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 面板存在 + 入口接线
  // ═══════════════════════════════════════════════════════════════════
  group('task-48【C】① 面板存在与入口', () {
    test('★★ 必须有"所有直播"面板的状态位与复用组件', () {
      expect(code, contains('bool _allChannelsOpen = false;'),
          reason: '★ 面板开关的状态位（`live_page.dart:174`）');
      expect(code, contains('EpisodePanel('),
          reason: '★★ 用户原话是「**就跟选集逻辑一样**」⇒ 必须复用'
              '播放页"选集"的**同一个组件** `EpisodePanel`，\n'
              '  而不是新造一个"频道面板"（新造 = 两套形态、两套回归面）。\n'
              '  ★ 形态自动分流（PC 右抽屉 / 手机·TV 底部抽屉）'
              '在 `episode_strip.dart` 内部完成。');
      expect(code, contains('SheetTransition('),
          reason: '★ 与"选集"同源的进出场动画（不是裸 `AnimatedPositioned`）');
    });

    test('★★★ 入口：`onShowAll` 必须在**有频道时**才给', () {
      final squashed = _squash(code);
      expect(
        squashed,
        contains('onShowAll: allEpisodes.isEmpty ? null : '
            '() => setState(() => _allChannelsOpen = true),'),
        reason: '★★★ `_PageHead` 的"所有直播"入口。\n'
            '  · `allEpisodes.isEmpty ? null` —— 没频道时**不给入口**\n'
            '    （否则点开是个空面板，比没入口更困惑）\n'
            '  · `setState(() => _allChannelsOpen = true)` —— 点一下**打开面板**\n'
            '  ★ 这三段缺任何一段，用户原话"点击出来所有的直播"就没实现。',
      );
    });

    test('★★★ 面板必须列**全部**频道（不是按源过滤）', () {
      expect(code, contains('final allChannelEntries = _flatChannels;'),
          reason: '★★★ 用户要的是「可以看**所有**的直播」。\n'
              '  `_flatChannels` 是**跨源平铺**的全部可见频道（task-42/39）。\n'
              '  ⚠️ 若这里改成按 `_activeProvider` 过滤 ⇒ 用户只能看到'
              '当前选中源的台，原话就落空了。');
      final squashed = _squash(code);
      // ★★ 逐字取自源码（`dart format` 把它拆成**两个相邻字符串字面量**）：
      //     title: '${allChannelEntries[i].channel.name}'
      //         ' · ${allChannelEntries[i].tag}',
      //   ⇒ 拼接后是 `名字 · 源名`（`·` 两侧**各一个**空格）。
      //   ⚠️ 我第一版写成两个空格 —— 那是我**凭记忆**写的，不是从源码抄的
      //      ⇒ 假红。教训：逐字断言必须**从源码抄**，不能凭印象。
      expect(squashed, contains(r"' · ${allChannelEntries[i].tag}'"),
          reason: '★ 每项要**标出它来自哪个源**（title 里带 tag）——\n'
              '  与左栏列表同一口径。跨源平铺之后不标源，用户分不清谁是谁。');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② ★★★ 上下键门控（本文件最核心的判据）
  // ═══════════════════════════════════════════════════════════════════
  group('task-48【C】② ↑/↓ 门控（两道入口必须同源）', () {
    test('★★★ `_onKey`（焦点树路径）必须有门控，且**在切台之前**', () {
      final body = _functionBody(code, 'KeyEventResult _onKey(');
      expect(body, isNotEmpty, reason: '★ 前置（见 ⓪ 组）');

      expect(body, contains('cycleChannel('),
          reason: '★ 阳性对照：`_onKey` 确实会切台（否则它不需要门控）');

      const gate = 'if (_allChannelsOpen) return KeyEventResult.ignored;';
      expect(body, contains(gate),
          reason: '★★★ 门控 ④：面板打开时，焦点树那条路**必须放行** ↑/↓。\n'
              '  不加 ⇒ 一次按键**既切台又移动面板**（用户根本选不了）。');

      expect(
        body.indexOf(gate),
        lessThan(body.indexOf('cycleChannel(')),
        reason: '★★★ 顺序：门控必须在 `cycleChannel(` **之前**。\n'
            '  ★ 门控顺序错误在 `flutter analyze` 里**看不出来**（全绿），\n'
            '    只能靠追控制流 / 静态契约发现（本项目已记过这个坑）。',
      );
    });

    test('★★★ `_onHardwareKey`（early handler 路径）必须有门控，且**在切台之前**', () {
      final body = _functionBody(code, 'bool _onHardwareKey(');
      expect(body, isNotEmpty, reason: '★ 前置（见 ⓪ 组）');

      expect(body, contains('cycleChannel(1)'),
          reason: '★ 阳性对照：这就是 ↓ 的切台分支');
      expect(body, contains('cycleChannel(-1)'),
          reason: '★ 阳性对照：这就是 ↑ 的切台分支');

      const gate = 'if (_allChannelsOpen) return false;';
      expect(body, contains(gate),
          reason: '★★★ 门控 ④（early handler 侧）。\n'
              '  early handler 跑在**焦点树之前** ⇒ 它先看到 ↑/↓ ⇒\n'
              '  若不禁用，面板打开时按一下 ↓ 会：\n'
              '    ① `cycleChannel(1)` 立刻切台\n'
              '    ② 事件继续给焦点树 ⇒ 面板**也**移动一格\n'
              '  ⇒ 一次按键**移动两格 + 立刻切台**。');

      expect(
        body.indexOf(gate),
        lessThan(body.indexOf('cycleChannel(1)')),
        reason: '★★★ 顺序：门控必须在 ↓ 切台分支**之前**',
      );

      // ★ 返回值必须是 `false`（= ignored）而不是 `true`
      //   —— 返回 true 会把事件**吞掉**，面板就收不到 ↑/↓ 了
      expect(body, contains('if (_allChannelsOpen) return false;'),
          reason: '★★ 必须返回 `false`：让事件**继续往下走**给焦点树，\n'
              '  面板自己处理 ↑/↓（这正是 `EpisodeSheet` 既有的方向键行为）。\n'
              '  ⚠️ 返回 `true` = 吞掉事件 ⇒ 面板里的 ↑/↓ **完全没反应**。');
    });

    test('★★★ Esc 关闭面板，且**必须排在"面板打开 ⇒ return false"之前**', () {
      final body = _functionBody(code, 'bool _onHardwareKey(');
      expect(body, isNotEmpty, reason: '★ 前置（见 ⓪ 组）');

      const esc = 'if (_allChannelsOpen) {';
      const gate = 'if (_allChannelsOpen) return false;';

      expect(body, contains(esc),
          reason: '★ 面板必须能被 Esc 关掉（否则"打开了关不掉"）');
      expect(
        body.indexOf(esc),
        lessThan(body.indexOf(gate)),
        reason: '★★★ **顺序很关键**：Esc 处理必须在"面板打开 ⇒ return false"'
            '**之前**。\n'
            '  若排在之后 ⇒ 面板一打开，Esc 永远走不到那个分支\n'
            '  ⇒ 等于**面板关不掉**。\n'
            '  ★ `live_page.dart:697-701` 的注释逐字记着这个坑：\n'
            '    「第一版我就是这么写的……这类"门控顺序"错误在静态分析里'
            '**看不出来**（analyze 是绿的）」',
      );

      // Esc 分支里必须真的关面板（而不是只 return true）
      final escIdx = body.indexOf(esc);
      final escBlock = body.substring(
        escIdx,
        body.indexOf('}', body.indexOf('setState', escIdx)) + 1,
      );
      expect(escBlock, contains('setState(() => _allChannelsOpen = false)'),
          reason: '★★ Esc 分支必须**真的把面板关掉**（改状态），不能只 `return true`');
    });

    test('★★ 两道入口的判据必须**同源**（不能只挡一边）', () {
      final onKey = _functionBody(code, 'KeyEventResult _onKey(');
      final onHw = _functionBody(code, 'bool _onHardwareKey(');
      expect(onKey.contains('_allChannelsOpen'), isTrue,
          reason: '★ 焦点树那条必须有门控');
      expect(onHw.contains('_allChannelsOpen'), isTrue,
          reason: '★ early handler 那条也必须有门控');
      debugPrint('VERDICT C2 both_gates=true '
          'onKeyGate=${onKey.contains('if (_allChannelsOpen) return KeyEventResult.ignored;')} '
          'onHwGate=${onHw.contains('if (_allChannelsOpen) return false;')}');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 选中与关闭
  // ═══════════════════════════════════════════════════════════════════
  group('task-48【C】③ 选中 ⇒ 切台 + 关面板', () {
    test('★★★ `onPick` 必须"先关面板，再切台"', () {
      final args = _argsOf(code, 'EpisodePanel(');
      expect(args, isNotEmpty,
          reason: '★ 前置：定位不到 `EpisodePanel(` 的实参表 ⇒ 下面全是空的');

      expect(args, contains('onPick:'),
          reason: '★ 阳性对照：面板确实接了"点了某一项"的回调');
      expect(args, contains('onClose:'),
          reason: '★ 阳性对照：面板确实接了"关掉"的回调');

      final squashed = _squash(args);
      expect(squashed, contains('setState(() => _allChannelsOpen = false)'),
          reason: '★★ 选中之后面板要**关掉**（与"选集"点一下就走同一体验）');
      expect(squashed, contains('_select('),
          reason: '★★★ 选中之后必须**切台** —— 这是"就跟选集逻辑一样"的落点。\n'
              '  只关面板不切台 ⇒ 用户点了没反应。');

      // ★ 顺序：关面板在切台之前（先收 UI，再发网络请求）
      expect(
        squashed.indexOf('setState(() => _allChannelsOpen = false)'),
        lessThan(squashed.indexOf('_select(')),
        reason: '★ 顺序：先关面板再切台（避免"面板还开着、底下已经在换流"）',
      );
    });

    test('★★ `onPick` 必须**按 id 反查**频道（不能按下标）', () {
      final args = _squash(_argsOf(code, 'EpisodePanel('));
      expect(args, contains('e.channel.id == ep.id'),
          reason: '★★ 用 **id** 反查（不是下标）：\n'
              '  `allEpisodes` 与 `allChannelEntries` 是同一份数据，\n'
              '  但 id 反查对"列表顺序变化"免疫（探测会陆续剔除不可用频道）。');
    });

    test('★★ 面板必须告诉组件"当前选中的是哪一个"（高亮 + 自动滚动）', () {
      final args = _argsOf(code, 'EpisodePanel(');
      expect(args, contains('currentIndex:'),
          reason: '★ 阳性对照：确实传了当前索引');
      expect(args, contains('episodes:'),
          reason: '★ 阳性对照：确实传了列表');
      // curIdx 的定义必须是"按 id 找当前选中"
      expect(code, contains('allChannelEntries.indexWhere('),
          reason: '★★ `curIdx` 必须按 id 从**同一份** `allChannelEntries` 里找 ⇒\n'
              '  ↑/↓ 切台后高亮**自动跟随**（`EpisodeSheet` 的 `active` + '
              '`didUpdateWidget` 会滚到它）。');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 【A】的反面：本页**不得**再有 EPG 容器（与面板并存会互相盖）
  // ═══════════════════════════════════════════════════════════════════
  group('task-48【A/C】④ 本页不得再构造 EPG 容器', () {
    test('★ 剥注释后，源码里不能出现 EPG 容器类名', () {
      expect(code.contains('CollapsibleEpg'), isFalse,
          reason: '★ 用户要求【A】「直播删除掉节目单」。\n'
              '  ★ 注意本断言是**反向**的 ⇒ 必须靠 ⓪ 组的阳性对照\n'
              '    证明 `code` 不是空的（否则这条会静默变绿）。');
      expect(code.contains('_epgKey'), isFalse,
          reason: '★ EPG 的 GlobalKey 也必须一并删掉（取数链路整条没了）');
      // ⚠️ 只删**直播页的** —— SourinApi.getEpg 本身保留（别的页可能用）
      debugPrint('VERDICT C4 epg_container_absent=true');
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  静态分析工具（`_readFile` / `_codeOnly` 照抄
//  `zz_t42_gate_verification_test.dart:502-559`，**逐字一致**以便互证）
// ═══════════════════════════════════════════════════════════════════════

String _readFile(String rel) {
  // ★ 相对路径按 `flutter test` 的工作目录（项目根）解析
  final f = File(rel);
  if (f.existsSync()) return f.readAsStringSync();
  final alt = File('${Directory.current.path}/$rel');
  return alt.readAsStringSync();
}

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释，支持嵌套）
///
/// ★ 必须剥 —— 本项目踩过多次"断言匹配到注释文本 ⇒ 假通过"。
String _codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0;
  var inLine = false;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (depth > 0) {
      if (c == '/' && n == '*') {
        depth++;
        i += 2;
        continue;
      }
      if (c == '*' && n == '/') {
        depth--;
        i += 2;
        continue;
      }
      if (c == '\n') out.write('\n');
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && n == '*') {
      depth++;
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取某个函数/方法的**函数体**（从签名到配平的 `}`）
///
/// ★ 用配平括号而不是正则 —— 正则遇到嵌套花括号会截错。
String _functionBody(String code, String signaturePrefix) {
  final start = code.indexOf(signaturePrefix);
  if (start < 0) return '';
  final braceOpen = code.indexOf('{', start);
  if (braceOpen < 0) return '';
  var depth = 0;
  for (var i = braceOpen; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(braceOpen, i + 1);
    }
  }
  return '';
}

/// 取某次调用的**实参表**（从 `callPrefix` 的第一个 `(` 到配平的 `)`）
String _argsOf(String code, String callPrefix) {
  final start = code.indexOf(callPrefix);
  if (start < 0) return '';
  final open = code.indexOf('(', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')') {
      depth--;
      if (depth == 0) return code.substring(open, i + 1);
    }
  }
  return '';
}

/// 把连续空白压成一个空格
///
/// ★ 用途：源码里的实参/表达式经常**跨行**（dart format 的产物），
///   逐字 `contains` 会假红。压空白之后才能稳定匹配"逻辑上的一句话"。
/// ⚠️ 只在**已经剥掉注释**的源码上用（否则会把注释和代码压到一起）。
String _squash(String src) => src.replaceAll(RegExp(r'\s+'), ' ').trim();
