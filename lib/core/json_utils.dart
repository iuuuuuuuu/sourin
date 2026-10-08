// ═══════════════════════════════════════════════════════════════════════
//  JSON 解码工具 —— 契约的唯一下拉点
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要单独一个文件
//
// 依据 `.trellis/spec/guides/code-reuse-thinking-guide.md` 的 **Pattern 4**：
//
// > **Bad**：多个消费者各自把同一份 JSON 字段取出来
// > ```dart
// > final title = (m as Map)['title'] as String;
// > ```
// > 这是**重复的契约逻辑**，哪怕只有两行。每个消费者都拥有一份
// > 私有契约，下一次字段变更会改到一处、漏掉另一处。
// >
// > **Good**：抽成共享工具，各处 import。
//
// 第一版这些函数写在 `api.dart` 里（私有 `_str` / `_list` / `_map`）。
// 加播放链路时发现 `playback.dart` 也需要同一组函数 ——
// 那一刻就是「该抽出来了」的信号。
//
// # 错误策略：宁可抛，不要静默
//
// 字段缺失或类型不对时**抛异常**，而不是返回空串/null。
//
// 为什么：静默的空值会把「字段名拼错」变成**看不见的空界面** ——
// 开发期毫无提示，上线后用户看到一片空白。
// 抛出来则问题在开发期就暴露，错误消息还会带上实际收到的键名，
// 一眼能看出是不是拼写问题。

import 'ffi.dart';

/// 取必填字符串
///
/// 缺失或类型不对 → 抛 [SourinCoreException]，消息里带上实际收到的键。
String jstr(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v is String) return v;
  throw SourinCoreException(
    '字段 `$key` 缺失或不是字符串（实际: ${v.runtimeType}，收到的键: ${j.keys.toList()}）',
    'other',
  );
}

/// 取字符串列表（缺失/类型不对 → 空列表）
///
/// 与 [jstr] 不同，这里**容忍缺失**：数组字段在原版里
/// 大多是可选元数据（演员、导演、分类），没有是正常的。
List<String> jstrList(dynamic v) {
  if (v is! List) return const [];
  return v.whereType<String>().toList();
}

/// 解成对象
Map<String, dynamic>? jmapOrNull(dynamic v) {
  if (v == null) return null;
  if (v is Map) return v.cast<String, dynamic>();
  throw SourinCoreException('期望对象，实际收到 ${v.runtimeType}', 'other');
}

Map<String, dynamic> jmap(dynamic v) {
  final m = jmapOrNull(v);
  if (m == null) {
    throw SourinCoreException('期望对象，实际收到 null', 'other');
  }
  return m;
}

/// 解成模型列表
///
/// ⚠️ 数组里混了非对象元素时**跳过**而不是整体失败 ——
///    单个坏条目不该让整页白屏。
List<T> jlist<T>(dynamic v, T Function(Map<String, dynamic>) fromJson) {
  if (v == null) return const [];
  if (v is! List) {
    throw SourinCoreException('期望数组，实际收到 ${v.runtimeType}', 'other');
  }
  final out = <T>[];
  for (final e in v) {
    if (e is Map) {
      out.add(fromJson(e.cast<String, dynamic>()));
    }
  }
  return out;
}

/// 解分页结果 `Page<T>` → 条目列表
///
/// # 为什么单独抽出来
///
/// `get_list` / `get_rank` 返回的都是 `Page<T>`：
/// ```jsonc
/// { "items": [...], "page": 1, "page_count": 50, "total": 1000 }
/// ```
/// 而 `list_providers` 返回**裸数组** —— 两种形状不同。
/// 这里统一了「Page → items」的取法，避免每处都写一遍
/// `jmap(raw)['items']`。
List<T> jpage<T>(dynamic v, T Function(Map<String, dynamic>) fromJson) {
  final m = jmap(v);
  return jlist(m['items'], fromJson);
}

/// 解分页元信息（需要 total / page_count 时用）
class JPage {
  const JPage({required this.items, this.page, this.pageCount, this.total});

  final dynamic items;
  final int? page;
  final int? pageCount;
  final int? total;

  factory JPage.of(dynamic v) {
    final m = jmap(v);
    return JPage(
      items: m['items'],
      page: (m['page'] as num?)?.toInt(),
      pageCount: (m['page_count'] as num?)?.toInt(),
      total: (m['total'] as num?)?.toInt(),
    );
  }
}
