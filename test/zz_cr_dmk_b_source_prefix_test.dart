// ═══════════════════════════════════════════════════════════════════════
//  zz_cr_dmk_b_source_prefix_test.dart
//  OPS-10 B 的**最后一半**：dandanplay 支状态文案的「来源前缀」硬门禁
// ═══════════════════════════════════════════════════════════════════════
//
// ── 这一针守什么 ────────────────────────────────────────────────────────
//
// 业主 1009 B② 逐字：「这个好像是概率性的,缓存到本地就不要显示换源按钮了,
// 然后这个弹幕还是显示 没收到凭证」
// （原话见 .probe/ops/DISPATCH-sidecar.md；同一条也记在 T73FIX-report.md §0）
//
// OPS-10 施工单 §4 把它翻成可执行的要求
// （.probe/ops/OPS-10-danmaku-cred-and-import.md，逐字）：
// ```text
// 修 B：按「先试 bilibili（无需登录），不行再试需要凭证的源」的口径确认当前
//       代码顺序，并**在 UI 上如实反映实际用的是哪个源的弹幕**。
// ```
// ⇒ OPS-10 B 给状态文案加了**来源前缀**。当前工作树实测（剥离注释后）：
// ```text
// lib/ui/player_page.dart:4733   _danmakuStatus = 'dandanplay · ${res.summary}';  ← 本文件守它
// lib/ui/player_page.dart:4741   status: 'dandanplay · ${res.summary}',           ← 同一支（面板读数）
// lib/ui/player_page.dart:5468   _danmakuStatus = 'B 站 · ${r.summary}';          ← t73 守
// lib/ui/player_page.dart:5510   _danmakuStatus = 'B 站 · ${r.summary}';          ← t73 守
// ```
// 每处两行，是因为同一个 setState 里要同时更新**播放页角标** _danmakuStatus
// 与**弹幕面板读数** _danmakuSettings.status。
//
// 为什么非要有前缀（lib 里的注释 :4723-4732 写得很清楚）：res.summary 自己是
// 「某番 第 3 集 · 842 条弹幕」，**不含源名**；B 站那侧**不要凭证**、
// dandanplay 那侧**要** —— 这个区别恰恰是业主排错时唯一要分清的事。
//
// ── 为什么必须单独一个文件（T73FIX 留下的覆盖缺口）────────────────────
//
// test/t73_bili_wiring_test.dart:352（T73FIX，已由 Lead 复核）只钉住了 **B 站那一半**：
// 它的锚点是 Future<void> _loadBiliDanmaku(，窗口 [i0, i0+2600)，
// 而 dandanplay 那一支在**另一个函数**（_loadDanmakuNamed）里 ⇒ 那一针看不见它。
// 实测：把 :4733 回退成 _danmakuStatus = res.summary;，
// **全 test/ 目录 0 条断言变红**。这就是本文件要补的洞。
//
// ── 规矩（写给后来的人：别在这里省事）──────────────────────────────────
// ```text
// ✗ 不许降断言：不许把「逐字前缀」放宽成 contains('dandanplay') / contains(' · ')
//   / startsWith —— 那等于不判。业主的诉求正是**前缀逐字**能分清源。
// ✗ 不许 skip：本文件**不带 @Tags**，必须进默认套件（flutter test test/ 一条不落）。
//   dart_test.yaml 里的 native-media / needs-isolated-userprofile / needs-shot-dir
//   三个标签与本判据无关，不许借用。
// ✗ 不许整块 Platform.isWindows 跳过：本判据**只读文件、不挂页面、不碰 libmpv**，
//   任何平台都该跑得动（需要 libmpv 的是「挂真 PlayerPage」，本文件不挂）。
// ✗ 不许 import package:media_kit/...：加载 libmpv 会让 flutter_tester 偶发
//   native 崩溃（证据链见 dart_test.yaml 顶部）。
// ✗ 不许联网：本文件只读一个本地文件。
// ```
//
// ── 判据手法（与 t73 同源：源码级契约断言）─────────────────────────────
// 读 lib/ui/player_page.dart → 剥注释 → 锚定函数 → 在**实测过**的窗口里找逐字字符串。
// 必须用 Dart **raw string**（r"..."）：针里有 ${res.summary}，
// 普通字符串会把 $ 当插值 ⇒ 运行时变成「... · Instance of ...」⇒ 针永远找不到（假红）。
//
// ⚠️ 本文件与 test/t73_bili_wiring_test.dart 是**两个独立文件**：t73 一个字都没动
//    （它是 T73FIX 的成果），这里只是把缺口补上。
// ═══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ══════════════════════════════════════════════════════════════════════
//  源码级判据的底座（stripComments 逐字照抄 test/t73_bili_wiring_test.dart:42-83）
// ══════════════════════════════════════════════════════════════════════

/// 剥掉 // 行注释、/// 文档注释、/* */ 块注释（保留字符串字面量）。
///
/// ⚠️ 必须剥：本仓踩过「把注释文本写进判据 ⇒ 永远找不到 ⇒ 假红」的坑，
///    而 player_page.dart 的注释里**正写着** _danmakuStatus = 'dandanplay · ...'
///    这段说明（:4723-4732）—— 不剥的话本判据会在**注释**上通过，等于假绿。
String stripComments(String src) {
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

const String _pagePath = 'lib/ui/player_page.dart';

/// 剥注释后的宿主源码（本文件的全部判据都读它）。
final String _page = stripComments(File(_pagePath).readAsStringSync());

/// 原始（未剥注释）源码 —— 只用来把命中位置换算成**人读的行号**，
/// 让失败信息能直接点名「player_page.dart:4733 那一行坏了」。
final String _pageRaw = File(_pagePath).readAsStringSync();

/// needle 在 raw 里首次出现的 1-based 行号；找不到返回 -1。
int _rawLineOf(String raw, String needle) {
  final i = raw.indexOf(needle);
  if (i < 0) return -1;
  return raw.substring(0, i).split('\n').length;
}

/// 锚点：dandanplay 支所在的函数。
const String _kAnchor = 'Future<void> _loadDanmakuNamed(';

/// 窗口大小 —— **实测后定的 2600**，不是猜的（读数见 test ①）：
/// ```text
/// i0（锚点绝对偏移，剥离注释后）= 51189
/// 针 _danmakuStatus = 'dandanplay · ${res.summary}'; 相对 i0 的命中偏移 = 1154，针长 47
/// ⇒ 末端相对偏移 1201，距 2600 上限还有 1399 字符余量
/// 面板读数那一针 status: 'dandanplay · ${res.summary}', 相对偏移 = 1453，末端 1491
/// 函数体本身到 i0+2865 结束（整根针都在窗口内、且余量充足）
/// ```
/// ★ 与 t73 用同一个 2600：这是本仓源码级判据的既有口径，不另立一套。
const int _kWindow = 2600;

/// 锚点与针在**原始文件**里的行号（仅用于失败信息点名；不参与判据，
/// 所以文件上方增删行不会让本门禁变红）。
final int _kAnchorRawLine = _rawLineOf(_pageRaw, _kAnchor);

/// ★★ 被钉的逐字契约（raw string ⇒ ${res.summary} 里的 $ 保持字面量）。
///
/// 这一根针**同时**钉住两条语义：
///   ① 右侧逐字 res.summary（不能换字段、不能写死字符串、不能换成 r.summary）；
///   ② 左侧逐字「dandanplay · 」前缀（不能退回无前缀形态、不能抄成别的源名）。
const String _kPin = r"_danmakuStatus = 'dandanplay · ${res.summary}';";

/// 针的左半：赋值 + 来源前缀（逐字，含前缀后那个空格与间隔号 ·）。
const String _kPinLeft = r"_danmakuStatus = 'dandanplay · ";

/// 针的右半：必须逐字仍是 res.summary。
const String _kPinRight = r"${res.summary}';";

/// 面板读数（_danmakuSettings.status）那一行，同一个来源前缀。
const String _kPinStatus = r"status: 'dandanplay · ${res.summary}',";

/// 回退形态（OPS-10 B 改之前的样子）—— 只允许出现在**注释**里，代码里不许有。
/// 本针在原始文件里的行号（实测 = 4733；仅用于失败信息点名）。
final int _kPinRawLine = _rawLineOf(_pageRaw, _kPin);

/// 失败信息里点名的「该行」：针在 → 针的行号；针不在但退化形态在 →
/// 退化形态的行号（**这正是「被回退」的场景，这个行号就是坏掉的那一行**）；
/// 两者都不在 → 锚点行号。
int get _shouldBeLine {
  if (_kPinRawLine >= 0) return _kPinRawLine;
  final legacy = _rawLineOf(_pageRaw, _kLegacyUnprefixed);
  return legacy >= 0 ? legacy : _kAnchorRawLine;
}

const String _kLegacyUnprefixed = '_danmakuStatus = res.summary;';

/// 别人的源前缀（B 站支）。它出现在 _loadDanmakuNamed 的窗口里 = 源标签抄错了。
const String _kBiliPrefix = r"'B 站 · ";

void main() {
  // ═══════════════════════════════════════════════════════════════════
  group('★ OPS-10 B：dandanplay 支的状态文案必须带来源前缀', () {
    test('① 锚点与窗口：先实测后钉（读数打印在此）', () {
      final i0 = _page.indexOf(_kAnchor);
      expect(i0, greaterThan(0),
          reason: '★★ 找不到锚点 $_kAnchor —— 函数被改名/删掉了？'
              '本判据锚在**函数**上，改名必须同步改这里（不许直接删断言）');

      final hit = _page.indexOf(_kPin, i0);
      final rel = hit - i0;
      // ignore: avoid_print
      print('[DMKPF 实测] 剥注释后长度=${_page.length} i0=$i0 '
          '窗口=$_kWindow 命中偏移(绝对)=$hit 相对i0=$rel '
          '针长=${_kPin.length} 末端相对=${rel + _kPin.length} '
          '余量=${_kWindow - rel - _kPin.length} | '
          'raw 锚点行=$_kAnchorRawLine raw 针行=$_kPinRawLine');

      expect(rel, greaterThanOrEqualTo(0),
          reason: '★★ 针在锚点之后找不到（绝对偏移 $hit）');
      expect(rel + _kPin.length, lessThan(_kWindow),
          reason: '★★ 针必须**整根**落在窗口里 —— 否则窗口太小 ⇒ 假红。'
              '实测相对偏移 $rel、针长 ${_kPin.length}、窗口 $_kWindow');
    });

    test('② 逐字契约：左半是「dandanplay · 」前缀，右半仍是 res.summary', () {
      final i0 = _page.indexOf(_kAnchor);
      expect(i0, greaterThan(0), reason: '★★ 找不到锚点 $_kAnchor');
      final body = _page.substring(i0, i0 + _kWindow);

      // 整根针（逐字）—— 这是最强的那一条。
      expect(body.contains(_kPin), isTrue,
          reason: '★★ OPS-10 B：dandanplay 这一支的状态文案必须逐字是 '
              '$_kPin。点名：锚点 $_kAnchor 在 $_pagePath:$_kAnchorRawLine，'
              '本针应在 $_pagePath:$_shouldBeLine'
              '（锚点 $_pagePath:$_kAnchorRawLine；'
              '若此处读到的就是锚点行，说明针在源码里根本找不到 ⇒ '
              '要么 lib 被回退、要么针自己抄错了）—— '
              '业主 1009 B② 要求 UI 上如实反映弹幕来自哪个源'
              '（B 站不要凭证、dandanplay 要，这正是他排错时要分清的事）');

      // 拆成左右两半各钉一次：失败信息能直接点名是哪一半坏了。
      final iLeft = body.indexOf(_kPinLeft);
      expect(iLeft, greaterThanOrEqualTo(0),
          reason: '★★ 左半 $_kPinLeft 不见了 ⇒ 来源前缀被删/被改'
              '（退回无前缀形态或抄成别的源）');
      expect(
        body.substring(iLeft + _kPinLeft.length).startsWith(_kPinRight),
        isTrue,
        reason: '★★ 右半必须是逐字 $_kPinRight —— 前缀后面跟的必须还是 res.summary，'
            '不能换字段、不能写死字符串（把源名写进状态里就再也反映不出实际数据了）',
      );
    });

    test('③ 面板读数同一行也要带前缀（角标 + 面板两处一起改）', () {
      final i0 = _page.indexOf(_kAnchor);
      expect(i0, greaterThan(0), reason: '★★ 找不到锚点 $_kAnchor');
      final body = _page.substring(i0, i0 + _kWindow);
      expect(body.contains(_kPinStatus), isTrue,
          reason: '★★ 只改角标不改面板 ⇒ 打开弹幕设置看到的读数还是没源名。'
              '两处都在同一个 setState 里，必须一起带前缀（实测两处都在本窗口内）');
    });

    test('④ 反向：本窗口里不许出现 B 站前缀（防「前缀被抄错源」）', () {
      final i0 = _page.indexOf(_kAnchor);
      expect(i0, greaterThan(0), reason: '★★ 找不到锚点 $_kAnchor');
      final body = _page.substring(i0, i0 + _kWindow);

      /*
       * ★★ 这一条是**反向**判据：_loadDanmakuNamed 走的是 dandanplay，
       *    它窗口里一旦出现 'B 站 · 前缀 ⇒ 源标签被抄错了源
       *    （用户会看到「B 站 · ...」却其实是 dandanplay 给的弹幕 ——
       *     比没有前缀更糟：业主会照着 B 站那条路去查，查不出任何东西）。
       *
       * ★ 实测（2026-10-10）：窗口里 'B 站 ·  = **0 次** ⇒ 严格判据成立，无需放宽。
       *   窗口里确实另有 2 处含「B 站」二字，但都**不是**来源前缀，故不受影响：
       *     · :4664 _flash('B 站弹幕：这一集没匹配到分 P（cid），已改用 dandanplay')
       *       —— 「绑了 B 站但这集没 cid」的落空提示（t73 与 zz_t3_flash_probe 另守）
       *     · :4801 「…这是 dandanplay 的凭证，与 B 站弹幕无关」 —— 失败提示的补充说明
       *   ⇒ 判据写在**带引号的前缀** 'B 站 · 上，而不是裸「B 站」二字上。
       */
      expect(body.contains(_kBiliPrefix), isFalse,
          reason: '★★ _loadDanmakuNamed 是 dandanplay 那条路，窗口里不该有 '
              '$_kBiliPrefix 前缀 —— 出现了说明源标签抄错了源（比没前缀更误导）');

      // 全文口径：dandanplay 前缀形态**有且仅有 1 处**（:4733 这一支）。
      final all = _page.split(_kPinLeft).length - 1;
      expect(all, 1,
          reason: '★ $_kPinLeft 在全文应恰好 1 次（:4733 这一支），实测 $all 次 —— '
              '多于 1 次说明别处也抄了 dandanplay 前缀，需要人来判断是不是抄错了源');
    });

    test('⑤ 不许退回无前缀形态（代码里），且反向形态在窗口里不存在', () {
      final i0 = _page.indexOf(_kAnchor);
      expect(i0, greaterThan(0), reason: '★★ 找不到锚点 $_kAnchor');
      final body = _page.substring(i0, i0 + _kWindow);

      expect(body.contains(_kLegacyUnprefixed), isFalse,
          reason: '★★ $_pagePath:$_shouldBeLine 不许退回无前缀形态 '
              '$_kLegacyUnprefixed —— OPS-10 B 之前的原样，'
              '业主 1009 B② 的诉求会当场失效');

      // 反向形态（把 B 站那条抄进 dandanplay 支）也不许有。
      expect(body.contains(r"_danmakuStatus = 'B 站 · "), isFalse,
          reason: '★★ dandanplay 支不许写成 B 站前缀 —— 抄错源');
    });
  });
}
