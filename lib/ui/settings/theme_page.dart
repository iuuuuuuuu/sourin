// ═══════════════════════════════════════════════════════════════════════
//  二级页：主题（明暗三态 + 多套调色板 + 外部主题包）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 的两条原话，对应本页的两个区块
//
// > 主题如果可以做多主题就是外部插件式 或者之类的,能做的话就做一下
//
// ⇒ 上半部分「明暗」是原有的跟随系统 / 浅色 / 深色三态（保留，不动）；
//   下半部分「配色」是主题包卡片网格（内置 6 套 + 可导入外部 .json）。
//
// ★ 为什么「明暗」与「配色」是**两个独立区块**而不是合成一个下拉
//
//   把两件事合成一个选择器，用户就配不出"深色 + 日间配色"这种组合，
//   也看不出自己到底改了什么。分开之后：
//   ```text
//   明暗 = 这个界面是亮底还是暗底   （跟着系统的那个开关）
//   配色 = 这个界面的具体颜色        （挑一套皮肤）
//   ```
//
// # 为什么每张卡片都带一个**小预览**而不是只给名字
//
//   主题名是没法比较的（"森绿"和"午夜"哪个好看？）。给出缩略图之后，
//   用户看到的是**结果**。预览用的是主题自己的调色板真色，
//   所以卡片看起来什么样，切过去就是什么样 —— 不会"预览与实物不符"。
//
// # 播放器画面的处理
//
//   播放器画面区域**永远深色**，不跟主题变（与 player agent 的约定）。
//   本页不做任何与播放器相关的事。

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show XFile;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../app_theme.dart';
import '../theme/theme_pack.dart';
import '../tokens.dart';
import '../widgets/app_toast.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  /// 导入时可能出现的警告（缺字段 / 非法值 / 版本过新 …）
  String? _warn;

  /// 手动刷新主题包列表
  ///
  /// ⚠️ 不能靠 `setState` 刷新**应用的主题** —— `MaterialApp` 在树的顶层，
  ///    本页 `setState` 只重画自己（那正是 `notifyThemeChanged()` 存在的理由）。
  ///    这里 `setState` 只是重画**这张列表**，主题生效走全局通知。
  void _reload() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final packs = ThemePackStore.loadAll();
    final selectedId = ThemePackStore.selectedId;
    final picked = ThemePackStore.selectedId.isEmpty
        ? null
        : packs.where((p) => p.id == selectedId).firstOrNull;

    return SettingsSubPage(
      title: '主题',
      subtitle: '明暗与配色分开设置，都即时生效',
      children: [
        // ── 区块 1：明暗（原有的三态，保留液态玻璃）──────────────────────
        SettingsBlock(
          title: '明暗',
          trailing: Text(
            AppTheme.mode.label,
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            GlassContainer(
              // 胶囊形 —— 与底栏同一个形状语言。
              // ⚠️ 必须包**容器**而不是 pill：`SettingsGesturePill` 被手势配置
              //    复用，改 pill 会让那边也跟着变玻璃，而 Owner 只要求改主题。
              shape: const LiquidRoundedSuperellipse(borderRadius: 999),
              quality: GlassQuality.standard,
              // 让 pill 与玻璃边缘留呼吸空间：玻璃效果作用在**边缘**，
              // pill 紧贴边缘会让选中高亮压住折射带，看起来像"玻璃没生效"。
              padding: const EdgeInsets.all(Sp.x2),
              child: Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  for (final m in AppThemeMode.values)
                    SettingsGesturePill(
                      text: m.label,
                      selected: AppTheme.mode == m,
                      onTap: () => _pickMode(context, m),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x3),
            Text(
              '「跟随系统」会随系统明暗偏好自动切换，无需重启。',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),

        // ── 区块 2：配色（主题包网格）────────────────────────────────────
        SettingsBlock(
          title: '配色',
          trailing: Text(
            picked?.name ?? '默认',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            ThemeGrid(
              packs: packs,
              selectedId: selectedId,
              onPick: (p) => _pickPack(context, p),
              onDelete: (p) => _deletePack(context, p),
            ),
            const SizedBox(height: Sp.x3),
            Row(children: [
              SettingsGesturePill(
                text: '从文件导入',
                selected: false,
                onTap: () => _importFile(context),
              ),
              const SizedBox(width: Sp.x2),
              SettingsGesturePill(
                text: '粘贴 JSON',
                selected: false,
                onTap: () => _pasteJson(context),
              ),
            ]),
            if (_warn != null) ...[
              const SizedBox(height: Sp.x3),
              _Warning(text: _warn!),
            ],
            const SizedBox(height: Sp.x3),
            Text(
              '主题包是��个 JSON 文件，放在「${ThemePackStore.dir.path}」'
              '目录下就能自动出现在上面的列表里。',
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

  /// 切明暗
  ///
  /// ★ 必须通知顶层重建：`MaterialApp` 在树的最顶层，本页在很深的子树里，
  ///   没有共同的 State 可提升。`setState` 只会重画本页 ——
  ///   底栏、标题栏、所有已缓存的页面都不会变色。
  void _pickMode(BuildContext context, AppThemeMode m) {
    AppTheme.setMode(m);
    notifyThemeChanged();
  }

  /// 切配色
  void _pickPack(BuildContext context, ThemePack p) {
    ThemePackStore.select(p.id);
    notifyThemeChanged();
    showAppToast(context, '已切换到「${p.name}」', style: okToastStyle());
  }

  void _deletePack(BuildContext context, ThemePack p) {
    final ok = ThemePackStore.delete(p);
    if (!ok) {
      showAppToast(context, '内置主题不可删除', style: errToastStyle());
      return;
    }
    notifyThemeChanged();
    _reload();
    showAppToast(context, '已删除「${p.name}」');
  }

  Future<void> _importFile(BuildContext context) async {
    // ⚠️ 选文件器在 Linux/部分环境下不可用；捕获异常并提示，
    //    不要让"没装那个平台插件"变成"点一下就崩"。
    XFile? pickedFile;
    try {
      pickedFile = await openFile(acceptedTypeGroups: [
        const XTypeGroup(label: '主题包', extensions: ['json']),
      ]);
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '无法打开文件选择器：$e', style: errToastStyle());
      return;
    }
    if (pickedFile == null || !mounted) return;
    final r = ThemePackStore.importFromFile(pickedFile);
    notifyThemeChanged();
    _reload();
    _applyImport(context, r, pickedFile.path);
  }

  Future<void> _pasteJson(BuildContext context) async {
    final ctl = TextEditingController();
    final src = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴主题包 JSON'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: ctl,
            maxLines: 10,
            minLines: 6,
            decoration: const InputDecoration(
              hintText: '{\n  "name": "我的主题",\n  "brightness": "dark",\n'
                  '  "colors": { "primary": "#8ED9A8" }\n}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (src == null || !mounted) return;
    final r = ThemePackStore.importFromString(src);
    notifyThemeChanged();
    _reload();
    _applyImport(context, r, '粘贴的 JSON');
  }

  /// 导入后的反馈：**先说清楚发生了什么，再说成功/失败**
  ///
  /// ⚠️ 之所以要分开：一份缺字段的主题包是**可用**的（缺的用默认值），
  ///   如果只弹「导入成功」，用户会以为每个字段都按他写的生效了。
  void _applyImport(BuildContext context, ThemePackResult r, String from) {
    setState(() => _warn = r.warnings.isEmpty ? null : r.warnings.join('\n'));
    if (r.warnings.isEmpty) {
      showAppToast(context, '已导入「${r.pack.name}」', style: okToastStyle());
    } else {
      // 有警告但仍可用 —— 明确说"已导入 + 有 N 处被忽略"
      showAppToast(
        context,
        '已导入「${r.pack.name}」，但有 ${r.warnings.length} 处被忽略',
        style: errToastStyle(),
      );
    }
    debugPrint('[THEME] 从 $from 导入：${r.warnings.join(' / ')}');
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  主题卡片网格
// ═══════════════════════════════════════════════════════════════════════

class ThemeGrid extends StatelessWidget {
  const ThemeGrid({
    required this.packs,
    required this.selectedId,
    required this.onPick,
    required this.onDelete,
    super.key,
  });

  final List<ThemePack> packs;
  final String selectedId;
  final ValueChanged<ThemePack> onPick;
  final ValueChanged<ThemePack> onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // 每张卡至少 190 宽，一行放得下几张就放几张。
        // ⚠️ 必须按**实际可用宽度**算，不能写死列数 —— 桌面 1440 与
        //    手机 412 能放下的张数差 3 倍多，写死必然在某一端溢出。
        const minCard = 190.0;
        final w = box.maxWidth;
        final cols = (w / minCard).floor().clamp(1, 5);
        final gap = Sp.x2;
        final cardW = (w - gap * (cols - 1)) / cols;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final p in packs)
              SizedBox(
                width: cardW,
                child: ThemeCard(
                  pack: p,
                  selected: p.id == selectedId,
                  onTap: () => onPick(p),
                  onDelete: p.builtin ? null : () => onDelete(p),
                ),
              ),
          ],
        );
      },
    );
  }
}

class ThemeCard extends StatelessWidget {
  const ThemeCard({
    required this.pack,
    required this.selected,
    required this.onTap,
    this.onDelete,
    super.key,
  });

  final ThemePack pack;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: '${pack.name}（${pack.brightness == Brightness.dark ? '深色' : '浅色'}）',
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rMd,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: Radii.rMd,
            border: Border.all(
              // 选中态用**主色描边**，不靠换底色 —— 换底色会与卡片自己的
              // 预览色打架（预览本来就是那个颜色，看不出变化）。
              color: selected ? cs.primary : cs.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(Sp.x2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Preview(pack: pack, selected: selected),
              const SizedBox(height: Sp.x2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      pack.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  if (onDelete != null)
                    // 命中区域比图标大 —— 16px 的 ✕ 在电视遥控器上点不中
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      child: InkWell(
                        onTap: onDelete,
                        child: Icon(Icons.close, size: 16, color: cs.onSurfaceVariant),
                      ),
                    )
                  else if (selected)
                    Icon(Icons.check, size: 16, color: cs.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卡片里的**真实配色**缩略图
///
/// ⚠️ 刻意不用 `Image`/截图：直接用主题自己的 `AppPalette` 画，
///   所以预览与切换后的实际效果**逐色一致**，且零成本。
class _Preview extends StatelessWidget {
  const _Preview({required this.pack, required this.selected});

  final ThemePack pack;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = pack.palette;
    return Container(
      height: 66,
      decoration: BoxDecoration(
        color: p.background,
        borderRadius: Radii.rSm,
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 顶栏：主色（模拟标题栏 / 强调区域）
          Container(height: 14, color: p.primary),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 左：一张"卡片"
                  Container(
                    width: 34,
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: const BorderRadius.all(Radius.circular(4)),
                      border: Border.all(color: p.border),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 右：两行文字块（正文色 + 次要色）
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(height: 5, color: p.foreground),
                        const SizedBox(height: 4),
                        FractionallySizedBox(
                          widthFactor: 0.62,
                          child: Container(height: 5, color: p.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        // 错误容器色：比实心红淡得多，但仍能一眼认出"有问题"
        color: cs.errorContainer,
        borderRadius: Radii.rSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: cs.onErrorContainer),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: cs.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
