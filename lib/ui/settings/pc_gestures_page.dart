// ═══════════════════════════════════════════════════════════════════════
//  二级页：PC 播放手势（2026-09-25 任务 ㉙ 从 settings_page.dart 搬来）
// ═══════════════════════════════════════════════════════════════════════
//
// # 搬运说明（★ 逻辑一字未改，只换宿主）
//
// 原来这段是 `settings_page.dart` 里 `title: 'PC 播放手势'` 那个 `_Block`
// （被 `if (Device.isDesktop)` 包着，见下面"为什么本页也判"）。
//
// # ★ 用户要求（原注释照搬，这是功能的**依据**）
//
// > 而且pc端更直觉的左右按钮 单点是快进快退(可配置)
// > 长按是倍速,右是快进倍速(可配置) 左是 快退(可配置)
//
// ⚠️ 但第一句里的「**单点是快进快退**」后来被用户**推翻**了：
// > **不要单击快进快退,去掉这个功能**   （2026-09-25）
//
// 所以「单击步长」那一项**已经删掉** —— 留着它就是在给一个
// 不存在的功能做配置，用户改了毫无反应，比不显示更糟。
// 现在这块只剩**三项**，全部服务**长按**。
//
// # ★ 为什么本页**仍然**判 `Device.isDesktop`
//
// 入口行在一级页已经用 `if (Device.isDesktop)` 藏起来了，理论上
// 手机上点不到。但：
// ```text
// ① TV / 手机可能通过**遥控器或外部唤起**直接 push 这个路由
//    （本项目有 `tv_nav_probe.dart` 这类路径）
// ② 设置页的 State 可能在 push 之后**重建**（例如主题切换）
//    → 入口行消失，但已经 push 的路由**不会自动弹出**
// ```
// 而这块的所有开关在非桌面端**永远不生效**
// （`PlayerGestures.pcArrowHoldEnabled` 只在 PC 键盘路径被读）。
// 给触摸用户看到一个点了没用的开关，比不显示更糟 —— 所以照原样判。
//
// ⚠️ 与「播放手势」（触摸端那一块）**互斥**：PC 看这块、手机看那块。
//    因为两者的交互形态不同（用户明确要求不要统一）。

import 'package:material_ui/material_ui.dart';

import '../../core/device.dart';
import '../../core/player_gestures.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

class PcGesturesSettingsPage extends StatefulWidget {
  const PcGesturesSettingsPage({super.key});

  @override
  State<PcGesturesSettingsPage> createState() => _PcGesturesSettingsPageState();
}

class _PcGesturesSettingsPageState extends State<PcGesturesSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ⚠️ 非桌面直接给一句说明 —— 见文件头"为什么本页仍然判"。
     *    不用 `SizedBox.shrink()`：那样用户会看到一个**完全空白**的页面，
     *    以为是 bug。给一句话说明"这一页在 PC 上才有内容"。
     */
    if (!Device.isDesktop) {
      return SettingsSubPage(
        title: 'PC 播放手势',
        subtitle: '仅在桌面端可用',
        children: [
          SettingsBlock(
            title: 'PC 播放手势',
            children: [
              Text(
                '这些手势依赖键盘方向键与鼠标，只在桌面端生效 —— '
                '当前设备是触摸端，请到一级页的「播放手势」里配置。',
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      );
    }

    return SettingsSubPage(
      title: 'PC 播放手势',
      subtitle: '键盘方向键 + 鼠标长按',
      children: [
        SettingsBlock(
          title: 'PC 播放手势',
          trailing: Text(
            '键盘 + 鼠标',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
          children: [
            /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 键盘方向键（用户 2026-09-25 明确要求）
             * ══════════════════════════════════════════════════════════
             *
             * > 在pc上,小键盘的左右按键 单击 应该是步数控制,长按是 快进快退
             * > 这两个都是可配置 可关闭的
             *
             * ★ 两个开关**各自独立**（用户强调「这两个配置开关
             *   是单独配置的」）—— 关掉单击不影响长按，反之亦然。
             *   所以它们是**两个独立的 SettingsGestureToggle**，
             *   而不是一个总开关 + 两个子选项。
             */
            SettingsGestureToggle(
              label: '方向键单击：步数控制',
              hint: '左右方向键轻点一下，跳一个步长'
                  '（与下面的长按各自开关）',
              value: PlayerGestures.pcArrowSeekEnabled,
              onChanged: (v) => setState(() {
                PlayerGestures.setPcArrowSeekEnabled(v);
              }),
            ),
            if (PlayerGestures.pcArrowSeekEnabled) ...[
              const SizedBox(height: Sp.x3),
              SettingsGestureChoice<int>(
                label: '方向键单击步长',
                options: PlayerGestures.pcArrowSeekSecondsOptions,
                value: PlayerGestures.pcArrowSeekSeconds,
                labelOf: (v) => '$v 秒',
                onChanged: (v) => setState(() {
                  PlayerGestures.setPcArrowSeekSeconds(v);
                }),
              ),
            ],

            const SizedBox(height: Sp.x5),
            SettingsGestureToggle(
              label: '方向键长按：快进快退',
              hint: '按住右方向键倍速快进、按住左方向键连续快退'
                  '，松开恢复原速',
              value: PlayerGestures.pcArrowHoldEnabled,
              onChanged: (v) => setState(() {
                PlayerGestures.setPcArrowHoldEnabled(v);
              }),
            ),
            if (PlayerGestures.pcArrowHoldEnabled) ...[
              const SizedBox(height: Sp.x3),
              SettingsGestureChoice<double>(
                label: '长按倍率（快进）',
                options: PlayerGestures.pcArrowHoldRateOptions,
                value: PlayerGestures.pcArrowHoldRate,
                labelOf: (v) => '${v}x',
                onChanged: (v) => setState(() {
                  PlayerGestures.setPcArrowHoldRate(v);
                }),
              ),
            ],

            const SizedBox(height: Sp.x5),
            Divider(color: colors.outlineVariant, height: 1),
            const SizedBox(height: Sp.x5),

            SettingsGestureToggle(
              label: '启用左右区域手势',
              /*
               * ⚠️ 文案必须如实 —— 这里原来写的是
               * 「单击左/右侧快退/快进，长按左连续快退、右倍速快进」。
               * 单击那一半已经不存在了，不改的话用户会去点画面
               * 期待跳秒，然后以为"坏了"。
               */
              hint: '鼠标长按左半屏连续快退、长按右半屏倍速快进'
                  '（单击画面为播放/暂停）。'
                  '★ PC 上更常用的是上面的方向键，'
                  '这个鼠标手势可单独关掉',
              value: PlayerGestures.pcButtonsEnabled,
              onChanged: (v) => setState(() {
                PlayerGestures.setPcButtonsEnabled(v);
              }),
            ),
            if (PlayerGestures.pcButtonsEnabled) ...[
              const SizedBox(height: Sp.x4),
              SettingsGestureChoice<double>(
                label: '右半屏长按倍率（快进）',
                options: PlayerGestures.pcForwardRateOptions,
                value: PlayerGestures.pcForwardRate,
                labelOf: (v) => '${v}x',
                onChanged: (v) => setState(() {
                  PlayerGestures.setPcForwardRate(v);
                }),
              ),
              const SizedBox(height: Sp.x4),
              SettingsGestureChoice<int>(
                label: '左半屏长按每步（连续快退）',
                options: PlayerGestures.pcRewindStepOptions,
                value: PlayerGestures.pcRewindStep,
                labelOf: (v) => '$v 秒',
                onChanged: (v) => setState(() {
                  PlayerGestures.setPcRewindStep(v);
                }),
              ),
              const SizedBox(height: Sp.x3),
              Text(
                /*
                 * ★ 如实说明限制（2026-09-24）
                 *
                 * `media_kit` 的 setRate 拒绝非正数，所以左半屏长按
                 * **做不到真正的倒放**。与其让用户以为坏了，
                 * 不如直接写清楚 —— 用户原话里说的"左是快退"，
                 * 我按连续快退实现，并在这里说明。
                 */
                '提示：左半屏长按为「连续快退」（每 0.4 秒退一步）。'
                '底层不支持负倍速，因此无法倒放播放。',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
