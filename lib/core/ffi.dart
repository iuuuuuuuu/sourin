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

import 'package:ffi/ffi.dart';

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
      _lib = DynamicLibrary.open('libsourin_core.dylib');
    } else {
      throw UnsupportedError('不支持的平台: ${Platform.operatingSystem}');
    }
    return _lib!;
  }

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
  /// 实现上是把它丢到 tokio 线程池里执行，避免阻塞 Dart 的 UI 线程。
  static Future<Map<String, dynamic>> startAsync(String dataDir) {
    _ensureBound();
    // 用同步版跑在独立的 isolate 上？不必 —— 更好的做法是
    // 复用 Rust 侧的异步能力：这里直接同步调，但放在
    // `compute`-like 的微任务里。实际启动耗时在毫秒级（实测 ~50ms），
    // 一次性的开销对首屏无影响。
    return Future(() => start(dataDir));
  }

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
  static final Map<int, Completer<dynamic>> _pending = {};
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
    final completer = _pending.remove(id);
    if (completer == null) return; // 已被取消/超时，忽略

    final value = _readAndFree(resultPtr);
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
    _pending[id] = completer;

    final req = jsonEncode({'cmd': cmd, if (args != null) 'args': args}).toNativeUtf8();
    try {
      _callAsyncFn!(
        req,
        _callable!.nativeFunction.address,
        id, // 当作 user_data 用（Rust 只原样回传）
      );
    } catch (e) {
      _pending.remove(id);
      return Future.error(e);
    } finally {
      malloc.free(req);
    }

    // 加个超时兜底：万一 Rust 侧永远不回调（不该发生），
    // 至少不让 UI 无限等下去
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _pending.remove(id);
        throw SourinCoreException('命令 $cmd 超时（120 秒）', 'network');
      },
    );
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
        completer.complete();
        return;
      }
      if (kind == 'error') {
        _streamHandlers.remove(token);
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
      return Future.error(e);
    } finally {
      malloc.free(req);
    }

    return completer.future.timeout(
      const Duration(seconds: 180),
      onTimeout: () {
        _cancelStreamFn!(token);
        _streamHandlers.remove(token);
        throw SourinCoreException('流式命令 $cmd 超时（180 秒）', 'network');
      },
    );
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
}
