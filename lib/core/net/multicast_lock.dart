// ═══════════════════════════════════════════════════════════════════════
//  组播锁（MulticastLock）—— 让 Android 把组播包交给应用
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个（投屏 task-27 的真机前置条件）
//
// Android 的 Wi-Fi 栈**默认不把组播包交给应用** —— 这是省电设计。
// 而 DLNA/UPnP 的设备发现完全建立在组播之上：
// ```text
//   M-SEARCH  → 发到 239.255.255.250:1900（组播）
//   应答/NOTIFY → 设备回包（可能是单播，也可能是组播）
// ```
// 不持锁的典型症状：**扫描永远 0 台设备**，而日志里"M-SEARCH 发出去了"
// 又一切正常 —— 因为包确实发出去了，只是**收不到**。
//
// # 两条缺一不可（Android 官方文档 + AOSP 源码）
//
// ```text
// ① AndroidManifest.xml 声明 CHANGE_WIFI_MULTICAST_STATE
//    没有它，createMulticastLock() 直接抛 SecurityException
// ② 运行时真的持有 WifiManager.MulticastLock
//    只声明不持锁 = 照样收不到组播（权限只是"允许申请"）
// ```
// 本文件负责 ②，① 在 `android/app/src/main/AndroidManifest.xml`，
// 原生实现（createMulticastLock / acquire / release）在
// `MainActivity.kt` 的 `sourin/net` 通道。
//
// # ★ 拿不到锁不是错误
//
// 这些情况**都会**拿不到锁，而且都是正常的：
// ```text
// · 非 Android（Windows/测试环境）      → 组播本来就不需要锁
// · 模拟器（QEMU 用户态网络）           → 组播路径本身就是断的
// · 以太网 / 没有 Wi-Fi 硬件            → WifiManager 返回 null
// · flutter test（MethodChannel 无实现） → MissingPluginException
// ```
// 所以本类**只返回 bool，从不抛异常**：调用方拿到 false 就照常继续扫描
// —— 组播路径自然退化，不该因此报错。反过来，把 false 当错误弹给用户
// 才是错的（用户会看到一个跟他无关的报错）。
//
// # ⚠️ 未在真机验证（如实标注）
//
// 本机只有 x86_64 模拟器，其网络是 QEMU 用户态栈（组播包计数恒为 0，
// 实测见 `.probe/cast/TASK27-REPORT.md`）⇒ **"真机上到底还需不需要
// 这把锁"在本仓库没有实证**，依据只有 Android 官方文档与 AOSP 的
// WifiManager 实现。这条限制不要在任何报告里写成"已验证"。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 原生组播锁的 Dart 侧门面
///
/// 用法（**推荐 `scope`，它保证异常路径也会释放**）：
/// ```dart
/// final result = await MulticastLock.scope(() => SsdpDiscovery.scan());
/// ```
abstract final class MulticastLock {
  static const _channel = MethodChannel('sourin/net');

  /// 是否处于持有状态（**仅供诊断/测试**，不要用它做逻辑判断 ——
  /// 原生侧可能因为别的原因释放）
  static bool get held => _held;
  static bool _held = false;

  /// 诊断：最近一次失败原因（拿不到锁时非空，仅用于日志）
  static String? get lastFailure => _lastFailure;
  static String? _lastFailure;

  /// 测试用：在非 Android 宿主上强制走「Android 分支」
  ///
  /// ★ 存在的理由：`Platform.isAndroid` 在 flutter test 里**恒为 false**
  ///   （测试跑在 Windows 上），不强制的话通道分支永远测不到 ——
  ///   而那正是真机上真正会跑的那条路。
  @visibleForTesting
  static bool debugAndroidOverride = false;

  static bool get _onAndroid => Platform.isAndroid || debugAndroidOverride;

  /// 申请组播锁。返回是否**真的**拿到了。
  ///
  /// 幂等：已持有时直接返回 true。
  /// 任何异常都被吞掉（见文件头「拿不到锁不是错误」）。
  static Future<bool> acquire() async {
    if (_held) return true;
    if (!_onAndroid) {
      // 非 Android 不需要这把锁 —— 不算失败，直接算"已具备条件"
      _lastFailure = null;
      return true;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('acquireMulticastLock');
      _held = ok == true;
      _lastFailure = _held ? null : '原生侧返回 false（无 Wi-Fi 硬件或权限被拒）';
      if (!_held) debugPrint('[NET] 组播锁未取得：$_lastFailure');
      return _held;
    } on MissingPluginException {
      // flutter test / 未注册通道 —— 测试环境本来就没有原生侧
      _lastFailure = '通道 sourin/net 未注册（测试环境）';
      return false;
    } catch (e) {
      _lastFailure = '$e';
      debugPrint('[NET] 组播锁申请异常（按未取得处理）：$e');
      return false;
    }
  }

  /// 释放组播锁。幂等；没持有时是 no-op。
  static Future<void> release() async {
    if (!_onAndroid) return;
    if (!_held) return;
    try {
      await _channel.invokeMethod<bool>('releaseMulticastLock');
    } catch (e) {
      debugPrint('[NET] 组播锁释放异常（忽略）：$e');
    } finally {
      _held = false;
    }
  }

  /// 在持有组播锁的期间执行 [body]，**无论成功/失败/抛异常都会释放**。
  ///
  /// 拿不到锁时也照常执行 [body]（只是组播可能收不到）——
  /// 这样调用方不需要写两套分支。
  static Future<T> scope<T>(Future<T> Function() body) async {
    await acquire();
    try {
      return await body();
    } finally {
      await release();
    }
  }

  /// 测试用：重置内部状态
  @visibleForTesting
  static void debugReset() {
    _held = false;
    _lastFailure = null;
    debugAndroidOverride = false;
  }
}
