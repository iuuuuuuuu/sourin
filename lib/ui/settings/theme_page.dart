// ═══════════════════════════════════════════════════════════════════════
//  二级页：主题（2026-09-25 任务 ㉙ 从 settings_page.dart 搬来）
// ═══════════════════════════════════════════════════════════════════════
//
// # 搬运说明（★ 逻辑一字未改，只换宿主）
//
// 原来这段是 `settings_page.dart` 里 `title: '主题'` 那个 `_Block`。
// 用户拍板方案 A 后搬到这里。**只改了宿主**：
// ```text
// 改前：settings_page.dart 的 _Block(title:'主题', children:[...])
// 改后：本文件 SettingsSubPage(title:'主题', children:[SettingsBlock(...)])
// ```
//
// # ★ 为什么 `GlassContainer` 必须在**容器**上，不能加在 pill 上
//
// 用户原话：
// > 设置页的主题,也没做液态玻璃
// > 我们现在的底栏的那种液态玻璃效果,你就直接套用就行了
//
// `SettingsGesturePill` 被**手势配置复用**：
// ```text
// SettingsGestureChoice  → Wrap( for o in options) SettingsGesturePill(...) )
// 主题区块                → Wrap( for m in AppThemeMode.values) SettingsGesturePill(...) )
// ```
// 改 pill 本身 → **手势配置那几处也会跟着变玻璃**，而用户只要求改「主题」。
//
// 而且就算想改 pill，**结构也不对**：用户要的是「跟底栏一样」
// = 一条玻璃 + 一个选中药丸（见 `my_shelf.dart:330-360` 记的教训：
// "看起来不像"时**先怀疑结构，不要先调参数**）。
//
// → 所以**只包容器**：外层一块 `GlassContainer`，
//   `SettingsGesturePill` 保持原样（选中态仍是它自己的高亮）。
//
// ⚠️ 这与追更页的处理**故意不同**：追更页那三个 tab 是页面级主导航
//    （用户明确要求"套用底栏"），所以做了完整的两层结构；
//    这里的 pill 复用度高、又是次要设置项，只包容器是
//    **收益最大、侵入最小**的选择。

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../app_theme.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '主题',
      subtitle: '跟随系统 / 浅色 / 深色',
      children: [
        SettingsBlock(
          title: '主题',
          trailing: Text(
            AppTheme.mode.label,
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            GlassContainer(
              // 胶囊形 —— 与底栏同一个形状语言
              shape: const LiquidRoundedSuperellipse(borderRadius: 999),
              // 与底栏同一档（包文档：95% 场景的正确选择）
              quality: GlassQuality.standard,
              /*
               * ⚠️ `padding: Sp.x2` —— 让 pill 与玻璃边缘留呼吸空间。
               *
               * 不能省：`GlassContainer` 的玻璃效果作用在**边缘**，
               * pill 紧贴边缘会让选中高亮压住玻璃的折射带，
               * 看起来像"玻璃没生效"。
               *（`my_shelf` 用的是 4px，同样是这个道理。）
               */
              padding: const EdgeInsets.all(Sp.x2),
              child: Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  for (final m in AppThemeMode.values)
                    SettingsGesturePill(
                      text: m.label,
                      selected: AppTheme.mode == m,
                      onTap: () => _pick(context, m),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x3),
            Text(
              '「跟随系统」会随系统明暗偏好自动切换（无需重启）。',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 切换主题
  ///
  /// ★ 必须通知顶层重建（2026-09-24）
  ///
  /// `MaterialApp` 在树的**最顶层**，而本页在很深的子树里 ——
  /// 没有共同的 State 可提升。用全局 `ValueNotifier` 通知
  /// （原版是 Vue 的 `ref` 响应式，改了就自动重渲染）。
  ///
  /// ⚠️ 只 `setState` 只会重画**本页** ——
  ///    底栏、标题栏、所有已缓存的页面都不会变色。
  ///
  /// ⚠️ 搬进二级页后**多了一层**：`SettingsSubPage` 是 `StatelessWidget`，
  ///    所以这里用 `Navigator` 之外的方式触发重建 —— 直接调全局
  ///    `notifyThemeChanged()`（它驱动 `MaterialApp` 那一层重建，
  ///    二级页作为其子树自然跟着重建）。**不需要**本页自己 `setState`。
  void _pick(BuildContext context, AppThemeMode m) {
    AppTheme.setMode(m);
    notifyThemeChanged();
  }
}
