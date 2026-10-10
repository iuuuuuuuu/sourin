// ═══════════════════════════════════════════════════════════════════════
//  探针 3（OPS-9 / task-17 ②）：「来源」chip 到底卡在哪一步 —— 真事件循环版
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么还要第三个探针
//
// 探针 2 的结论是「listProviders() 的 future 永不完成」—— 但那是在
// **假时钟**里量的：testWidgets 的函数体跑在 FakeAsync 里，而
// NativeCallable.listener 的回包是走**真**消息端口投递的 ⇒ 假时钟下
// 真事件循环根本不转，回包永远送不进来。
// 所以「永不完成」可能只是**测量方式**的产物，不是产品的形态。
//
// 这一版把同一段调用放进 tester.runAsync（真事件循环）里量：
//
//   · 若真事件循环下它**能**回来 ⇒ 探针 2 的结论作废，E 组可以改判据让它可达
//   · 若仍然不回来             ⇒ 结论成立，E 组的判据必须换（不能留一条永远红的断言）
//
// ─────────────────────────────────────────────────────────────────────
// # 三种世界（2026-10-10 加：CI 上核心 dll 不存在时本文件不许判红）
// ─────────────────────────────────────────────────────────────────────
//
// 本探针是**测量工具**，不是门禁：它一条 expect 都没有。但它原先在核心
// 不可用时会把「加载 dll 失败」升级成 unhandled async error ⇒ 整条判红。
// 而仓库根**没有** sourin_core.dll 正是 CI 的真实状态 ⇒ 一个新增文件一红，
// CI 就红，红的却与它要量的东西无关。故显式区分三种世界：
//
//   1. 核心不可用（cwd 下没有 sourin_core.dll）：**无法测量** ——
//      打一行 [P3] SKIP 说明 + markTestSkipped 后正常结束（退出码 0）。
//   2. 核心可用：照旧如实打印四条读数（version / isLoaded /
//      callAsync(list_providers) / providerDisplayName(cycani)）。
//   3. 核心可用但结果异常：照旧如实打印，**不**新增 expect 把它变门禁。
//
// ★ 承重改动：runAsync 的函数体整体 try/catch。
//   flutter_test 的 AutomatedTestWidgetsFlutterBinding.runAsync
//   （flutter_test/src/binding.dart:2304-2321）把回调 future 的错误交给
//   FlutterError.reportError ⇒ 记成「The exception was caught asynchronously.」
//   ⇒ 测试失败。原代码的 `.catchError(...)` 看着有兜底，但
//   SourinCore.callAsync 里的 `_ensureBound()`（lib/core/ffi.dart:639）是
//   **同步抛**的 —— 异常在 `.then/.catchError` 挂上之前就已经出了函数体，
//   所以那个 catchError 从来没有机会跑。外面套一层 try/catch 才是真兜底。
//
// 跑法：
//   flutter test test/zz_cr_origin_probe3_test.dart --reporter expanded --concurrency=1

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/ui/widgets/provider_name.dart';

/// 核心 dll 的裸名 —— 与 `SourinCore._openLibrary()`（lib/core/ffi.dart:226）
/// 在 Windows 上 open 的**同一个**名字。
/// 裸名 ⇒ 查找顺序是 exe 同目录 → PATH ⇒ `flutter test` 的 cwd 就是仓库根。
const String _dllRel = 'sourin_core.dll';

/// 核心**可测量**吗？
///
/// ⚠️ 不能只写 `SourinCore.isLoaded`：它是 `_lib != null`（lib/core/ffi.dart:209），
///   **没碰过核心时恒为 false** —— 新 isolate 里在第一条读数之前它一定是
///   false，dll 明明就躺在 cwd 也照样判「不可用」，那「有 dll 就要真测量」
///   这条分支就永远走不到了。所以判据是「**要么已经加载，要么 dll 就在 cwd**」。
bool get _coreMeasurable => SourinCore.isLoaded || File(_dllRel).existsSync();

/// 跳过原因（markTestSkipped 的文案）
const String _unmeasurableReason = '无法测量：核心不可用（sourin_core.dll 不在 cwd）。'
    '跑法：把 sourin_core.dll 放到仓库根再跑本条；'
    '在 CI 上则应接受「本条跳过」—— 它量不出东西时不该判红。';

void main() {
  testWidgets('探针3：真事件循环下 listProviders / providerDisplayName 回不回来',
      (t) async {
    String dll;
    try {
      dll = 'existsSync=' + File(_dllRel).existsSync().toString();
    } catch (e) {
      dll = 'ERR:$e';
    }
    debugPrint('[P3] cwd=' + Directory.current.path);
    debugPrint('[P3] dll(' + dll + ')');

    // ── 世界 1：核心不可用 ⇒ 无法测量，显式跳过（不判红）────────────
    if (!_coreMeasurable) {
      debugPrint('[P3] SKIP 无法测量：核心不可用（sourin_core.dll 不在 cwd）');
      debugPrint('[P3] SKIP isLoaded=' +
          SourinCore.isLoaded.toString() +
          ' dllExists=' +
          File(_dllRel).existsSync().toString());
      markTestSkipped(_unmeasurableReason);
      return;
    }

    String ver;
    try {
      ver = SourinCore.version;
    } catch (e) {
      ver = 'THROW:$e';
    }
    debugPrint('[P3] version=' + ver + ' isLoaded=' + SourinCore.isLoaded.toString());

    // ── 世界 2 / 3：核心可用 ⇒ 真测量，四条读数如实打印 ─────────────
    await t.runAsync(() async {
      // ★ 承重：runAsync 里任何异步异常都会被 FlutterError.reportError 记成
      //   「The exception was caught asynchronously.」⇒ 判红。
      //   探针要的是「量不到就说量不到」，不是把**测量失败**冒充成**产品失败**。
      try {
        final f = SourinCore.callAsync('list_providers').then((r) =>
            'ok(type=${r.runtimeType},len=${r is List ? r.length : '-'})').catchError(
            (Object e) => 'err:$e');
        final r = await Future.any(<Future<String>>[
          f,
          Future<String>.delayed(const Duration(seconds: 4), () => 'TIMEOUT(4s)'),
        ]);
        debugPrint('[P3] callAsync(list_providers) = ' + r);

        resetProviderNameCache();
        final g = providerDisplayName('cycani');
        final n = await Future.any(<Future<String>>[
          g,
          Future<String>.delayed(const Duration(seconds: 4), () => 'TIMEOUT(4s)'),
        ]);
        debugPrint('[P3] providerDisplayName(cycani) = ' + n);
      } catch (e) {
        debugPrint('[P3] 测量中断：' + e.toString());
      }
    });
  });
}
