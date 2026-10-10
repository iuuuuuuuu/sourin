// ═══════════════════════════════════════════════════════════════════════
//  ★★★ XPLAT 门禁：test/ 里不许把**字面反斜杠**写进 File/Directory/Link 的路径实参
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷形态（本门禁要挡的那一类）
// ```text
// 2026-10-10 的 macOS CI run 有 9 条红，全部是同一类根因：
//   测试里把路径分隔符用**字面反斜杠**写死。
// 在 POSIX 上反斜杠**只是普通文件名字符**、不是分隔符 —— 于是
//   File('build/probe-shots' + 反斜杠 + '449_dialog.png')
// 在 macOS 上不是「build/probe-shots 目录下的 449_dialog.png」，
// 而是「仓库根下、名字里带一个反斜杠的**单个文件**」。
//
// ★ 最阴的一档是**静默跑偏**（本门禁挡下的第一个真缺陷就是这种）：
//   test/t449_skip_dialog_shot_test.dart:109-111 先
//     Directory('build/probe-shots').createSync(recursive: true)
//   —— 父目录 build 已存在 ⇒ 这句在 macOS 上**不抛**，
//   随后写出的垃圾文件落在 build/ 根下、名字里带反斜杠，
//   而断言只看 png.length > 1000 ⇒ **照样绿**。
//   ⇒ 不红 ≠ 没缺陷；它只是在 macOS 上「悄悄写错地方 + 留垃圾」。
// ```
//
// # ★★ 为什么判据是**静态扫源码**，而不是「跑一遍用例看红不红」
// ```text
// 缺陷在 Windows 上**完全不可见**（那里反斜杠就是分隔符）⇒ 任何运行时用例
// 在本机都测不出它，绿了也证明不了什么。本仓铁律是「假门禁比红更糟」
// ⇒ 必须换一个**能真正区分对错**的判据：直接扫源码里的路径实参。
// ```
//
// # ★★★ 为什么**不能**用 Platform.isWindows 整块跳过（写死这个决定）
// ```text
// ① 缺陷在 Windows 上不可见 ⇒ 写缺陷的人**只**在 Windows 上开发。
//    若门禁在 Windows 上跳过，它就永远没在「能发现缺陷的那台机器」上跑过；
//    本机绿 = 什么都没证明（正是本仓在骂的假门禁形态）。
// ② 判据是**静态**的：源码文本对不对，与跑门禁的机器是什么系统**无关**。
//    在 Windows 上跑同一条判据，得到的是**同一个**答案 —— 没有任何理由跳过。
// ③ 平台门（if (Platform.isWindows) return;）会让 Windows job 恒绿，
//    而 macOS job 才是红的那个 —— 等于把「谁来发现」推给最慢的反馈环。
// ⇒ 本门禁**无条件**在两端都跑；它不碰文件系统语义，只读源码文本。
// ```
//
// # 判据（**窄且准**：宁可漏报，不要误报）
// ```text
// 只抓一种东西：File( / Directory( / Link( / FileSystemEntity( 的**实参**里，
//   某个字符串字面量的**运行时值**含有反斜杠。
// 「运行时值」= 把字面量按 Dart 规则解出转义后的真实内容：
//   非 raw 字面量：\n \t \r \b \f \v \0 \' \" \$ \\ \xHH \uHHHH 都是**转义**，
//                 解出来是换行/制表符/退格… 或一个反斜杠；未识别的转义原样保留。
//   raw 字面量（r'...'）：**不做转义**，反斜杠原样进入路径 ⇒ 直接算命中。
// ⇒ '$_outDir\\449_dialog.png' 命中（运行时是 …\449_dialog.png）；
//   r'D:\WishProject\…' 命中（raw，反斜杠原样）；
//   .split('\n') 之类**不**命中（运行时是换行，里面没有反斜杠）。
//
// 必须排除的误报源（逐条对照）：
//   ① 注释 / 文档字符串里的反斜杠 —— 扫描器带跨行状态机（块注释、三引号
//      字符串），注释里的样本根本不进判据。
//   ② 转义序列（\n \t \r \b \f \v \0 \xHH \uHHHH）—— 见上「运行时值」。
//   ③ 用 Platform.pathSeparator / p.join 拼的路径 —— 字面量里**没有**反斜杠
//      ⇒ 天然不命中，不需要特判。
//   ④ raw 字面量里「引用分隔符这个字符本身」的用法（x.replaceAll(r'\', '/')）
//      —— 它的运行时值**整个就是反斜杠**、且**整个实参就是它自己**（前后是
//      ( , 或 ) ）⇒ 判为「引用字符」而不是「拼路径」，不报。
//      ⚠️ 若同一个字面量紧挨加号（dir + r'\' + name），那就是真拼路径 ⇒ 报。
//   ⑤ 纯字面量的固定路径（盘符绝对路径）—— 判据**刻意不判**它有没有害
//      （那要读语义、会变宽）；已知无害的逐条进豁免表（见下）。
// 只抓「字面量**运行时含反斜杠**」这一个条件，不做更宽的启发式 ——
//   宽判据会把门禁变成噪音，然后被人整块废弃（比没有门禁更糟）。
// ```
//
// # 豁免（**有名字 + 有行号 + 有理由**，绝不静默跳过）
// ```text
// 豁免必须**真的挂着**：被豁免的那一行若已无命中 ⇒ 红（逼你删掉过期豁免）。
// 豁免粒度是**文件:行号**，不是「整个文件跳过」—— 同一个文件里**其它行**
// 有命中照样红。本文件不用 skip:、不用整块跳过、不用 Platform 门。
// ```
//
// # ★ 已知漏报边界（写清楚，免得后人以为它是万能的）
// ```text
// ① 实参**跨行**时本判据不判（如 File( 换行 a + b 换行 )）—— 逐行扫描器只在
//    本行内配对右括号，配不上就跳过（扫描时会打印「跨行实参未判定 N 处」）。
// ② 路径由**变量**拼出来的（File(path)、File(a + sep + b)）静态看不见。
// ③ 本文件**排除自己**（注释与阳性对照里必然有反斜杠样本），
//    所以它自己不被本门禁管 —— 与 zz_cr_dl_c25_path_sep_test.dart 同款取舍。
// ④ 只覆盖 File/Directory/Link/FileSystemEntity 四个构造器；
//    直接调 dart:io 其它 API（如 XFile('a\\b')）不在管辖内。
// ⑤ 只扫 test/ 下 *.dart；lib/、tool/、脚本里的同类缺陷不归本门禁管。
// ⑥ 判据是「字面量运行时含反斜杠」，**不**判断那个反斜杠是不是真的当分隔符用；
//    无害的命中靠豁免表逐条登记（豁免表因此必须有人维护）。
// ```
//
// # 阳性 / 阴性对照（主用例第 ⑥ 步）
// ```text
// ★ 本门禁自带对照：用**同一套判据**跑两段内联样例文本 ——
//   阳性样例必须报（否则判据是恒空的假门禁），
//   阴性样例必须不报（否则判据是恒红的噪音）。
//   ⚠️ 注意拼法：简报里的样例写成 File('a\b.png')（源码单个反斜杠 + b），
//     但那在 Dart 里是**退格符**，运行时值里没有反斜杠 ⇒ 它**不是**本缺陷，
//     判据正确地不报（已钉进阴性对照）。本缺陷的真实拼法是
//     File('a\\b.png')（源码双反斜杠）或 raw 写法 File(r'a\b.png') ——
//     阳性对照两种拼法都覆盖。
// ```
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本门禁自己：注释与阳性对照里必然含反斜杠样本 ⇒ 必须排除，否则判据一收紧就恒红
const String kSelfRelativePath = 'zz_cr_xplat_path_test.dart';

/// 路径构造器家族：实参里出现**运行时反斜杠** ⇒ 违规
const List<String> kPathCtors = <String>[
  'File',
  'Directory',
  'Link',
  'FileSystemEntity',
];

/// 扫描文件数的下限：防「扫描器空跑」假绿（test/ 下当前 300+ 个 dart 文件）
const int kMinScannedFiles = 200;

/// ★ 冻结的**必须覆盖**名单（金丝雀，用相对 test/ 的路径，子目录用 / 分隔）。
///
/// 发现口径（递归列举 test/ 下全部 *.dart）一旦退化 —— 比如 listSync 忘了
/// recursive、或误加了后缀/前缀过滤 —— 这里就带着文件名红。
/// 名单**刻意不写全集**：全集靠动态发现，这里只钉「必须出现」的样本。
const List<String> kMustBeCovered = <String>[
  // 本批真缺陷所在文件（修好后仍必须被扫到）
  't449_skip_dialog_shot_test.dart',
  // 子目录必须被递归覆盖（listSync(recursive: true) 的证据）
  'support/ui_shot.dart',
  'support/zz_cr_upd_origin.dart',
  '_support/strip_comments.dart',
  // 同批别的探针 / 回归门禁文件（同类缺陷的历史高发区）
  'task32_source_name_test.dart',
  'task37_poster_placeholder_test.dart',
  'zz_cr_dl_c25_path_sep_test.dart',
  'zz_t3_20_download_dir_probe_test.dart',
  'zz_t12_cache_page_probe_test.dart',
  'zz_t3_19_cache_page_probe_test.dart',
];

/// 显式豁免：**文件 + 行号 + 理由**。豁免必须真的挂着（见主用例第 ⑤ 步）。
class Waiver {
  const Waiver(this.relativePath, this.line, this.reason);
  final String relativePath; // 相对 test/，子目录用 /
  final int line; // 1-based 行号
  final String reason;
}

/// ★ 豁免表全文（**有名字 + 有行号 + 有理由**，没有「跳过整个文件」）。
///
/// 判据本身**刻意不**判「这个反斜杠有没有害」—— 那要读语义，会变宽。
/// 已知无害的命中在这里逐条豁免，理由必须能被独立复核。
const List<Waiver> kWaivers = <Waiver>[
  Waiver(
    'support/ui_shot.dart',
    72,
    '真缺陷形态（常量 dir 后面拼两个字面反斜杠），但**无害**：'
        'const dir = r「C:\Windows\Fonts」 是 Windows 系统字体目录，'
        '整块只用来把微软雅黑注册进 flutter_tester；'
        '路径不存在时被 .where((f) => f.existsSync()) 过滤掉，'
        '文件头注释里写明「非 Windows（CI 的 macOS）上没有 C:\Windows\Fonts '
        '⇒ 自动退回 Ahem，不报错」⇒ 不产生断言、不写文件、不会把 macOS 带红。'
        '改成 Platform.pathSeparator 属另一个写入范围（本门禁的写入范围只有本文件）。',
  ),
  Waiver(
    'support/ui_shot.dart',
    73,
    '同上（msyhbd.ttc 那一行），同一块代码、同一个理由。',
  ),
  Waiver(
    'task32_source_name_test.dart',
    348,
    'raw 字面量写死的**另一台机器/另一个仓库**的绝对路径'
        '（r「D:…\cctv_to_client\…SourcePicker.vue」）。'
        '它是「原版参考实现」的取样路径，语义就是「本机开发机上那个外部仓库」；'
        '不存在时该用例自己 print + return（跳过而不是失败）⇒ macOS 上安全。'
        '改成 Platform.pathSeparator 毫无意义：盘符 D: 本身已经把它钉成 Windows 专用。',
  ),
  Waiver(
    'task37_poster_placeholder_test.dart',
    491,
    '同 task32 形态与理由：r「D:…\cctv_to_client\src\design\base.css」 '
        '是外部仓库取样路径，不存在时 print + return（见同文件 :495-499）。',
  ),
  Waiver(
    'task37_poster_placeholder_test.dart',
    493,
    '同上（theme-light.css 那一行），同一处取样、同一个理由。',
  ),
];

// ───────────────────────── 源码扫描器 ─────────────────────────

/// 一个字符串字面量（在**某一行的源码文本**里的位置与内容）
class _Lit {
  const _Lit(
      this.start, this.end, this.isRaw, this.body, this.closer, this.closed);
  final int start; // 起始下标（引号本身）
  final int end; // 结束下标（闭合引号之后）
  final bool isRaw; // r 前缀 ⇒ 不做转义、不做插值
  final String body; // 引号之间的**源码原文**
  final String closer; // 闭合引号（三引号时是三个字符）
  final bool closed; // 本行内是否闭合成
}

/// 一次构造器调用（实参文本 + 是否在本行内配对成功）
class _Call {
  const _Call(this.ctor, this.args, this.argsClosed);
  final String ctor;
  final String args; // 括号之间的**源码原文**
  final bool argsClosed; // 右括号是否落在本行
}

/// 跨行状态：块注释 / 未闭合的多行字面量
class _ScanState {
  bool inBlock = false;
  String? triple;
}

/// 一处违规
class Violation {
  const Violation(this.line, this.source, this.detail);
  final int line; // 1-based
  final String source; // 该行原文（trim 过）
  final String detail; // 命中说明（构造器 + 字面量运行时值）
}

/// 已知转义序列 ⇒ 它们的运行时值**不是**反斜杠
///
/// ★ 这就是「\n \t 之类不算违规」的全部依据。
const Map<String, String> kKnownEscapes = <String, String>{
  'n': '\n',
  't': '\t',
  'r': '\r',
  'b': '\b',
  'f': '\f',
  'v': '\v',
  '0': '\u0000',
  "'": "'",
  '"': '"',
  r'$': r'\',
  r'\': r'\',
};

bool _isSpace(String c) => c == ' ' || c == '\t';

bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A) ||
      c == '_' ||
      c == r'$';
}

bool _isIdentChar(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A) ||
      c == '_' ||
      c == r'$';
}

int _identEnd(String s, int start) {
  var i = start;
  while (i < s.length && _isIdentChar(s[i])) {
    i++;
  }
  return i;
}

/// 从 raw[start]（引号本身）开始读一个字面量
_Lit _readLiteral(String raw, int start) {
  final q = raw[start];
  final p = start - 1;
  final isRaw = p >= 0 &&
      (raw[p] == 'r' || raw[p] == 'R') &&
      (p == 0 || !_isIdentChar(raw[p - 1]));
  final triple =
      start + 2 < raw.length && raw[start + 1] == q && raw[start + 2] == q;
  final closer = triple ? q + q + q : q;
  var j = start + 1;
  while (j < raw.length) {
    if (!isRaw && raw[j] == r'\') {
      j += 2; // 转义：跳过下一个字符（\ 与 \" 都算）
      continue;
    }
    if (raw.startsWith(closer, j)) {
      return _Lit(start, j + closer.length, isRaw, raw.substring(start + 1, j),
          closer, true);
    }
    j++;
  }
  return _Lit(
      start, raw.length, isRaw, raw.substring(start + 1), closer, false);
}

/// 字面量的**运行时值**：按 Dart 规则解转义（raw 原样）
String _runtimeValue(_Lit lit) {
  if (lit.isRaw) return lit.body; // raw 不做转义 ⇒ 反斜杠原样进路径
  final sb = StringBuffer();
  var i = 0;
  while (i < lit.body.length) {
    final c = lit.body[i];
    if (c == r'\' && i + 1 < lit.body.length) {
      final n = lit.body[i + 1];
      final known = kKnownEscapes[n];
      if (known != null) {
        sb.write(known);
        i += 2;
        continue;
      }
      if (n == 'x' || n == 'u') {
        // \xHH / \uHHHH / \u{...} 都是转义（十六进制码点）⇒ 不是反斜杠
        var k = i + 2;
        if (n == 'u' && k < lit.body.length && lit.body[k] == '{') {
          final e = lit.body.indexOf('}', k);
          k = e < 0 ? lit.body.length : e + 1;
        } else {
          var digits = n == 'x' ? 2 : 4;
          while (digits > 0 && k < lit.body.length) {
            k++;
            digits--;
          }
        }
        sb.write('?'); // 占位：码点内容与「有没有反斜杠」无关
        i = k;
        continue;
      }
      sb.write(r'\'); // 未识别的转义：反斜杠留着（宁可报）
      sb.write(n);
      i += 2;
      continue;
    }
    sb.write(c);
    i++;
  }
  return sb.toString();
}

/// body 里**只有**反斜杠吗（=「引用分隔符这个字符本身」的形态）
bool _allBackslashes(String s) {
  if (s.isEmpty) return false;
  for (var i = 0; i < s.length; i++) {
    if (s[i] != r'\') return false;
  }
  return true;
}

/// 这个字面量**整个就是一条实参**吗（前后是 ( , 或 )）——
/// 用来把 x.replaceAll(r'\', '/') 这种「引用字符」和 dir + r'\' + name 区分开
bool _isStandaloneArg(String args, _Lit lit) {
  var a = lit.start - 1;
  // ★ raw 字面量的 r 前缀属于字面量本身，不能当实参边界
  //   （r'' 的引号前面那个字符是 r，不是 ( 或 , ⇒ 不跳过就会把
  //    x.replaceAll(r'', '/') 误判成「拼路径」）
  if (lit.isRaw && a >= 0 && (args[a] == 'r' || args[a] == 'R')) a--;
  while (a >= 0 && _isSpace(args[a])) {
    a--;
  }
  final leftOk = a < 0 || args[a] == '(' || args[a] == ',';
  var b = lit.end;
  while (b < args.length && _isSpace(args[b])) {
    b++;
  }
  final rightOk = b >= args.length || args[b] == ',' || args[b] == ')';
  return leftOk && rightOk;
}

/// 实参文本里的字面量
List<_Lit> _literalsIn(String args) {
  final out = <_Lit>[];
  var i = 0;
  while (i < args.length) {
    final c = args[i];
    if (c == "'" || c == '"') {
      final lit = _readLiteral(args, i);
      if (!lit.closed) break;
      out.add(lit);
      i = lit.end;
      continue;
    }
    i++;
  }
  return out;
}

/// 本行内与 open 处左括号配对的右括号下标（-1 = 本行配不上）
int _matchParen(String raw, int open) {
  var depth = 0;
  var i = open;
  while (i < raw.length) {
    final c = raw[i];
    if (c == "'" || c == '"') {
      final lit = _readLiteral(raw, i);
      if (!lit.closed) return -1;
      i = lit.end;
      continue;
    }
    if (c == '/' && i + 1 < raw.length && raw[i + 1] == '/') return -1;
    if (c == '(') {
      depth++;
      i++;
      continue;
    }
    if (c == ')') {
      depth--;
      if (depth == 0) return i;
      i++;
      continue;
    }
    i++;
  }
  return -1;
}

/// 本行的构造器调用（带跨行状态机：注释与多行字符串里的东西不算代码）
List<_Call> _callsOnLine(String raw, _ScanState st) {
  final out = <_Call>[];
  var i = 0;
  while (i < raw.length) {
    if (st.inBlock) {
      final e = raw.indexOf('*/', i);
      if (e < 0) return out; // 整行还在块注释里
      st.inBlock = false;
      i = e + 2;
      continue;
    }
    final t = st.triple;
    if (t != null) {
      final e = raw.indexOf(t, i);
      if (e < 0) return out; // 整行还在多行字符串里
      st.triple = null;
      i = e + t.length;
      continue;
    }
    final c = raw[i];
    if (c == '/' && i + 1 < raw.length && raw[i + 1] == '/') {
      return out; // 行注释：本行到此为止
    }
    if (c == '/' && i + 1 < raw.length && raw[i + 1] == '*') {
      st.inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final lit = _readLiteral(raw, i);
      if (!lit.closed) {
        st.triple = lit.closer; // 未闭合 ⇒ 后面几行都算这个字符串
        return out;
      }
      i = lit.end;
      continue;
    }
    if (_isIdentStart(c)) {
      final j = _identEnd(raw, i);
      final word = raw.substring(i, j);
      var k = j;
      while (k < raw.length && _isSpace(raw[k])) {
        k++;
      }
      if (k < raw.length && raw[k] == '(' && kPathCtors.contains(word)) {
        final close = _matchParen(raw, k);
        if (close < 0) {
          out.add(_Call(word, raw.substring(k + 1), false)); // 跨行实参
          return out;
        }
        out.add(_Call(word, raw.substring(k + 1, close), true));
        i = close + 1;
        continue;
      }
      i = j;
      continue;
    }
    i++;
  }
  return out;
}

/// 这条实参字面量算违规吗（判据的全部内容）
bool _isViolation(String args, _Lit lit) {
  final rv = _runtimeValue(lit);
  if (!rv.contains(r'\')) return false; // 运行时没有反斜杠 ⇒ 与路径分隔符无关
  // 「引用分隔符这个字符本身」（整个实参就是这个字面量）⇒ 不算拼路径
  if (_allBackslashes(rv) && _isStandaloneArg(args, lit)) return false;
  return true;
}

/// 扫描器统计（跨行实参计数，用于自证漏报边界）
class ScanStats {
  int multilineSkips = 0;
}

/// 扫一段**源码文本**（对文件与内联样例用的是同一套判据）
List<Violation> scanSource(String label, List<String> lines, ScanStats stats) {
  final out = <Violation>[];
  final st = _ScanState();
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    for (final call in _callsOnLine(raw, st)) {
      if (!call.argsClosed) {
        stats.multilineSkips++;
        continue; // 已知漏报边界 ①（见文件头）
      }
      for (final lit in _literalsIn(call.args)) {
        if (!_isViolation(call.args, lit)) continue;
        out.add(Violation(
          i + 1,
          raw.trim(),
          call.ctor + '(...) 的实参字面量运行时含反斜杠 ⇒ ' +
              _show(_runtimeValue(lit)),
        ));
      }
    }
  }
  return out;
}

/// 把运行时值显示成人能读的样子（反斜杠可见、控制字符转义）
String _show(String s) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    final u = c.codeUnitAt(0);
    if (c == r'\') {
      sb.write(r'\\');
    } else if (u < 0x20) {
      sb.write('<U+' + u.toRadixString(16).padLeft(4, '0') + '>');
    } else {
      sb.write(c);
    }
  }
  return sb.toString();
}

/// 相对 test/ 的路径（子目录用 / 分隔），用于与冻结名单 / 豁免表对齐
String _relOf(String path) {
  var p = path.replaceAll(r'\', '/');
  const marker = 'test/';
  if (p.startsWith(marker)) return p.substring(marker.length);
  final i = p.lastIndexOf('/' + marker);
  if (i >= 0) return p.substring(i + 1 + marker.length);
  return p;
}

// ───────────────────────── 对照样例（第 ⑥ 步用）─────────────────────────

/// ★ 阳性对照：这些**都**是本缺陷的真实拼法 ⇒ 必须全部报（5 条）
const String kPositiveControlSource = r'''
// 阳性对照（注释行，不该报）
final a = File('a\\b.png');
final b = Directory('$root\\sub');
final c = File(dir + '\\' + 'x.png');
final d = File(r'a\b.png');
final e = Link('out\\link');
''';

/// ★ 阴性对照：这些都不是本缺陷 ⇒ 一个都不许报
const String kNegativeControlSource = r'''
// 阴性对照：用 pathSeparator / p.join 拼路径（字面量里没有反斜杠）
final a = File(p.join('a', 'b.png'));
final b = File('$dir/{name}.png');
final c = Directory(<String>['out', 'sub'].join(Platform.pathSeparator));
final d = File('a\b.png');
final e = File(x.replaceAll(r'\', '/'));
final f = File(path);
// 注释里的样本：File('build\probe-shots\x.png') 不算
''';

void main() {
  test('XPLAT：test/ 下 File/Directory 的实参不许含字面反斜杠', () {
    final stats = ScanStats();

    // ── ① 动态发现：递归列举 test/ 下全部 *.dart，不写死清单 ────────
    final dir = Directory('test');
    expect(dir.existsSync(), isTrue, reason: '★ 必须在仓库根跑（test/ 目录找不到）');
    final discovered = <String>[];
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File) continue;
      final rel = _relOf(e.path);
      if (!rel.endsWith('.dart')) continue;
      if (rel == kSelfRelativePath) continue; // 排除自己（见文件头）
      discovered.add(rel);
    }
    discovered.sort();
    debugPrint('XPLAT 动态发现 ' + discovered.length.toString() + ' 个 dart 文件');
    expect(discovered.length, greaterThan(kMinScannedFiles),
        reason: '★ 只扫到 ' +
            discovered.length.toString() +
            ' 个 ⇒ 扫描器空跑（发现口径退化 / 目录找错）⇒ 这种绿是假的。');

    // ── ② 冻结金丝雀：发现口径退化 ⇒ 带文件名字红 ──────────────────
    final missing =
        kMustBeCovered.where((n) => !discovered.contains(n)).toList();
    debugPrint('XPLAT 必须覆盖 ' +
        kMustBeCovered.length.toString() +
        ' 个（命中 ' +
        (kMustBeCovered.length - missing.length).toString() +
        ' 个）');
    expect(missing, isEmpty,
        reason: '★★★ 动态发现口径退化：这些**必须被覆盖**的文件没被发现 → ' +
            missing.join(', ') +
            '。别改小 kMustBeCovered —— 它是发现口径的金丝雀。');

    // ── ③ 子目录必须被递归覆盖（test/support 等）──────────────────
    expect(discovered.any((n) => n.contains('/')), isTrue,
        reason: '★ 一个子目录文件都没扫到 ⇒ listSync(recursive:) 失效，'
            'test/support 下的缺陷会整块漏掉。');

    // ── ④ 逐文件扫描（每个文件只读一次）────────────────────────────
    final hitsByFile = <String, List<Violation>>{};
    for (final rel in discovered) {
      hitsByFile[rel] =
          scanSource(rel, File('test/' + rel).readAsLinesSync(), stats);
    }

    // ── ⑤ 豁免必须**真的挂着**（防止静默跳过 / 过期豁免）──────────
    final waivedKeys = <String>{
      for (final w in kWaivers) w.relativePath + ':' + w.line.toString(),
    };
    final staleWaivers = <String>[];
    for (final w in kWaivers) {
      if (!discovered.contains(w.relativePath)) {
        staleWaivers.add(w.relativePath + '（不在发现集里）');
        continue;
      }
      final hits = hitsByFile[w.relativePath]!;
      if (!hits.any((h) => h.line == w.line)) {
        staleWaivers.add(w.relativePath +
            ':' +
            w.line.toString() +
            '（该行已无命中 ⇒ 豁免该删掉，否则就是静默跳过）');
      }
    }
    expect(staleWaivers, isEmpty,
        reason: '★★ 豁免名单不实：' + staleWaivers.join(' / '));

    // ── ⑥ 阳性 / 阴性对照：同一套判据跑内联样例文本 ────────────────
    //   ★ 这一步先跑：判据本身失灵（恒空或恒红）时要立刻带证据红，
    //     而不是让「违规 0 处」的绿把判据失灵盖住。
    final posStats = ScanStats();
    final pos = scanSource('<inline:positive>',
        kPositiveControlSource.trim().split('\n'), posStats);
    debugPrint('XPLAT 阳性对照：命中 ' +
        pos.length.toString() +
        ' 处 → 行 ' +
        pos.map((v) => v.line.toString()).join(','));
    expect(pos.length, 5,
        reason: '★★★ 阳性对照没全中 ⇒ 判据是恒空的假门禁。'
            '样例里的 5 种缺陷拼法（双反斜杠 / 插值 / 加号拼接 / raw / Link）'
            '必须全部被判违规。');
    expect(pos.map((v) => v.line).toList(), <int>[2, 3, 4, 5, 6],
        reason: '★ 阳性对照命中的**行号**不对 ⇒ 判据定位错了。');
    for (final v in pos) {
      debugPrint('XPLAT 阳性对照命中 → :' +
          v.line.toString() +
          ' ' +
          v.source +
          '  [' +
          v.detail +
          ']');
    }

    final negStats = ScanStats();
    final neg = scanSource('<inline:negative>',
        kNegativeControlSource.trim().split('\n'), negStats);
    debugPrint('XPLAT 阴性对照：命中 ' + neg.length.toString() + ' 处');
    expect(neg, isEmpty,
        reason: '★★★ 阴性对照被误报 ⇒ 判据太宽（会把 Platform.pathSeparator / '
            'p.join / 转义序列 / 注释样本 全判成违规）⇒ 门禁会变成噪音被废弃。'
            '误报：' + neg.map((v) => v.line.toString() + ' ' + v.source).join(' | '));

    // ── ⑦ 主判定：违规列表必须空，失败时打印「文件:行号 + 原文」────
    final bad = <String>[];
    var waivedHits = 0;
    for (final rel in discovered) {
      for (final v in hitsByFile[rel]!) {
        final key = rel + ':' + v.line.toString();
        if (waivedKeys.contains(key)) {
          waivedHits++;
          debugPrint('XPLAT 豁免（理由见 kWaivers）→ test/' + key);
          continue;
        }
        bad.add('test/' + key + ': ' + v.source + '   [' + v.detail + ']');
      }
    }
    for (final b in bad) {
      debugPrint('XPLAT 违规 → ' + b);
    }
    debugPrint('XPLAT 扫了 ' +
        discovered.length.toString() +
        ' 个 dart 文件，违规 ' +
        bad.length.toString() +
        ' 处，豁免 ' +
        waivedHits.toString() +
        ' 处（豁免条目 ' +
        kWaivers.length.toString() +
        ' 条），跨行实参未判定 ' +
        stats.multilineSkips.toString() +
        ' 处');
    expect(bad, isEmpty,
        reason: '★★★ 这些反斜杠在 POSIX 上只是普通文件名字符、不是分隔符 ⇒ '
            'macOS CI 上要么红、要么（更糟）静默写到错位置还留垃圾。'
            '请用 Platform.pathSeparator（或 p.join）拼路径。命中：\n' + bad.join('\n'));
  });
}
