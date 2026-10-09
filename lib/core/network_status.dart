// ═══════════════════════════════════════════════════════════════════════
//  联网状态 —— 供「离线时隐藏操作按钮」这类判据使用
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（Owner 第 1009 批 13）
// ```text
// 本地播放页要在**没网时不显示操作按钮**（收藏/追更/换源/下载）。
// 而这些按钮的实现全部要打网络 —— 网不通时点了只会报错。
// ⇒ 需要一个"此刻能不能上网"的判据。
// ```
//
// # ★ 三条纪律（都是被真实坑逼出来的）
// ```text
// ① **不许阻塞首帧**：判据是异步的，调用方必须能在"还不知道"时正常渲染
//    （默认按"有网"渲染 ⇒ 联网用户零感知；断网用户顶多多看一瞬再消失）。
// ② **不许用 DNS/ICMP 之外的玄学**：只做一次「能不能连上一个固定主机:443」的
//    TCP 握手 —— Windows 上 DNS 解析不可靠（会拖 5 秒），而 TCP connect
//    失败与成功都在几百毫秒内。
// ③ **不许抛**：任何异常一律降级成"按有网处理"，绝不把异常抛给调用方。
// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import 'app_log.dart';

/// 全局联网状态（一个进程一份）
class NetworkStatus {
  NetworkStatus._();

  /// 探测目标：任选一个稳定可达的地址即可 —— 这里**只关心通不通**，
  /// 不关心内容（不下载任何字节，握手成功即断开）。
  static const String _probeHost = 'www.msftconnecttest.com';

  static const int _probePort = 443;

  /// 上一次探测的结果
  ///
  /// ★ **初始值 = true**：与"不许阻塞首帧"配套 —— 首帧按有网渲染，
  ///   探测回来再纠正。离线用户代价是"按钮闪一下就没"，
  ///   在线用户则完全无感（反过来初始 false 会让联网用户白等一下）。
  static final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  static bool _probing = false;

  /// 探一次（**幂等**：已有一次在跑就直接返回）
  static Future<bool> refresh() async {
    if (_probing) return online.value;
    _probing = true;
    var result = true;
    Socket? s;
    try {
      s = await Socket.connect(
        _probeHost,
        _probePort,
        timeout: const Duration(milliseconds: 1500),
      );
      result = true;
    } on Object catch (e) {
      result = false;
      AppLog.write('NET', '联网探测失败：$e');
    } finally {
      // ★ 必须关掉：否则每次探测都漏一个 socket，几十次后进程句柄吃紧
      try {
        s?.destroy();
      } catch (_) {
        // 关不掉也不是错误（已经断了）—— 绝不因此让 refresh 抛出去
      }
      _probing = false;
    }
    if (online.value != result) online.value = result;
    return result;
  }

  /// 探针注入点（测试用；null = 真实探测）
  ///
  /// ★ 与本仓其它 `debug*` 注入点同一条纪律：生产路径（null）**一行都不走**这里。
  @visibleForTesting
  static Future<bool> Function()? debugProbe;

  @visibleForTesting
  static void debugResetForTest() {
    online.value = true;
    _probing = false;
    debugProbe = null;
  }

  /// 页面上用的一条龙：探一次并把结果写进 [online]
  ///
  /// ⚠️ 返回值只用于"刚探完这一刻"，UI 平时应当读 [online]（可监听）。
  static Future<bool> probe() async {
    final f = debugProbe;
    if (f != null) {
      final r = await f();
      if (online.value != r) online.value = r;
      return r;
    }
    return refresh();
  }
}
