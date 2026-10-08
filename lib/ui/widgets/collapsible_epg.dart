// ═══════════════════════════════════════════════════════════════════════
//  可折叠的节目单容器（task-39 新增）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要"可折叠"
//
// lead 裁决【设计点 3】= A（放播放器下方）+ **可折叠**，理由：
// ```text
// ① 用户要的是"**列表**占满高度" —— 播放器下方放 EPG 不违背它
//    （列表仍然满高）
// ② ★ EPG 是**已有功能**，不能因为改布局就默默删掉
// ③ ★★ 但 cctv 是我们唯一有 EPG 的源（`capabilities.epg`），
//    而 cctv 的频道现在**默认被隐藏**了 ⇒ EPG 常常是空的
//    ⇒ 空着一大块很浪费 ⇒ 默认折叠，有数据才自动展开
// ```
//
// # ★ 一个容易搞错的点：EPG 是"按频道"的
//
// `get_epg(provider, channelId)` —— 换台要重新取。
// 所以"折叠状态"不该在换台时被重置（用户折叠了就是想让它一直收着），
// 但"自动展开"只该在**第一次拿到数据**时做一次，
// 否则用户手动折叠后换个台又弹开，会很烦。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

class CollapsibleEpg extends StatefulWidget {
  const CollapsibleEpg({super.key, required this.child, this.autoExpand = true});

  final Widget child;

  /// 拿到数据时是否自动展开一次（默认开；用户手动折叠后不再自动展开）
  final bool autoExpand;

  @override
  State<CollapsibleEpg> createState() => CollapsibleEpgState();
}

class CollapsibleEpgState extends State<CollapsibleEpg> {
  bool _open = false;

  /// 用户有没有**手动**操作过
  ///
  /// ★ 一旦用户手动操作过，就**不再自动展开** ——
  ///   否则"我折叠了，换个台它又弹出来"，用户会觉得按钮坏了。
  ///
  /// ⚠️ 现在还没有"父级通知有数据了"的接口，所以这个标记暂时只用于
  ///    `openOnce()`（给父级在拿到 EPG 数据时调一次）。
  ///    之所以先留着：`didUpdateWidget` 里要判断"要不要自动展开"。
  bool _userTouched = false;

  /// 父级拿到 EPG 数据时调一次 —— 只在用户没手动动过时自动展开
  ///
  /// ★ 为什么是"一次性"而不是"跟着数据走"：
  ///   换台会导致 EPG 反复加载 ⇒ 每次都自动展开的话，
  ///   用户手动折叠后换个台又弹开。`_userTouched` 就是拦这个的。
  void openOnce() {
    if (_userTouched || _open) return;
    setState(() => _open = true);
  }

  /// 当前是否展开（测试用）
  bool get isOpen => _open;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            _open = !_open;
            _userTouched = true;
          }),
          borderRadius: Radii.rMd,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x2,
              vertical: Sp.x2,
            ),
            child: Row(
              children: [
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  '节目单',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open) widget.child,
      ],
    );
  }
}
