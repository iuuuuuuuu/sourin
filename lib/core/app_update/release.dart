// ═══════════════════════════════════════════════════════════════════════
//  GitHub Release 的解析 + 按平台挑选资产
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么**解析**与**下载**分成两个文件
//
// 解析是纯函数（JSON 字符串 ⇒ 对象），用录制夹具就能测；
// 下载是 IO。混在一起时，网络不通的那天连解析都测不了。

import 'semver.dart';

/// 一个可下载的资产
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.url,
    required this.browserUrl,
  });

  /// 文件名（CI 里给的名字）
  final String name;

  /// 字节数（GitHub 的 `size` 字段）
  final int size;

  /// 直链（`browser_download_url`），下载用这个
  final String url;

  /// 打开在浏览器里的页面（Android 降级方案用）
  final String browserUrl;

  /// 人类可读的体积（`28.4 MB`）
  String get prettySize {
    if (size <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = size.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return i == 0 ? '${v.toStringAsFixed(0)} ${units[i]}'
                  : '${v.toStringAsFixed(1)} ${units[i]}';
  }
}

/// 一个 Release
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.name,
    required this.notes,
    required this.assets,
    required this.prerelease,
    required this.htmlUrl,
    required this.publishedAt,
  });

  final String tag;
  final String name;

  /// 版本说明（Markdown 原文）
  final String notes;
  final List<ReleaseAsset> assets;
  final bool prerelease;
  final String htmlUrl;
  final DateTime? publishedAt;

  /// 规范化后的版本号（`v1.2.3` ⇒ `1.2.3`）
  String get version => stripTagPrefix(tag);

  /// 展示用的标题（没有 title 就用 tag）
  String get displayTitle => name.trim().isEmpty ? tag : name.trim();
}

/// 解析失败（网络返回的不是预期结构）
class ReleaseParseException implements Exception {
  ReleaseParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 解析 `releases/latest`（或 `releases` 列表的第一项）的 JSON
ReleaseInfo parseReleaseJson(Map<String, dynamic> json) {
  final tag = (json['tag_name'] ?? '').toString();
  if (tag.isEmpty) throw ReleaseParseException('发布信息里没有版本号');

  final rawAssets = json['assets'];
  final assets = <ReleaseAsset>[];
  if (rawAssets is List) {
    for (final a in rawAssets) {
      if (a is! Map) continue;
      final url = (a['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      assets.add(ReleaseAsset(
        name: (a['name'] ?? '').toString(),
        size: _asInt(a['size']),
        url: url,
        browserUrl: (a['html_url'] ?? url).toString(),
      ));
    }
  }
  DateTime? published;
  final p = (json['published_at'] ?? '').toString();
  if (p.isNotEmpty) published = DateTime.tryParse(p)?.toLocal();

  return ReleaseInfo(
    tag: tag,
    name: (json['name'] ?? '').toString(),
    notes: (json['body'] ?? '').toString(),
    assets: assets,
    prerelease: json['prerelease'] == true,
    htmlUrl: (json['html_url'] ?? '').toString(),
    publishedAt: published,
  );
}

/// 解析 `releases` 列表（勾选「包含预发布」时用）
List<ReleaseInfo> parseReleaseListJson(List<dynamic> json) {
  final out = <ReleaseInfo>[];
  for (final e in json) {
    if (e is! Map) continue;
    try {
      out.add(parseReleaseJson(e.cast<String, dynamic>()));
    } on ReleaseParseException {
      // 单条坏数据不该让整个列表消失
    }
  }
  // 列表默认按创建时间倒序，但我们**按版本号**自己排 —— 语义更可靠
  out.sort((a, b) {
    final x = SemVer.tryParse(a.tag);
    final y = SemVer.tryParse(b.tag);
    if (x == null || y == null) return b.publishedAt?.compareTo(a.publishedAt ?? DateTime(2000)) ?? 0;
    return y.compareTo(x);
  });
  return out;
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

/// 下载哪个平台
enum UpdatePlatform { windows, android, androidTv, macos }

/// 按平台挑资产；挑不到返回 null（UI 据此显示「无可用安装包」）
///
/// # CI 的产物名（与 `.github/workflows/build.yml` 逐字对齐）
/// ```text
/// Windows   Sourin-Setup-<ver>.exe          安装包（优先）
///            sourin-windows-<tag>.zip        免安装
/// macOS      sourin-macos-<tag>.dmg          拖拽安装
///            sourin-macos-<tag>.zip          兜底
/// Android    sourin-android-arm64-<tag>.apk
///            sourin-android-armv7-<tag>.apk
/// ```
///
/// ⚠️ Android TV 与手机**同一个 APK**（CI 只出一个包），所以
///   [UpdatePlatform.androidTv] 与 android 共用选择逻辑 ——
///
/// # 排序策略：先按名字筛出候选，再按偏好顺序取第一个
/// （不写死「一定要 arm64」：设备 ABI 的判定在
///  `selectForAbi`，把「平台」与「架构」两件事分开才好测。）
ReleaseAsset? selectAsset(
  ReleaseInfo release,
  UpdatePlatform platform, {
  String? abi,
}) {
  final byName = release.assets;
  if (byName.isEmpty) return null;

  switch (platform) {
    case UpdatePlatform.windows:
      // 安装包优先 —— 免安装 zip 对普通用户是「不知道放哪」
      final setup = _firstWhere(byName, (a) {
        final n = a.name.toLowerCase();
        return n.startsWith('sourin-setup-') && n.endsWith('.exe');
      });
      if (setup != null) return setup;
      return _firstWhere(byName, (a) => a.name.toLowerCase().endsWith('.exe'));

    case UpdatePlatform.macos:
      final dmg = _firstWhere(byName, (a) => a.name.toLowerCase().endsWith('.dmg'));
      if (dmg != null) return dmg;
      return _firstWhere(byName, (a) => a.name.toLowerCase().endsWith('.zip'));

    case UpdatePlatform.android:
    case UpdatePlatform.androidTv:
      return selectForAbi(byName, abi);
  }
}

/// 按 ABI 选 APK；[abi] 为空/未知时退回 arm64（覆盖面最广）
ReleaseAsset? selectForAbi(List<ReleaseAsset> assets, String? abi) {
  final apks = assets.where((a) => a.name.toLowerCase().endsWith('.apk')).toList();
  if (apks.isEmpty) return null;
  // ★ 先试**精确**的 ABI，再试它的俗称，最后才是通用回退 ——
  //   顺序反了会把 armeabi-v7a 的设备判成 arm64（名字里都含 "arm"）。
  //   俗称表是穷举的：`armeabi-v7a` 在 CI 产物里叫 `armv7`，字符串上
  //   **互不包含** ⇒ 只能靠显式映射，不能靠 contains 猜。
  const aliases = <String, List<String>>{
    'arm64-v8a': ['arm64-v8a', 'arm64', 'aarch64'],
    'armeabi-v7a': ['armeabi-v7a', 'armv7', 'armeabi'],
    'x86_64': ['x86_64', 'x64'],
  };
  final order = <String>[];
  for (final a in [
    ...?aliases[abi],
    if (abi != null && abi.isNotEmpty && !aliases.containsKey(abi)) abi,
    'arm64-v8a',
    'arm64',
    'armeabi-v7a',
    'armv7',
    'universal',
  ]) {
    if (!order.contains(a)) order.add(a);
  }
  for (final key in order) {
    final hit = _firstWhere(apks, (a) => a.name.toLowerCase().contains(key));
    if (hit != null) return hit;
  }
  return apks.first;
}

ReleaseAsset? _firstWhere(
  List<ReleaseAsset> assets,
  bool Function(ReleaseAsset) test,
) {
  for (final a in assets) {
    if (test(a)) return a;
  }
  return null;
}

/// 解析 `SHA256SUMS.txt`（`<hex>  <文件名>` 每行一条）
///
/// ⚠️ 文件里通常混着**别的平台**的条目（三个平台的包都在里面），
///   所以只查我们要下的那个文件名，别把整张表当"白名单"。
Map<String, String> parseSha256Sums(String text) {
  final out = <String, String>{};
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    // shasum 的格式可能是 `hash *file`（二进制模式带星号）
    final m = RegExp(r'^\*?([0-9a-fA-F]{64})\s+(.+)$').firstMatch(t);
    if (m == null) continue;
    out[m.group(2)!.trim()] = m.group(1)!.toLowerCase();
  }
  return out;
}

/// 从 `SHA256SUMS.txt` 里取某个文件的期望摘要
String? expectedSha256(Map<String, String> sums, String fileName) {
  final direct = sums[fileName];
  if (direct != null) return direct;
  // Windows 的安装包名里带版本号（`Sourin-Setup-1.0.0.exe`），
  // 退一步按「去掉版本号后的形状」匹配，避免大小写/前缀差异。
  for (final e in sums.entries) {
    if (e.key.toLowerCase() == fileName.toLowerCase()) return e.value;
  }
  return null;
}