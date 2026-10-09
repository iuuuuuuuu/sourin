// ======================================================================
//  应用日志（内存环形缓冲 + 按天落盘 + 导出/复制）
// ======================================================================
//
// 用户 2026-10-04 要求（逐字，m13330 截图第 ⑤ 项）：
// > 这些功能也可以抄一下
// 第 ⑤ 项 = 「分享日志」。
//
// # ★ 为什么「分享」要落成「保存到文件 + 复制到剪贴板」
//
// pubspec.yaml 里**没有** share_plus（已核对 pubspec.lock：ABSENT），
// 而 pubspec.yaml 不在本次写范围内 ⇒ 不能新增依赖。
// file_selector 是**已有**依赖（pubspec.yaml:166，且
// lib/ui/widgets/backup_panel.dart:239-262 已经用它做过「另存为」），
// Clipboard 也是 Flutter 自带（先例 lib/shell.dart:5278、
// lib/ui/settings_page.dart:1533）。
// ⇒ 两条路都通：① 另存为 .log 文件 ② 复制全文到剪贴板。
//   两条路在 lib/ui/settings/playback_page.dart 的「日志」区块里各有按钮。
//
// # 日志写在哪
//
// <dataDir>/logs/sourin-YYYY-MM-DD.log
// ★ dataDir 的解析次序与 lib/shell.dart:792 一致（见 ClipDownloader.dataDir
//   的注释；本文件**复用**它，避免两处各写一份而漂移）。
//
// # ★ 这个文件是新建的（产品里原本没有任何日志基础设施）
//
// 落地前 grep：lib/ 里 logFile / logPath 零命中；写文件的只有
// lib/core/ui_prefs.dart:120（ui-prefs.json）。运行期诊断信息全走
// debugPrint —— 用户报问题时**拿不到任何东西**。
//
// # 为什么内存里也留一份（环形缓冲）
//
// 用户点「分享日志」时，磁盘上可能只有一个空文件（刚装、刚清）——
// 那样导出的日志毫无价值。环形缓冲保证：**本次会话启动后**的所有
// 记录都在，即使还没到落盘时机（或落盘失败）也能导出。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'clip_download.dart';

/// 一条日志。
class LogLine {
  LogLine(this.tag, this.message) : at = DateTime.now();

  final DateTime at;
  final String tag;
  final String message;

  /// 形如  2026-10-04 12:34:56.789 [DL] 完成 a.mp4
  String get text {
    final t = at;
    String p2(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${t.year}-${p2(t.month)}-${p2(t.day)} '
        '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}.'
        '${p2(t.millisecond, 3)} [$tag] $message';
  }

  @override
  String toString() => text;
}

/// 应用日志。全部静态方法（进程级单例）。
class AppLog {
  AppLog._();

  /// 内存里保留的最大条数。★ 2000 是**拍出来的**：按一行 120 字节算
  /// ≈ 240 KB 常驻，对一个播放器可忽略；再多就没有导出价值了。
  static const int maxLines = 2000;

  static final List<LogLine> _lines = [];

  /// 单次会话里最多落盘多少行（防止长时间挂机把磁盘写满）
  static const int maxFileLines = 20000;

  static int _fileLines = 0;
  static File? _file;
  static Future<void>? _pending;
  static bool _enabled = true;

  /// 探针/测试用：暂停落盘（只看内存）
  @visibleForTesting
  static void debugSetEnabled(bool v) => _enabled = v;

  /// 探针/测试用：清空内存缓冲
  @visibleForTesting
  static void debugClear() {
    _lines.clear();
    _file = null;
    _fileLines = 0;
    // ★ 缓冲/定时器也必须一起清 —— 否则上一条用例攒的行会漏到下一条去
    _flushTimer?.cancel();
    _flushTimer = null;
    _buf.clear();
    _bufLines = 0;
    _bufOldest = null;
  }

  /// 内存里的全部日志（按时间正序）
  static List<LogLine> get lines => List.unmodifiable(_lines);

  static int get lineCount => _lines.length;

  // ======================================================================
  //  脱敏
  // ======================================================================

  /// 敏感键名（后面紧跟 = 或 : 的值一律换成 <已脱敏>）
  ///
  /// 覆盖：token / access_token / refresh_token / api_key / apikey /
  /// secret / password / passwd / pwd / authorization / auth /
  /// signature / sign / set-cookie / cookie。
  static final RegExp _kvSecret = RegExp(
    r'(token|access[_-]?token|refresh[_-]?token|api[_-]?key|apikey|secret'
    r'|password|passwd|pwd|authorization|auth|signature|sign'
    r'|set-cookie|cookie)'
    r'(\s*[=:]\s*)([^\s&,;]+)',
    caseSensitive: false,
  );

  /// Bearer xxx / Basic xxx / Token xxx
  static final RegExp _bearerToken = RegExp(
    r'\b(Bearer|Basic|Token)\s+[A-Za-z0-9\-._~+/=]{6,}',
    caseSensitive: false,
  );

  /// 脱敏命中次数（测试/探针用：证明脱敏**真的发生过**，不是写了没生效）
  static int redactedCount = 0;

  /// 把一行文本里的敏感值换成 <已脱敏>。
  ///
  /// ★ 硬约束：日志**不得**写入 token / 订阅链接 / cookie。
  ///   这里做的是「进内存缓冲之前」的过滤，所以磁盘上的日志文件
  ///   与剪贴板导出**都不含原文**（导出走的就是同一个 _lines）。
  static String redact(String s) {
    var n = 0;
    var out = s.replaceAllMapped(_kvSecret, (m) {
      n++;
      return '${m[1]}${m[2]}<已脱敏>';
    });
    out = out.replaceAllMapped(_bearerToken, (m) {
      n++;
      return '${m[1]} <已脱敏>';
    });
    if (n > 0) redactedCount += n;
    return out;
  }

  /// 记录一条。
  ///
  /// ⚠️ **绝不要**在这里 await 或抛异常 —— 它是从下载器、设置页、
  ///    播放器各处调用的旁路设施，任何异常都不能影响主流程。
  ///
  /// ★ 入口处统一 [redact]：任何调用方都不可能把敏感值写进日志。
  static void write(String tag, String message) {
    final line = LogLine(tag, redact(message));
    _lines.add(line);
    while (_lines.length > maxLines) {
      _lines.removeAt(0);
    }
    /*
     * ★ 2026-10-04 订正（Lead 审计 team-message-914508ce，【中】第 1 条）：
     *   这里**原先**写的是 `debugPrint('[$tag] $message')` —— 用的是**未脱敏**的原始 message。
     *
     * 为什么这是真问题（Lead 查过框架源码，不是猜的）：
     * ```text
     * flutter/lib/src/foundation/print.dart:50
     *   DebugPrintCallback debugPrint = debugPrintThrottled;
     * print.dart:73  debugPrintThrottled(...) → 内部走 print → stdout → logcat
     * print.dart:37  文档原话：「The debugPrint function logs to console
     *                even in [release mode]」
     * ```
     * ⇒ 含 token / 订阅链接 / cookie 的原文会进 logcat（release 也进），
     *   与文件头那条硬约束「日志**不得**写入 token / 订阅链接 / cookie」直接矛盾。
     *   日志的**唯一**出口必须是脱敏后的 `line.text`。
     */
    debugPrint('[$tag] ${line.text}');
    if (!_enabled) return;
    // 落盘失败只吞掉，不影响调用方
    unawaited(_append(line).catchError((Object _) {}));
  }

  /// 日志目录：<dataDir>/logs
  static Future<String> logDir() async {
    final d = Directory(
        '${await ClipDownloader.dataDir()}${Platform.pathSeparator}logs');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  static String _stamp(DateTime t) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p2(t.month)}-${p2(t.day)}';
  }

  /// 今天的日志文件路径（不保证已存在）
  static Future<File> todayFile() async {
    final dir = await logDir();
    return File('$dir${Platform.pathSeparator}'
        'sourin-${_stamp(DateTime.now())}.log');
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 落盘合并（Owner「很多地方我感觉都卡卡的」）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 改前的形态与它的代价
  //
  // `AppLog.write` 有 **90 处**调用点，而每一条都走
  // `await f.writeAsString(..., mode: append)` —— 也就是**一行一次系统调用**。
  // 高频路径（弹幕、探测、进度、下载队列）一秒能打十几行，于是：
  //
  // ```text
  // 每行 → 一个 File.open + write + close 往返（Windows 上还要过一层
  //        安全描述符与缓冲失效）
  // ⇒ 每次几百微秒的**同步开销全部记在 UI isolate 的微任务队列上**
  //    （await f.writeAsString 之后的续体是要回到 UI isolate 跑的）
  // ```
  //
  // # 为什么合并成 1 秒一批是安全的
  //
  // ```text
  // ① 日志是**旁路**：唯一出口是「用户导出/复制」，没有任何功能读它
  // ② 内存环形缓冲（[_lines]）**一条不少** —— 导出走的就是它
  //    ⇒ 合并不影响"分享日志"看到的内容
  // ③ 换日/被删时立即 flush（见 [_append] 里的日期守卫）
  // ④ 崩溃最多丢最后 1 秒的**磁盘**副本，内存副本仍在
  // ```
  static const Duration _flushInterval = Duration(seconds: 1);

  /// 攒着还没落盘的行（跨 [_flushInterval] 合并成一次写）
  static final StringBuffer _buf = StringBuffer();

  /// 当前批次里最老那行的时间 —— 用来判断"这行还是不是今天的"
  static DateTime? _bufOldest;

  /// 排好的落盘定时器（同一时刻只有一个）
  static Timer? _flushTimer;

  /// 合并窗口内的**兜底条数** —— 极端高频时不让缓冲无限涨
  ///
  /// 1 秒 10 行时它根本不会触发（缓冲只有几百字节）；
  /// 它挡的是"日志风暴"（每行几 KB）那种情况。
  static const int _bufMaxLines = 400;

  static int _bufLines = 0;

  /// 把一行并进缓冲（**不**自己写文件）
  static Future<void> _append(LogLine line) async {
    // ★ 超过单次会话上限 ⇒ 直接丢弃（磁盘防爆，与合并逻辑无关）
    if (_fileLines >= maxFileLines) return;
    final f = _file ??= await todayFile();

    // ★ 换日（或文件被删/换了）⇒ 先把上一批落盘，绝不跨文件混写
    final stamp = _stamp(line.at);
    if (_bufOldest != null && _stamp(_bufOldest!) != stamp) {
      await _flushBuffer(f);
    }
    _bufOldest ??= line.at;

    _buf.write(line.text);
    _buf.write(Platform.lineTerminator);
    _bufLines++;

    // ★ 条数到了上限 ⇒ 立即落盘，不等窗口
    if (_bufLines >= _bufMaxLines) {
      await _flushBuffer(f);
      return;
    }
    _flushTimer ??= Timer(_flushInterval, () {
      _flushTimer = null;
      unawaited(_flushBuffer(f).catchError((Object _) {}));
    });
  }

  /// 把攒下的行一次写出去，并串行化（多次并发会交错）
  static Future<void> _flushBuffer(File f) async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_bufLines == 0) return;
    _bufOldest = null;

    final text = _buf.toString();
    _buf.clear();
    final n = _bufLines;
    _bufLines = 0;

    // 串行：并发 append 会交错成半行
    final prev = _pending;
    final next = () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      try {
        await f.writeAsString(text, mode: FileMode.append, flush: false);
        _fileLines += n;
      } catch (_) {}
    }();
    _pending = next;
    await next;
  }

  /// 立刻把缓冲落盘（退出前 / 测试收尾用）
  @visibleForTesting
  static Future<void> debugFlush() async {
    final f = _file;
    if (f == null) {
      // 从没落过盘 ⇒ 缓冲里不该有东西；保险起见清掉定时器
      _flushTimer?.cancel();
      _flushTimer = null;
      return;
    }
    await _flushBuffer(f);
  }

  /// 把内存里的全部日志拼成一段文本（导出/剪贴板用）。
  static String exportText({String? header}) {
    final b = StringBuffer();
    b.writeln(
        header ?? 'Sourin 播放器日志导出  ${DateTime.now().toIso8601String()}');
    b.writeln('内存条数：${_lines.length} / 上限 $maxLines');
    b.writeln('-' * 72);
    for (final l in _lines) {
      b.writeln(l.text);
    }
    return b.toString();
  }

  /// ★ ⑤ 的**真实生效路径**之一：把日志写成一个 .log 文件。
  ///
  /// [intoPath] 非空时写到指定路径（「另存为」用）；为空时写到
  /// <dataDir>/logs/ 下的导出文件。返回落盘后的文件。
  static Future<File> exportToFile({String? intoPath}) async {
    final text = exportText();
    final f = intoPath != null
        ? File(intoPath)
        : File('${await logDir()}${Platform.pathSeparator}'
            'sourin-export-${DateTime.now().millisecondsSinceEpoch}.log');
    await f.writeAsString(text, flush: true);
    return f;
  }

  /// 已存在的日志文件（按路径倒序），「另存为」对话框的默认名用
  static Future<List<File>> existingFiles() async {
    final d = Directory(await logDir());
    if (!await d.exists()) return const [];
    final list = <File>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is File && e.path.endsWith('.log')) list.add(e);
    }
    list.sort((a, b) => b.path.compareTo(a.path));
    return list;
  }
}
