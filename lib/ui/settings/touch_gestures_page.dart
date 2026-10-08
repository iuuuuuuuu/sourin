// ═══════════════════════════════════════════════════════════════════════
//  二级页：播放手势（触摸端）—— task-18 ①②（2026-10-04）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独开一页
//
// Owner 原话（m13330，配截图）：
// > 这些功能也可以抄一下
//
// 截图里的 ① 双击快进退秒数、② 长按临时倍速 都是**触摸端**的手势项。
// 它们本来散在一级页 `settings_page.dart` 的「播放手势」`_Block` 里
// （:1996-2077），而那个 `_Block` 只有 `if (Device.isTouchOnly)` 才渲染 ——
// PC 用户完全看不到、也没法配。
//
// 本页把这两项**抽成独立二级页**，好处：
// ```text
// ① 一级页不再堆 70 行手势控件（那一页已经 5400+ 行）
// ② 桌面端也能看到"触摸端有哪些手势项"（走下面的非触摸分支说明）
// ③ 与 PC 手势页（pc_gestures_page.dart）**对称** —— 一端一页
// ```
//
// # ★ 键与读写全部复用 PlayerGestures，本页**不新增任何 prefs 键**
//
// ```text
// ① doubleTapSeconds      player.gesture.doubleTap.seconds   （5/10/15/30）
// ② longPressRate         player.gesture.longPress.rate      （1.5/2/2.5/3）
//   longPressRewindStep   player.gesture.longPress.rewindStep（2/5/10）
// ```
// 也就是说：**在一级页改、在本页改，改的是同一个键**，两边永远一致。
// 这正是一级页注释里说的"手机自己的连续快退每步秒数"（:2059-2065）。
//
// # ★ ② 的 2.5x 是本次新增的档位
//
// `PlayerGestures.longPressRateOptions` 原本是 `[1.5, 2.0, 3.0]`
// （`lib/core/player_gestures.dart:174`），Owner 的截图里要求含 **2.5x**
// ⇒ 改成 `[1.5, 2.0, 2.5, 3.0]`。
// ⚠️ 那个常量是**共享**的，一级页的 `_GestureChoice<double>`
//    （`settings_page.dart:2049-2057`）读的也是它 ⇒ 插进去之后
//    一级页**自动**多出 2.5x 这个药丸，无需改那个文件。
//
// # 为什么本页仍然自己判设备
//
// 与 `pc_gestures_page.dart:59-63` 同款理由：一级页的入口本身可能被
// 别处复用（比如以后放到桌面端），本页必须能**独立**给出正确内容 ——
// 桌面端进来看到的是"这些手势只在触摸端生效"，而不是一堆改了没用的开关。

import 'package:material_ui/material_ui.dart';

import '../../core/device.dart';
import '../../core/player_gestures.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

class TouchGesturesSettingsPage extends StatefulWidget {
  const TouchGesturesSettingsPage({super.key});

  @override
  State<TouchGesturesSettingsPage> createState() =>
      _TouchGesturesSettingsPageState();
}

class _TouchGesturesSettingsPageState extends State<TouchGesturesSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ⚠️ 非触摸端给一句说明，不用 SizedBox.shrink()
     *    —— 空白页会让用户以为坏了（与 pc_gestures_page.dart 同款）。
     */
    if (!Device.isTouchOnly) {
      return SettingsSubPage(
        title: '播放手势',
        subtitle: '仅在触摸端可用',
        children: [
          SettingsBlock(
            title: '播放手势',
            children: [
              Text(
                '双击左右侧、长按左右侧都是触摸手势，只在手机/平板上生效 —— '
                '当前设备是桌面端，请到一级页的「PC 播放手势」里配置方向键与鼠标。',
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
      title: '播放手势',
      subtitle: '双击左右侧 · 长按左右侧',
      children: [
        SettingsBlock(
          title: '播放手势',
          trailing: Text(
            '触摸操作',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
          children: [
            // ────────────────────────────────────────────────────────
            //  ① 双击左右侧快进快退
            // ────────────────────────────────────────────────────────
            SettingsGestureToggle(
              label: '双击左右侧快进快退',
              hint: '左侧快退、右侧快进',
              value: PlayerGestures.doubleTapEnabled,
              onChanged: (v) => setState(() {
                PlayerGestures.setDoubleTapEnabled(v);
              }),
            ),
            if (PlayerGestures.doubleTapEnabled) ...[
              const SizedBox(height: Sp.x3),
              SettingsGestureChoice<int>(
                label: '双击步长',
                options: PlayerGestures.doubleTapOptions,
                value: PlayerGestures.doubleTapSeconds,
                labelOf: (v) => '$v 秒',
                onChanged: (v) => setState(() {
                  PlayerGestures.setDoubleTapSeconds(v);
                }),
              ),
              const SizedBox(height: Sp.x3),
              Text(
                '双击一次就跳这么多秒。四档都是整数秒 —— '
                '固定档位比自由输入更好点中（手机上点中滑杆的代价很高）。',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],

            const SizedBox(height: Sp.x5),
            Divider(color: colors.outlineVariant, height: 1),
            const SizedBox(height: Sp.x5),

            // ────────────────────────────────────────────────────────
            //  ② 长按左右侧倍速播放
            // ────────────────────────────────────────────────────────
            SettingsGestureToggle(
              label: '长按左右两侧：快进快退',
              hint: '按住左侧连续快退、按住右侧倍速快进，松开恢复原速',
              value: PlayerGestures.longPressEnabled,
              onChanged: (v) => setState(() {
                PlayerGestures.setLongPressEnabled(v);
              }),
            ),
            if (PlayerGestures.longPressEnabled) ...[
              const SizedBox(height: Sp.x3),
              SettingsGestureChoice<double>(
                label: '长按右侧倍率（快进）',
                options: PlayerGestures.longPressRateOptions,
                value: PlayerGestures.longPressRate,
                labelOf: (v) => '${v}x',
                onChanged: (v) => setState(() {
                  PlayerGestures.setLongPressRate(v);
                }),
              ),
              const SizedBox(height: Sp.x3),
              Text(
                /*
                 * ★ 如实说明这一档是怎么来的
                 *
                 * Owner 截图里明确要求 1.5x / 2x / **2.5x** / 3x 四档，
                 * 而代码里原本只有 1.5 / 2 / 3 三档 ⇒ 本次补上 2.5。
                 * 写在这里是为了下一个人不用再去翻任务记录。
                 */
                /*
                 * ★ 2026-10-04 订正（Lead 审计 team-message-914508ce【低】第 3 条）：
                 *   这里**原先**写的是「松开立刻回到 1x」—— 与实现矛盾。
                 *   player_page.dart 的 _endLongPressBoost() 恢复的是
                 *   **_rateBeforeLongPress 快照**，不是硬编码的 1.0x
                 *   （用户先设了 1.5x，长按快进抬起后应回到 1.5x）。
                 *   同一设置的另外两个入口（settings_page.dart:2071 /
                 *   settings/pc_gestures_page.dart:139）写的都是「松开恢复原速」。
                 */
                '倍速只在按住期间生效，松开回到你之前设置的播放速度 —— '
                '不会把速度改成 1x。',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Sp.x4),
              SettingsGestureChoice<int>(
                label: '长按左侧每步（连续快退）',
                options: PlayerGestures.longPressRewindStepOptions,
                value: PlayerGestures.longPressRewindStep,
                labelOf: (v) => '$v 秒',
                onChanged: (v) => setState(() {
                  PlayerGestures.setLongPressRewindStep(v);
                }),
              ),
              const SizedBox(height: Sp.x3),
              Text(
                '左半屏长按是「连续快退」——每 0.4 秒退一步，'
                '退一步的秒数就是上面这一档。'
                '底层不支持负倍速，所以做不到真正的倒放。',
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
