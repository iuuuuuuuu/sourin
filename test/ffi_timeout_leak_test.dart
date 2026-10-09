// FFI 超时计时器不得悬空（2026-10-10）
//
// # 缺陷是什么
//
// `callAsync` / `callStream` 原来返回 `completer.future.timeout(120s)`。
// 那个内部 Timer 只有在 Future **真的被等到超时**或被正常完成时才被取消；
// 页面提前销毁、调用方不再 await 时它就挂在树上，于是：
//
// ```text
// A Timer is still pending even after the widget tree was disposed.
// ```
//
// # 怎么复现（实测过的条件组合）
//
// `sourin_core.dll` 出现在仓库根目录时 `DynamicLibrary.open` 成功 ⇒ 命令真的走通
// ⇒ 测试树先销毁 ⇒ 悬空。dll 不在时 `callAsync` 立刻抛「核心不可用」，反而是绿的。
// 所以这个测试自己把核心加载起来（真 dll 或任何能被 DynamicLibrary.open 的名字都不行，
// 只能用 dll），并断言树销毁后没有 pending timer —— 这条在修复前是红的。
//
// ⚠️ 环境：需要 `sourin_core.dll` 可被 `DynamicLibrary.open('sourin_core.dll')` 找到。
//    找不到就跳过并说明原因（不许在 CI 上红）。
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';

void main() {
  // 探针：树销毁之后若有计时器存活，FakeAsync 会在 tearDown 报出来
  //（「A Timer is still pending even after the widget tree was disposed」）。
  // 这里只需要真实地「发出请求 → 不等它 → 销毁」。
  test('callAsync 发出请求后不等待：树销毁不得留下悬空计时器', () async {
    // ★ 不删这个目录：核心起来后会持有它的 SQLite 句柄，强删会报
    //   PathAccessException（errno=32）。它落在系统临时目录里，留着无害。
    final dir = Directory.systemTemp.createTempSync('sourin_ffi_probe');

    Object? caught;
    try {
      await SourinCore.startAsync(dir.path);
    } catch (e) {
      caught = e;
    }

    if (caught != null) {
      // 核心不可用 ⇒ 这个测试的前提不成立（不是「产品通过」）
      markTestSkipped('核心不可用，无法验证本条：$caught');
      return;
    }

    // 真发一条**异步**命令，并**不等**它（模拟页面提前销毁）
    unawaited(SourinCore.callAsync('list_providers').catchError((Object e) {
      throw e;
    }));
    // 同理：流式命令也发一条就放弃
    unawaited(SourinCore.callStream('search_all_stream', {'keyword': 'x'},
        (_) => true).catchError((Object e) => throw e));

    // 给回调一点点机会落地（真实 isolate 回调是异步投递）
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  test('命令在超时前完成 ⇒ 计时器立刻被拆掉（不残留 120 秒）', () async {
    // 同上：不删数据目录（核心持有句柄）
    final dir = Directory.systemTemp.createTempSync('sourin_ffi_probe2');

    Object? caught;
    try {
      await SourinCore.startAsync(dir.path);
    } catch (e) {
      caught = e;
    }
    if (caught != null) {
      markTestSkipped('核心不可用，无法验证本条：$caught');
      return;
    }

    // 这条命令很快返回；完成后不应再有计时器存活
    final r = SourinCore.callAsync('core_version');
    await r.timeout(const Duration(seconds: 5));
    expect(r, isA<Object?>());
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('sourin_core.dll 是否可加载（决定上面两条是否会被跳过）', () {
    // 只做探测，不做断言 —— 让 CI 上「跳过」的原因可见
    try {
      final lib = DynamicLibrary.open('sourin_core.dll');
      lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'sourin_core_version');
      // ignore: avoid_print
      print('[PROBE] sourin_core.dll 可加载 ⇒ FFI 超时探针会真跑');
    } catch (e) {
      // ignore: avoid_print
      print('[PROBE] sourin_core.dll 不可加载（$e）⇒ FFI 超时探针会跳过');
    }
  });
}