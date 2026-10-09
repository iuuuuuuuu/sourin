// ═══════════════════════════════════════════════════════════════════════
//  底栏的「更多」分组浮层 —— 长尾功能收拢处（Owner 2026-10-09 第 12 条）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 为什么不是弹窗 / 抽屉
//  这一层里全是**低频但要留着**的东西（片头片尾、弹幕设置、投屏、画中画、
//  截图、画面缩放…）。它们每一项都要"弹一个全屏对话框"太重，
//  但一个下拉小卡片足够 —— 和 B 站的「更多」是同一种形态。
//
//  # 与 popover 的区别
//  ```text
//  popover  「从某个按钮上方弹出的一小段列表」—— 倍速 / 线路 / 清晰度
//  本件     「低频功能的分组入口清单」—— 每项点了**继续往下走**（打开对话框等）
//  ```
//  ⇒ 它是**二级**面板：本件里选一项 = 打开第三层（对话框）。
//
//  # 触达性：TV 方向键
//  每一项都是普通 `InkWell`（自带焦点）⇒ 方向键遍历、Esc / 返回键关闭
//  由 `PopoverController` 那一份真值源承担。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'player_popover.dart';

/// 「更多」里的一项
class MoreMenuEntry {
  const MoreMenuEntry({
    required this.label,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.hint,
    this.trailing,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  final String? hint;

  /// 行尾的自定义控件（投屏那枚要放真的 `CastButton`）；
  /// 非 null 时整行**不可点** —— 真正的动作在那个控件上。
  final Widget? trailing;
}

/// 一组（同组内用细分隔线隔开，组间用留白 —— 比多条实线更安静）
class MoreMenuGroup {
  const MoreMenuGroup(this.title, this.entries);

  final String title;
  final List<MoreMenuEntry> entries;
}

/// 「更多」浮层本体
class PlayerMoreMenu extends StatelessWidget {
  const PlayerMoreMenu({
    super.key,
    required this.groups,
    required this.onDismiss,
    this.width = 208,
  });

  final List<MoreMenuGroup> groups;
  final VoidCallback onDismiss;
  final double width;

  @override
  Widget build(BuildContext context) {
    return PlayerPopoverSurface(
      width: width,
      child: MouseRegion(
        // ★ 从按钮挪进面板时取消「收起」计时，否则永远点不进去
        onEnter: (_) {},
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var gi = 0; gi < groups.length; gi++) ...[
              if (gi > 0) const SizedBox(height: Sp.x1),
              PopoverGroupLabel(groups[gi].title),
              for (final e in groups[gi].entries)
                InkWell(
                  onTap: e.enabled && e.trailing == null
                      ? () {
                          onDismiss();
                          e.onTap();
                        }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Sp.x3,
                      vertical: Sp.x2,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          e.icon,
                          size: 17,
                          color: e.enabled
                              ? const Color(0xFFD8D8D8)
                              : const Color(0xFF6A6A6A),
                        ),
                        const SizedBox(width: Sp.x3),
                        Expanded(
                          child: Text(
                            e.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: e.enabled
                                  ? const Color(0xFFF2F2F2)
                                  : const Color(0xFF6A6A6A),
                              fontSize: FontSizes.sm,
                            ),
                          ),
                        ),
                        if (e.trailing != null)
                          e.trailing!
                        else if (e.hint != null && e.hint!.isNotEmpty)
                          Text(
                            e.hint!,
                            style: const TextStyle(
                              color: Color(0xFF8C8C8C),
                              fontSize: FontSizes.cap,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
