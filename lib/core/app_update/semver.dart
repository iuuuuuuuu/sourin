// ═══════════════════════════════════════════════════════════════════════
//  语义化版本号（只取我们需要的最小子集）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么自己写而不引 `pub_semver`
//
// `pub_semver` 只有一个类，但它把「构建元数据」的排序规则写得比 GitHub
// Release 实际使用的规则更细。我们真正要的判断只有一句：
// 「线上这个 tag 是不是比我现在的版本新」，**过度精确的排序反而会出错**
// （例如把 `1.0.0+ci.3` 判成比 `1.0.0` 新）。
//
// # 规则（与 GitHub / 常见发布流程一致）
// ```text
// 1.0.0        <  1.0.1
// 1.0.0-beta.1 <  1.0.0          （预发布 < 同版本正式版）
// 1.0.0-alpha.2 < 1.0.0-beta.1   （按标识符逐段比，字母序）
// ```
//
// 解析失败**一律返回 null**（不抛）—— 版本号来自网络，任何一步都该降级。

/// 一个已解析的版本号
class SemVer implements Comparable<SemVer> {
  const SemVer(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease = const [],
  });

  final int major;
  final int minor;
  final int patch;

  /// 预发布标识符（`1.0.0-beta.1` ⇒ `['beta', 1]`），空 = 正式版
  final List<Object> preRelease;

  bool get isPreRelease => preRelease.isNotEmpty;

  /// 是否带 `v` 前缀
  static final RegExp _re = RegExp(
    r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// 解析版本号；不合法返回 null（调用方按「拿不到版本」处理）
  static SemVer? tryParse(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    final m = _re.firstMatch(s);
    if (m == null) return null;
    final pre = <Object>[];
    if (m.group(4) != null && m.group(4)!.isNotEmpty) {
      for (final seg in m.group(4)!.split('.')) {
        // 纯数字段当数字比（beta.2 < beta.10），否则按字符串比
        pre.add(int.tryParse(seg) ?? seg);
      }
    }
    return SemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2) ?? '0'),
      int.parse(m.group(3) ?? '0'),
      preRelease: pre,
    );
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    // 两者都是正式版 → 相等
    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    // 正式版 > 任何预发布版（1.0.0-beta < 1.0.0）
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    final n = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < n; i++) {
      final a = preRelease[i];
      final b = other.preRelease[i];
      if (a is int && b is int) {
        if (a != b) return a.compareTo(b);
      } else if (a is int) {
        return -1; // 数字段 < 字符串段（SemVer 规范）
      } else if (b is int) {
        return 1;
      } else {
        final c = (a as String).compareTo(b as String);
        if (c != 0) return c;
      }
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }

  /// `a > b` 吗
  static bool greater(String? a, String? b) {
    final x = tryParse(a);
    final y = tryParse(b);
    if (x == null || y == null) return false;
    return x.compareTo(y) > 0;
  }

  @override
  String toString() => preRelease.isEmpty
      ? '$major.$minor.$patch'
      : '$major.$minor.$patch-${preRelease.join('.')}';
}

/// 去掉 tag 的前导 `v`（`v1.2.3` ⇒ `1.2.3`；本来就是纯数字则原样返回）
String stripTagPrefix(String tag) {
  final s = tag.trim();
  if (s.length > 1 && (s[0] == 'v' || s[0] == 'V')) return s.substring(1);
  return s;
}