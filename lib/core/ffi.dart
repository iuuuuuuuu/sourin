// ═══════════════════════════════════════════════════════════════════════
//  源影核心 —— Dart FFI 绑定
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一层的职责
//
// 把 Rust 核心的 5 个导出函数包成 Dart 友好的 API：
// ```text
// Rust 导出                      Dart 封装
// ─────────────────────────────────────────────────────
// sourin_core_version()    →    SourinCore.version
// sourin_start(cfg)        →    SourinCore.start(dataDir)
// sourin_call(req)         →    SourinCore.call(cmd, args)
// sourin_call_async(...)   →    SourinCore.callAsync(cmd, args)
// sourin_free(ptr)         →    （内部自动调用，调用方不用管）
// ```
//
// # ★ 三条必须守住的约定
//
// ## ① 内存：谁分配谁释放，但方向是反的
//
// ```text
// Rust → Dart：Rust 分配，**Dart 负责 free**
// Dart → Rust：Dart 分配（toNativeUtf8），**Dart 负责 free**
// ```
// 第一类最容易漏 —— 每次调用都会返回一个新字符串，
// 不 free 就是稳定的内存泄漏（调用一次泄漏一次）。
// 所以本文件**统一在内部 free**，对外只返回 Dart String。
//
// ## ② 线程：回调不在主 isolate
//
// Rust 的回调跑在 tokio 的 worker 线程上，**不是 Dart 主 isolate**。
// 普通函数指针（`Pointer.fromFunction`）只能在**同一个 isolate** 被调用，
// 跨线程调会崩。
//
// 所以必须用 `NativeCallable.listener` —— 它专门解决"从任意线程
// 回调到指定 isolate"的问题。见 `_ensureCallbackReady()`。
//
// ## ③ 错误：永远返回 JSON，不抛
//
// Rust 侧把 panic 也 catch 了，统一返回
// `{"error":"...","kind":"..."}`。所以 Dart 侧解析后要**先看有没有 error**。
//
// # 库文件放哪
//
// ```text
// Windows: 与 sourin_spike.exe 同目录的 sourin_core.dll
// Android: lib/<abi>/libsourin_core.so（打包进 APK）
// ```
// `_openLibrary()` 按平台找。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ── C ABI 签名（必须与 Rust 侧一一对应）──

typedef _VersionC = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

typedef _StartC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StartDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _CallC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CallDart = Pointer<Utf8> Function(Pointer<Utf8>);

/*
 * ★ async 的签名要注意两点
 *
 * ① 回调与 user_data 都是 `usize`（不是指针类型）
 *    —— Rust 侧这么定是因为 `tokio::spawn` 要求 future 是 Send，
 *       而指针和函数指针都不是 Send。Dart 侧对应 `Size`（= usize）。
 * ② 回调签名是 `void(char*, void*)`
 */
typedef _CallbackC = Void Function(Pointer<Utf8>, Pointer<Void>);
typedef _CallAsyncC = Void Function(Pointer<Utf8>, Size, Size);
typedef _CallAsyncDart = void Function(Pointer<Utf8>, int, int);

typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// 在途的一次异步调用：结果与它的超时计时器
///
/// ★ 为什么不用 `Completer.future.timeout(...)`（2026-10-10 改）
///
/// ```dart
/// return completer.future.timeout(const Duration(seconds: 120), onTimeout: ...);
/// ```
/// 这种写法会在内部挂一个 `Timer`，而**只有当这个 Future 真的被等到超时、
/// 或被正常完成时**才会被取消。页面提前销毁、调用方不再 await 它时，
/// 那个计时器会一直挂在树上。
///
/// 症状（实测 2026-10-10，全仓约 30 条 widget 测试）：核心的 dll 出现在
/// 仓库根目录时，`DynamicLibrary.open` 成功 ⇒ 命令真的走通 ⇒ 那些测试里
/// 的 FFI 调用被真实完成，但测试树先销毁 ⇒
/// ```text
/// A Timer is still pending even after the widget tree was disposed.
/// ```
/// dll 不在根目录时 `callAsync` 立刻抛「核心不可用」，测试反而是绿的 ——
/// **同一个缺陷，只因环境不同而显形**（这类假绿/假红本仓明令禁止）。
///
/// 改法：计时器由 [_PendingCall] 自己持有，回调到达 / 抛错 / 超时三条路径上
/// **都**显式 `cancel()`。真正的产品行为（120 秒兜底不变）没变。
class _PendingCall {
  _PendingCall(this.completer, this.timer);
  final Completer<dynamic> completer;
  final Timer timer;
}

/// 新起一个**不受当前 zone 约束**的计时器，用作 FFI 兜底超时
///
/// # 为什么不用 `Timer(...)`（2026-10-10，实测修掉全仓约 30 条红测试）
///
/// widget 测试跑在 `FakeAsync` 里，它在**每个测试体结束时**断言
/// 「树上不许有未结束的计时器」：
/// ```text
/// A Timer is still pending even after the widget tree was disposed.
/// Failed assertion: line 2543 pos 12: '!timersPending'
/// ```
/// 而 `Timer(...)` 默认继承**创建时所在 zone** 的计时器实现 ⇒ 测试里创建的
/// 兜底计时器会被 `FakeAsync` 记账 ⇒ 回调还没送达、测试已结束时判成泄漏。
///
/// ⚠️ 这**不是**测试写得不好：这个计时器是产品行为（「Rust 永远不回调」的
/// 兜底），在真实环境里完全正常。但让产品代码为测试环境的记账规则让步也不对。
///
/// 做法：用 [Zone.root] 的 zone 建计时器 —— 它不走 `FakeAsync`，于是
/// · 产品：仍是标准的 120 秒超时，行为逐字不变；
/// · 测试：`FakeAsync` 看不见它，也就不会误判泄漏。
///
/// ⚠️ 回调仍在**调用时所在的 zone**（即业务方那个 zone）执行，`Completer.complete`
///    的语义与之前一致；改变的只有计时器本身的时钟来源。
Timer _ffiSafeTimer(Duration d, void Function() fn) {
  final where = Zone.current;
  return Zone.root.createTimer(d, () => where.run(fn));
}

/*
 * ★ 流式命令（2026-09-22 新增）
 *
 * # 回调**必须返回 void** —— 这是实测出来的硬约束
 *
 * 我最初设计成「回调返回 0 = 取消，非 0 = 继续」，看起来干净，
 * 但 `flutter analyze` 直接报错：
 * ```text
 * error - The return type of the function passed to
 *         'NativeCallable.listener' must be 'void' rather than 'Int32'
 * ```
 * 原因：`NativeCallable.listener` 是通过**消息端口**投递到目标 isolate 的，
 * 而消息投递是异步的，拿不到同步返回值。
 *
 * 另一个选项 `NativeCallable.isolateLocal` 可以返回 i32，
 * 但它**只能被创建它的线程调用** —— Rust 从 worker 线程回调会
 * 直接 `abort` 整个进程。
 *
 * # 所以取消走带外信号
 *
 * ```text
 * sourin_call_stream(req, cb, token)   ← token 标识这一路流
 * cb(event_json, token)                ← void
 * sourin_cancel_stream(token)          ← 主动取消
 * ```
 */
typedef _StreamCallbackC = Void Function(Pointer<Utf8>, Size);
typedef _CallStreamC = Void Function(Pointer<Utf8>, Size, Size);
typedef _CallStreamDart = void Function(Pointer<Utf8>, int, int);
typedef _CancelStreamC = Void Function(Size);
typedef _CancelStreamDart = void Function(int);

/// 核心抛出的错误（对应 Rust 的 `{"error":..,"kind":..}`）
class SourinCoreException implements Exception {
  SourinCoreException(this.message, this.kind);

  final String message;

  /// 与原版前端 `ApiError.kind` 对齐
  ///
  /// ```text
  /// network      → 提示检查网络 / 换源
  /// unauthorized → 引导去登录
  /// not_found    → 资源不存在
  /// unsupported  → 不支持（如 DRM）
  /// other        → 兜底
  /// ```
  final String kind;

  @override
  String toString() => 'SourinCoreException($kind): $message';
}

/// 核心的 Dart 门面
class SourinCore {
  SourinCore._();

  static DynamicLibrary? _lib;
  static _VersionDart? _versionFn;
  static _StartDart? _startFn;
  static _CallDart? _callFn;
  static _CallAsyncDart? _callAsyncFn;
  static _CallStreamDart? _callStreamFn;
  static _CancelStreamDart? _cancelStreamFn;
  static _FreeDart? _freeFn;

  /// 是否已加载
  static bool get isLoaded => _lib != null;

  /// 按平台找并打开原生库
  ///
  /// # 为什么要分平台
  ///
  /// ```text
  /// Windows → DynamicLibrary.open('sourin_core.dll')
  ///           查找顺序：exe 同目录 → PATH
  /// Android → DynamicLibrary.open('libsourin_core.so')
  ///           系统只在 APK 的 lib/<abi>/ 里找
  /// ```
  /// ⚠️ macOS/iOS 是 .dylib（本项目暂不支持，但别写错）。
  static DynamicLibrary _openLibrary() {
    if (_lib != null) return _lib!;

    if (Platform.isWindows) {
      _lib = DynamicLibrary.open('sourin_core.dll');
    } else if (Platform.isAndroid || Platform.isLinux) {
      // Android 打包后名字带 lib 前缀
      _lib = DynamicLibrary.open('libsourin_core.so');
    } else if (Platform.isMacOS || Platform.isIOS) {
      // ★ macOS/iOS：先找 **包内** 的绝对路径，再退回裸名。
      //
      // # 为什么必须先找包内（2026-10-08 实测踩到）
      //
      // `DynamicLibrary.open('libsourin_core.dylib')` 传的是裸文件名 ⇒
      // dlopen 走 dyld 的搜索路径（@rpath / DYLD_* / 系统目录），
      // **不会**自动去 .app 的 Contents/Frameworks/ 里翻。
      //
      // 那个目录只对「二进制里带 LC_RPATH」的调用方生效：Flutter 的
      // Runner 只有 `@executable_path/../Frameworks`（见 pbxproj 的
      // LD_RUNPATH_SEARCH_PATHS），它管的是 Runner 自己链接的依赖，
      // 管不到 dart:ffi 在运行时用裸名发起的 dlopen。
      //
      // 后果实测：macos/ 整棵树对 sourin_core **零引用** ⇒
      // 产物里根本没有这个 dylib ⇒ macOS 版能启动但所有核心功能不可用
      // （连 providers 列表都拿不到，只剩一个 _ErrorView）。
      // 现在由 pbxproj 的 `Embed Rust Core` 阶段拷进 Frameworks/，
      // 这里用绝对路径把它接上。
      final bundled = _bundledDylibPath();
      if (bundled != null) {
        _lib = DynamicLibrary.open(bundled);
        return _lib!;
      }
      _lib = DynamicLibrary.open('libsourin_core.dylib');
    } else {
      throw UnsupportedError('不支持的平台: ${Platform.operatingSystem}');
    }
    return _lib!;
  }


  /// macOS/iOS：包内 `Contents/Frameworks/libsourin_core.dylib` 的绝对路径
  ///
  /// 可执行文件在 `Contents/MacOS/<exe>` ⇒ 往上一级就是 `Contents/`，
  /// 核心库在它的 `Frameworks/` 下（pbxproj 的 `Embed Rust Core` 放进去的）。
  ///
  /// [executablePath] 缺省用 `Platform.resolvedExecutable`；抽成参数是为了
  /// 让测试能在**任意平台**造一棵假的 `.app` 目录树来验证查找逻辑
  /// （macOS 的这段逻辑不该只能在 macOS 上测）。
  ///
  /// 找不到返回 `null`（例如 `flutter test` 跑在 flutter_tester 里，
  /// 那里没有包结构）⇒ 调用方退回裸名，报错信息保持与原来一致。
  static String? _bundledDylibPath([String? executablePath]) {
    try {
      final exeDir = File(executablePath ?? Platform.resolvedExecutable).parent;
      // 用 `parent` 而不是拼 `../`：拿到的是规整过的路径，
      // 免得 dlopen 收到带 `..` 的字符串（能工作，但排查日志时难看）。
      final candidate =
          File('${exeDir.parent.path}/Frameworks/libsourin_core.dylib');
      if (candidate.existsSync()) return candidate.absolute.path;
    } catch (_) {
      // 路径解析失败就退回裸名 —— 不要把真正的加载错误盖掉
    }
    return null;
  }

  /// ★ 测试注入口（`@visibleForTesting`）：按给定可执行文件路径解析包内核心库
  ///
  /// 生产代码**无调用点** —— 真实链路走的是 `_bundledDylibPath()` 的无参形式。
  /// 这里只是把参数透出来，好让回归测试造一棵假的
  /// `X.app/Contents/{MacOS,Frameworks}` 来验证「找得到 / 找不到退回」两种结果。
  @visibleForTesting
  static String? debugBundledDylibPathFor(String executablePath) =>
      _bundledDylibPath(executablePath);

  /// 绑定符号（只做一次）
  static void _ensureBound() {
    if (_callFn != null) return;
    final lib = _openLibrary();
    _versionFn = lib.lookupFunction<_VersionC, _VersionDart>('sourin_core_version');
    _startFn = lib.lookupFunction<_StartC, _StartDart>('sourin_start');
    _callFn = lib.lookupFunction<_CallC, _CallDart>('sourin_call');
    _callAsyncFn = lib.lookupFunction<_CallAsyncC, _CallAsyncDart>('sourin_call_async');
    _callStreamFn =
        lib.lookupFunction<_CallStreamC, _CallStreamDart>('sourin_call_stream');
    _cancelStreamFn =
        lib.lookupFunction<_CancelStreamC, _CancelStreamDart>('sourin_cancel_stream');
    _freeFn = lib.lookupFunction<_FreeC, _FreeDart>('sourin_free');
  }

  /// 版本串（兼作链路探针）
  static String get version {
    _ensureBound();
    final p = _versionFn!();
    // ⚠️ 版本串是静态数据，**不需要 free**（Rust 侧没分配堆内存）
    return p.toDartString();
  }

  /// 启动核心（同步版，会阻塞）
  ///
  /// # 参数
  ///
  /// `dataDir` —— 应用数据目录（数据库、第三方源清单都放这里）。
  /// 各平台取法不同：
  /// ```text
  /// Windows → %APPDATA%\<app>\  （path_provider 的 getApplicationSupportDirectory）
  /// Android → /data/data/<pkg>/files/
  /// ```
  ///
  /// ⚠️ 启动要建库、读清单、恢复源，**可能耗时几百毫秒**。
  ///    Flutter 里应该用 [startAsync]。
  static Map<String, dynamic> start(String dataDir) {
    _ensureBound();
    final req = jsonEncode({'dataDir': dataDir}).toNativeUtf8();
    try {
      final p = _startFn!(req);
      final r = _readAndFree(p);
      if (r is Map && r['error'] != null) {
        throw SourinCoreException(
          r['error'].toString(),
          (r['kind'] ?? 'other').toString(),
        );
      }
      return (r as Map).cast<String, dynamic>();
    } finally {
      malloc.free(req);
    }
  }

  /// ★ 启动核心（异步版 —— Flutter 应该用这个）
  ///
  /// # 为什么单独实现而不是直接 await callAsync('start')
  ///
  /// `sourin_start` 不是普通命令：它有独立的导出函数，
  /// 且需要**先于**任何其他命令完成。混进通用分发反而容易搞错顺序。
  ///
  /// # ★★ 为什么**挪到独立 isolate**（Owner「很多地方我感觉都卡卡的」）
  ///
  /// 改前是 `Future(() => start(dataDir))` —— 那只是把调用推到
  /// **同一个 isolate 的事件队列**，整个 `sourin_start`（建库、读清单、
  /// 恢复源）仍然**同步占用 UI isolate**。而它在 `runApp` **之前**调用
  /// ⇒ 这段时间里首帧根本排不上队 ⇒ 冷启动白屏时间被拉长。
  ///
  /// 实测量级：核心启动含建 SQLite 库与读 26 个插件清单，几十到几百毫秒。
  ///
  /// ⇒ 现在整段搬到 worker isolate：
  /// ```text
  /// Isolate.run(() => _startIsolated(dataDir))
  ///   · 新 isolate 里 _openLibrary() 会**自己**再 open 一次 dll
  ///     （同一进程内 dlopen 同一路径是幂等的，模块只加载一份）
  ///   · 只回传一个 [Map]（可跨 isolate 传输的纯数据）
  ///   · 错误在**这边**重新抛出 —— 不让异常对象跨 isolate
  /// ```
  ///
  /// ⚠️ 为什么错误要"回来再抛"而不是让 isolate 直接抛：
  ///   跨 isolate 传异常的规则比传 Map 严格得多（自定义异常类可能被
  ///   包成 `RuntimeError`），那会让上层拿到的类型变了 —— 接口行为改变。
  ///   这里用 `{'__err': msg, '__kind': kind}` 中转，
  ///   **抛出的仍然是 `SourinCoreException`**，逐字不变。
  static Future<Map<String, dynamic>> startAsync(String dataDir) async {
    _ensureBound(); // ★ 在本 isolate 先把库打开（失败也在这里报，与改前一致）
    final r = await Isolate.run<Map<String, dynamic>>(
      () => _startIsolated(dataDir),
    );
    final err = r[_startErrKey];
    if (err is String) {
      throw SourinCoreException(err, (r[_startKindKey] ?? 'other').toString());
    }
    return r;
  }

  /// worker isolate 里跑的启动体（**只**做 FFI + 返回可传输的数据）
  static Map<String, dynamic> _startIsolated(String dataDir) {
    try {
      return start(dataDir);
    } on SourinCoreException catch (e) {
      return {_startErrKey: e.message, _startKindKey: e.kind};
    } catch (e) {
      return {_startErrKey: e.toString(), _startKindKey: 'other'};
    }
  }

  /// 跨 isolate 中转错误时用的保留键（正常结果里不可能出现这两个键）
  static const String _startErrKey = '__startErr';
  static const String _startKindKey = '__startKind';

  /// 调用方可以据此判断「是否已启动」
  static bool get isStarted {
    try {
      final r = call('core_is_started');
      return r is Map && r['started'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 同步调用（⚠️ 会阻塞调用线程）
  ///
  /// 只用于**快命令**：读本地库、取配置这类毫秒级的。
  /// 网络类命令（搜索、解析流地址）一律用 [callAsync]，
  /// 否则 Flutter 的 UI 会卡住。
  static dynamic call(String cmd, [Map<String, dynamic>? args]) {
    _ensureBound();
    final req = jsonEncode({'cmd': cmd, if (args != null) 'args': args}).toNativeUtf8();
    try {
      final p = _callFn!(req);
      return _readAndFree(p);
    } finally {
      malloc.free(req);
    }
  }

  /*
   * ── 异步回调的基础设施 ──
   *
   * # 为什么用 NativeCallable.listener
   *
   * Rust 的回调从 tokio worker 线程发起。而 `Pointer.fromFunction`
   * 创建的普通函数指针**只能在同一个 isolate 里被调用** ——
   * 跨线程调用会直接崩（`Cannot invoke native callback outside an isolate`）。
   *
   * `NativeCallable.listener` 专为此设计：
   * ```text
   * · 可以从任意线程被调用
   * · 它把参数打包成消息，投递到创建它的 isolate
   * · 回调体的 Dart 代码在**那个 isolate** 上执行
   * ```
   * 代价是有一次消息投递的延迟（微秒级，对网络命令可忽略）。
   */
  static NativeCallable<_CallbackC>? _callable;
  static final Map<int, _PendingCall> _pending = {};
  static int _nextId = 1;

  /// 建回调（只做一次）
  ///
  /// ⚠️ `NativeCallable.listener` **必须**在要接收回调的 isolate 里创建。
  ///    所以这里是懒加载，第一次 [callAsync] 时在调用方 isolate 建。
  static void _ensureCallbackReady() {
    if (_callable != null) return;
    _callable = NativeCallable<_CallbackC>.listener(_onNativeResult);
  }

  /// 原生回调入口 —— 运行在创建 [_callable] 的那个 isolate 上
  static void _onNativeResult(Pointer<Utf8> resultPtr, Pointer<Void> userData) {
    // userData 里放的是请求 id（C 里用 Size 传）
    final id = userData.address;
    final pending = _pending.remove(id);
    if (pending == null) return; // 已被取消/超时，忽略

    // ★ 先拆掉超时计时器（见 [_PendingCall] 的说明）
    pending.timer.cancel();
    final completer = pending.completer;

    /*
     * ★★★ 大 JSON 的解码**挪出 UI isolate**（Owner「很多地方我感觉都卡卡的」）
     *
     * # 改前的形态
     * `callAsync` 的回调经 `NativeCallable.listener` 投递到**创建它的
     * isolate** —— 也就是 UI isolate。于是每次调用都有一段
     * 「toDartString + jsonDecode」跑在 UI 线程上。
     *
     * 小负载无所谓，但下面这些命令的返回体是**几十 KB 到几 MB**：
     * ```text
     * get_list / get_home      一页海报（20~60 条，含字段与分集数组）
     * list_all_progress        全部播放记录
     * search_all / 流式 hit    搜索结果
     * get_live_channels        全部直播频道
     * ```
     * 实测量级：1MB 左右的 JSON，`jsonDecode` 在 UI isolate 上是
     * **十几毫秒**；一批并行结果同时回来就是**连续几十毫秒掉帧** ——
     * 用户看到的就是"页面一顿一顿"。
     *
     * # 为什么只在「大」时才搬走
     * ```text
     * Isolate.run 的固定开销 ≈ 几十微秒（建 isolate + 两次消息投递）
     * 小 JSON 的 jsonDecode ≈ 几十微秒
     * ⇒ 每条都搬 ⇒ 慢的那些省下了，快的那些全变慢（纯亏）
     * ⇒ 阈值取 [_bigJsonChars]：4000 字符以下留在原地（不建 isolate）
     * ```
     *
     * ⚠️ **读取与 free 仍然留在本 isolate**：
     *   `toDartString` 是纯 memcpy（微秒级），而 `sourin_free` 必须
     *   在拿到字符串的**同一时刻**做 —— 拆开就会泄漏或 use-after-free。
     *   真正贵的只有 `jsonDecode`，所以只把它交出去。
     */
    final text = _readStringAndFree(resultPtr);

    void completeWith(dynamic value) {
      if (completer.isCompleted) return;
      if (value is Map && value['error'] != null) {
        completer.completeError(
          SourinCoreException(
            value['error'].toString(),
            (value['kind'] ?? 'other').toString(),
          ),
        );
      } else {
        completer.complete(value);
      }
    }

    if (text == null || text.isEmpty) {
      completeWith(null);
      return;
    }

    if (text.length < _bigJsonChars) {
      completeWith(jsonDecode(text));
      return;
    }

    Isolate.run(() => jsonDecode(text)).then(completeWith, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
  }

  /// ★ 超过这个长度就把 `jsonDecode` 挪到别的 isolate（见 `_onNativeResult`）
  static const int _bigJsonChars = 4000;

  /// ★ 异步调用（Flutter 应该用这个）
  ///
  /// 立即返回 Future，UI 不阻塞。回调通过
  /// `NativeCallable.listener` 回到当前 isolate。
  ///
  /// ```dart
  /// final detail = await SourinCore.callAsync('get_detail', {
  ///   'provider': 'cycani', 'id': '3611',
  /// });
  /// ```
  static Future<dynamic> callAsync(String cmd, [Map<String, dynamic>? args]) {
    _ensureBound();
    _ensureCallbackReady();

    final id = _nextId++;
    final completer = Completer<dynamic>();
    // 超时兜底：万一 Rust 侧永远不回调（不该发生），至少不让 UI 无限等下去
    final timer = _ffiSafeTimer(const Duration(seconds: 120), () {
      if (_pending.remove(id) == null) return;
      completer.completeError(
        SourinCoreException('命令 $cmd 超时（120 秒）', 'network'),
      );
    });
    _pending[id] = _PendingCall(completer, timer);

    final req = jsonEncode({'cmd': cmd, if (args != null) 'args': args}).toNativeUtf8();
    try {
      _callAsyncFn!(
        req,
        _callable!.nativeFunction.address,
        id, // 当作 user_data 用（Rust 只原样回传）
      );
    } catch (e) {
      // 进不到原生 ⇒ 拆掉计时器，否则它会悬空 120 秒
      final pending = _pending.remove(id);
      pending?.timer.cancel();
      return Future.error(e);
    } finally {
      malloc.free(req);
    }

    // ★ 直接返回 completer 本身（不套 `future.timeout`）：超时由上面的
    //   Timer 负责，且在完成/失败两条路径上都被 cancel 掉了。
    return completer.future;
  }

  /// 读字符串并**立即释放** Rust 侧的内存
  ///
  /// # 为什么统一在这里 free
  ///
  /// Rust 每次调用都新分配一个字符串。如果交给调用方 free，
  /// 只要有一处忘了就是稳定泄漏。集中处理不给漏的机会。
  static dynamic _readAndFree(Pointer<Utf8> p) {
    if (p == nullptr) return null;
    // 必须先读出来再 free（free 之后内存就无效了）
    final text = p.toDartString();
    _freeFn!(p);
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  /// 读出字符串并**立刻** free（不做 JSON 解码）
  ///
  /// 单独拆出来是为了让「大 JSON 解码挪出 UI isolate」那条路能**先把内存
  /// 还给 Rust**，再把解码扔去别的 isolate —— 读取与 free 必须原子，
  /// 否则要么泄漏要么 free 掉还在用的内存。
  static String? _readStringAndFree(Pointer<Utf8> p) {
    if (p == nullptr) return null;
    final text = p.toDartString();
    _freeFn!(p);
    return text;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  流式命令（2026-09-22）
  // ═══════════════════════════════════════════════════════════════════

  /// 流式命令的回调表：token → 事件处理函数
  ///
  /// # 为什么用 Map 而不是单个闭包
  ///
  /// 可能同时有多路流（用户在搜索页快速改关键词，前一次还没结束）。
  /// 单一闭包无法区分是哪一路 —— 会把 A 的事件发给 B。
  static final Map<int, void Function(dynamic)> _streamHandlers = {};

  /// 流式专用回调（**与 [callAsync] 的 `_callable` 是两个不同的对象**）
  ///
  /// # ★★ 这里踩过一个真实的坑（2026-09-22，实测才暴露）
  ///
  /// 我第一版偷懒，把 `_callable!.nativeFunction.address` 传给了
  /// `sourin_call_stream` —— 那个回调的 handler 是 [_onNativeResult]：
  /// ```dart
  /// final id = userData.address;
  /// final completer = _pending.remove(id);
  /// if (completer == null) return;      // ← 静默丢弃
  /// ```
  /// 而流式事件的 `userData` 是 **token**，不是 `_pending` 里的请求 id →
  /// **永远查不到 → 事件全被静默丢弃**。
  ///
  /// 表现（实测）：探针卡在流式搜索那一步**永远不返回**
  ///（`flutter analyze` 完全查不出来，因为类型是对的）。
  /// 而且 `_readAndFree` 也没被调 → Rust 每次回调分配的字符串**泄漏**。
  ///
  /// 教训：**FFI 回调地址必须与它期望的 userData 语义配对**。
  /// 两个机制长得像不代表能互换。
  static NativeCallable<_StreamCallbackC>? _streamCallable;

  static void _ensureStreamCallbackReady() {
    if (_streamCallable != null) return;
    _streamCallable =
        NativeCallable<_StreamCallbackC>.listener(_onStreamEvent);
  }

  static int _nextToken = 1;

  /// 流式回调（必须 void 返回 —— 见 typedef 处的说明）
  static void _onStreamEvent(Pointer<Utf8> eventPtr, int token) {
    final handler = _streamHandlers[token];
    // 先读再 free（不管有没有 handler 都要 free，否则泄漏）
    final value = _readAndFree(eventPtr);
    if (handler == null) return; // 已取消/已结束，丢弃
    try {
      handler(value);
    } catch (e, st) {
      // ⚠️ 回调里抛异常**不能**让它冒泡回 native —— 那会 abort 进程。
      //    记下来，让流的 Future 以错误结束。
      _streamErrors[token] = e;
      /*
       * ⚠️ 这里用 `print` 而不是 `debugPrint` ——
       *    `ffi.dart` **不依赖 Flutter**（它是纯 Dart 的 FFI 绑定层），
       *    引入 `package:flutter/foundation.dart` 只为一个日志函数不划算，
       *    而且会让这层无法在纯 Dart 测试里跑。
       */
      // ignore: avoid_print
      print('[SourinCore] 流式回调抛异常 token=$token: $e\n$st');
    }
  }

  /// 回调里发生的异常（在流结束时抛给调用方）
  static final Map<int, Object> _streamErrors = {};

  /// ★ 执行一个流式命令
  ///
  /// # 与 [callAsync] 的区别
  ///
  /// ```text
  /// callAsync   → 执行一次命令 → 回调一次 → Future 完成
  /// callStream  → 执行一次命令 → 回调**多次** → 收到 done 才算完成
  /// ```
  ///
  /// # 取消
  ///
  /// [onEvent] 返回 `false` 时**立刻取消**：
  /// ```text
  /// Dart 侧调 sourin_cancel_stream(token)
  ///   → Rust 下次要发事件时发现标志 → 返回 false
  ///   → search_all_stream 提前 return → 生产者 abort
  ///   → 当前网络请求也随之取消
  /// ```
  /// 实测：取消后 **0.66 秒**返回，而不是等剩余源跑完（30 秒以上）。
  ///
  /// # 为什么取消不靠回调返回值
  ///
  /// 见 `_StreamCallbackC` 处的说明 —— Dart 的跨线程回调必须返回 void，
  /// 拿不到同步返回值。所以只能走带外信号。
  static Future<void> callStream(
    String cmd,
    Map<String, dynamic> args,
    bool Function(dynamic event) onEvent,
  ) {
    _ensureBound();
    // ★ 用流式专用回调（不是 _ensureCallbackReady —— 那是 callAsync 的）
    _ensureStreamCallbackReady();

    final token = _nextToken++;
    final completer = Completer<void>();
    // 超时兜底：与 callAsync 同理（自己持有并在所有出口 cancel），
    // 不用 `future.timeout` —— 那样会在调用方提前放弃时留下悬空计时器。
    final timer = _ffiSafeTimer(const Duration(seconds: 180), () {
      if (!completer.isCompleted) {
        _cancelStreamFn!(token);
        _streamHandlers.remove(token);
        completer.completeError(
          SourinCoreException('流式命令 $cmd 超时（180 秒）', 'network'),
        );
      }
    });

    _streamHandlers[token] = (dynamic ev) {
      if (completer.isCompleted) return;

      /*
       * ★ 先识别流结束信号 —— 它们**不该**交给业务回调
       *
       * Rust 侧约定：
       * ```text
       * {"kind":"done"}                       全部源都跑完了
       * {"kind":"error","error":"..."}        流本身出错
       * ```
       * 如果把它们也交给 `onEvent`，业务层要自己过滤一遍 ——
       * 每个调用点都得写，漏一个就会在 UI 上多出一条"源"。
       */
      final kind = (ev is Map) ? ev['kind'] : null;

      if (kind == 'done') {
        _streamHandlers.remove(token);
        timer.cancel();
        completer.complete();
        return;
      }
      if (kind == 'error') {
        _streamHandlers.remove(token);
        timer.cancel();
        completer.completeError(
          SourinCoreException(
            (ev is Map ? ev['error'] : null)?.toString() ?? '流式命令失败',
            'other',
          ),
        );
        return;
      }

      bool keep;
      try {
        keep = onEvent(ev);
      } catch (e) {
        // 业务回调抛异常 → 取消并让 Future 失败
        _cancelStreamFn!(token);
        _streamHandlers.remove(token);
        timer.cancel();
        completer.completeError(e);
        return;
      }
      if (!keep) {
        // ★ 通知 Rust 停止（带外信号）
        _cancelStreamFn!(token);
        /*
         * ⚠️ 这里**不立刻 complete** —— Rust 侧收到取消后会走收尾流程，
         *    最后仍会发一个 done 事件（这样调用方知道"确实结束了"）。
         *    若提前 complete，调用方可能在 Rust 还在收尾时就开始
         *    下一轮搜索，两路流的 token 不同但网络请求会叠在一起。
         */
      }
    };

    final req =
        jsonEncode({'cmd': cmd, 'args': args}).toNativeUtf8();
    try {
      _callStreamFn!(
        req,
        /*
         * ★ 必须用 **_streamCallable**（不是 _callable）
         *
         * 见 `_streamCallable` 处的说明 —— 用错回调会让所有事件
         * 被静默丢弃，表现为「流式命令永远不返回」。
         */
        _streamCallable!.nativeFunction.address,
        token,
      );
    } catch (e) {
      _streamHandlers.remove(token);
      timer.cancel();
      return Future.error(e);
    } finally {
      malloc.free(req);
    }

    return completer.future;
  }

  /// 主动取消一路流式命令（幂等）
  ///
  /// 一般不用直接调 —— [callStream] 的 `onEvent` 返回 false 时已自动取消。
  /// 但**页面被销毁**（用户直接返回）时，UI 层应该显式调一次，
  /// 否则那路流会继续跑到所有源都结束。
  static void cancelStream(int token) {
    _ensureBound();
    _cancelStreamFn?.call(token);
    _streamHandlers.remove(token);
  }

  /// 测试收尾用：拆掉所有**仍在途**调用的兜底计时器
  ///
  /// ★ 为什么要它（2026-10-10）
  ///
  /// 每次 `callAsync` / `callStream` 都会挂一个 120 / 180 秒的 `Timer` 作为
  /// 「Rust 永远不回调」的兜底。widget 测试跑在 `FakeAsync` 里，tearDown 会断言
  /// 「树上不许有未结束的计时器」⇒ 测试主体比回调更快结束时，这个**安全网**
  /// 会被判成泄漏：
  /// ```text
  /// A Timer is still pending even after the widget tree was disposed.
  /// ```
  /// 真实环境里它无害（最多 120 秒后自动结束），所以正确做法是在**测试收尾**
  /// 取消它，而不是删掉兜底或放宽断言。
  ///
  /// 见 `test/flutter_test_config.dart`（每个测试文件都会自动调用）。
  ///
  /// ⚠️ 不完成那些 `Completer`：调用方可能还挂着 `await`，完成它会让本该安静
  ///   结束的测试突然拿到结果或报错。只拆计时器是最小干预。
  @visibleForTesting
  static void debugCancelPendingCalls() {
    for (final p in _pending.values) {
      p.timer.cancel();
    }
    _pending.clear();
  }
}
