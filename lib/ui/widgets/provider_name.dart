// ═══════════════════════════════════════════════════════════════════════
//  源 id → 显示名（进程内缓存）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（task-32 用户原话）
//
// > 播放页和详情页都不能看到当前播放源是哪一个
//
// 两个页面拿到的都只有**源 id**（`widget.provider`，如 `cycani`），
// 而用户认的是**显示名**（`次元城`）。显示名只存在于
// `ProviderManifest.name`（`listProviders()` 的返回里）。
//
// # 为什么单独一个文件而不是各页各写一份
//
// ```text
// 两个页面都要这个查询 + 都要缓存
// ⇒ 写两份 = 两份缓存 = 两处会漂移（本项目反复记录过这个形态）
// ```
// 而且**缓存是必须的**：详情页每次 `build` 都可能要名字，
// 播放页同理 —— 不缓存就是每次重建都发一次 FFI 调用。
//
// # 为什么缓存是安全的（不会显示过期名字）
//
// `listProviders()` 走的是**本地注册表**（`libmpv` 那侧不需要网络，
// 见 `player_page.dart` 里 `_loginAndRetry` 的原注释：
// 「走的是本地注册表，没有网络开销」）。
// 而源名在运行期**不会变** —— 改名要重启核心（插件重载）。
// 所以进程内缓存不会显示过期数据。
//
// ⚠️ 但**失败不缓存** —— 否则一次瞬时失败会让整个进程再也拿不到名字。
//
// # 拿不到时**退回 id**，不是空字符串
//
// 与 `player_page.dart::_loginAndRetry` 同一条原则：
// ```text
// 用户此刻要的是"知道自己在哪个源"，不是"名字好看"。
// 显示 `cycani` 仍然回答了"是哪一个"；显示空字符串则什么都没回答。
// ```
import 'package:flutter/foundation.dart';

import '../../core/sourin_api.dart';

/// 进程内缓存：源 id → 显示名
///
/// `null` = **还没成功加载过**（与"加载成功但表为空"区分开 ——
/// 后者是合法的：一个插件都没装）。
Map<String, String>? _cache;

/// 确保缓存已加载；返回 `null` 表示这次加载失败
Future<Map<String, String>?> _ensure() async {
  final cached = _cache;
  if (cached != null) return cached;
  try {
    final list = await SourinApi.listProviders();
    final m = {for (final p in list) p.id: p.name};
    _cache = m;
    return m;
  } catch (e) {
    // ⚠️ 不写缓存（见文件头）—— 下次调用会重试
    debugPrint('[PROVIDER-NAME] listProviders 失败，退回 id: $e');
    return null;
  }
}

/// 取源的显示名（拿不到就退回 [id]）
///
/// 永不抛 —— 显示名是**装饰性**信息，不能因为它失败而让页面报错。
Future<String> providerDisplayName(String id) async {
  if (id.isEmpty) return id;
  final m = await _ensure();
  if (m == null) return id;
  final n = m[id];
  return (n == null || n.isEmpty) ? id : n;
}

/// 预热缓存 —— 页面可在 `initState` 里调，让名字早一帧就绪
///
/// ⚠️ **不要**实现成 `providerDisplayName('')` —— 那个函数在
///    `id.isEmpty` 时**提前返回**，根本不会去加载缓存（写错过一次）。
Future<void> warmProviderNameCache() async {
  await _ensure();
}

/// 清掉缓存（**仅供测试**）
///
/// 测试之间共享进程，不清会让"第一次加载失败"这类用例互相污染
/// （本项目已踩过 static 状态跨测试泄漏，见 VERIFY-LESSONS 铁律 11）。
@visibleForTesting
void resetProviderNameCache() => _cache = null;
