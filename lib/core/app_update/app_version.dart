// ═══════════════════════════════════════════════════════════════════════
//  「我现在是哪个版本」
// ═══════════════════════════════════════════════════════════════════════
//
// # 三层来源，优先级从高到低
// ```text
// ① --dart-define=SOURIN_VERSION=<tag>   CI 发版时注入（唯一权威来源）
// ② 硬编码的兜底 '1.0.0'                 本地构建 / 没注入时
// ```
//
// # 为什么 ① 要用 tag 而不是另写一个 semver
//
// 发版时 tag 与二进制里的版本号**必须一致**，否则用户手机上显示
// `1.0.0` 而更新检查说 `1.0.1` 是新版 —— 于是它永远不会提示自己已更新
// （Owner 会觉得"检查更新没用"）。CI 注入的是同一个 tag，
// 不存在两处各写一遍的可能。
//
// # 为什么不用 `package_info_plus`（本地实测后放弃）
//
// 它目前只是 forui 带进来的**传递依赖**，而 forui 正在被移除 ——
// 等它被删掉，这个 import 会在某天突然编不过。把它提成直接依赖
// 又要动 pubspec（theme agent 同时在改那个文件，冲突不可避免）。
//
// 而它能多给的只有"本地自己 build 的安装包版本"这一种场景 ——
// 那种构建本来就该显示兜底版本。**不值的**。
//
// # 为什么不做「运行时读 pubspec.yaml」
//
// pubspec 在构建期就被吃掉了，运行期根本不存在那个文件。

import 'semver.dart';

class AppVersionInfo {
  const AppVersionInfo({
    required this.version,
    required this.fromRelease,
  });

  /// 版本号（无前导 `v`）
  final String version;

  /// 是否来自 CI 注入（界面会显示成「正式版 x.y.z」）
  final bool fromRelease;
}

class AppVersion {
  AppVersion._();

  /// CI 注入的版本（空 = 没注入）
  static const injected =
      String.fromEnvironment('SOURIN_VERSION', defaultValue: '');

  /// 兜底版本 —— 与 pubspec 的 `version: 1.0.0+1` 对齐
  static const fallback = '1.0.0';

  static AppVersionInfo? _cache;

  /// 读版本；任何一步失败都**不抛**（关于页不该因为读不到版本就白屏）
  static Future<AppVersionInfo> load() async {
    if (_cache != null) return _cache!;

    if (injected.trim().isNotEmpty) {
      final v = stripTagPrefix(injected.trim());
      if (v.isNotEmpty) {
        return _cache = AppVersionInfo(version: v, fromRelease: true);
      }
    }

    return _cache = const AppVersionInfo(version: fallback, fromRelease: false);
  }

  /// 测试用：清缓存并覆盖下一次 [load] 的结果
  static void debugSetForTest(AppVersionInfo? info) => _cache = info;

  /// 「1.2.3」这种可比对的版本号（解析不了就返回 null）
  static String? get currentSemVer {
    final v = _cache?.version ?? injected.trim();
    return SemVer.tryParse(v)?.toString();
  }
}