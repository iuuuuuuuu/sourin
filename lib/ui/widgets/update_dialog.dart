// ═══════════════════════════════════════════════════════════════════════
//  「有新版本」对话框
// ═══════════════════════════════════════════════════════════════════════
//
// # 交互契约（三种输入都要能用）
// ```text
// 鼠标  : 点按钮
// 触摸  : 同上（按钮 ≥ 48dp 高）
// 遥控器: ↑↓ 移动焦点 / ←→ 切按钮 / 确认键触发
// ```
// ⇒ 用 Material 的 [AlertDialog]（自带焦点与 TV 方向键行为），
//   而不是自绘弹层。

import 'package:material_ui/material_ui.dart';

import '../../core/app_update/app_update_controller.dart';
import '../../core/app_update/install.dart';
import '../../core/app_update/release.dart';
import '../tokens.dart';
import 'app_toast.dart';
import 'release_notes.dart';

/// 显示更新对话框。返回 true 表示用户点了「下载」
Future<bool> showUpdateDialog(
  BuildContext context,
  ReleaseInfo release, {
  required UpdatePlatform platform,
}) async {
  final asset = selectAsset(release, platform);
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => _UpdateDialog(release: release, asset: asset),
  );
  return r ?? false;
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.release, required this.asset});
  final ReleaseInfo release;
  final ReleaseAsset? asset;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final c = AppUpdateController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final d = c.download;
        return AlertDialog(
          title: Text('发现新版本 ${widget.release.version}',
              style: const TextStyle(fontSize: FontSizes.lg)),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.asset == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Sp.x3),
                      child: Text('这个版本没有提供当前设备的安装包，可以到下载页手动获取。',
                          style: TextStyle(
                              fontSize: FontSizes.sm, color: colors.onSurfaceVariant)),
                    )
                  else if (widget.asset!.prettySize.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Sp.x3),
                      child: Text('${widget.asset!.name} · ${widget.asset!.prettySize}',
                          style: TextStyle(
                              fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
                    ),
                  ...buildReleaseNotes(
                    widget.release.notes,
                    linkColor: colors.onSurface,
                  ),
                  if (d.active || d.error != null) ...[
                    const SizedBox(height: Sp.x3),
                    _Progress(d),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后'),
            ),
            TextButton(
              onPressed: () {
                c.ignoreVersion(widget.release.tag);
                Navigator.pop(context, false);
              },
              child: const Text('忽略此版本'),
            ),
            FilledButton(
              onPressed: d.active || widget.asset == null
                  ? null
                  : () async {
                      if (!InstallLaunch.canInstallDirectly) {
                        final msg = await InstallLaunch.openInBrowser(
                            widget.asset!.browserUrl);
                        if (!context.mounted) return;
                        showAppToast(context, msg ?? '请在浏览器里完成更新。');
                        Navigator.pop(context, false);
                        return;
                      }
                      Navigator.pop(context, true);
                    },
              child: Text(d.active ? '下载中…' : '下载更新'),
            ),
          ],
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.d);
  final UpdateDownloadState d;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 用 colorScheme.error 而不是 AppPalette.of(...).error —— 两者取值一致
    //   （theme_bridge.dart 把角色展平进 ColorScheme），而这个对话框从头到尾
    //   用的都是 colorScheme；只把错误色换成色板会变成"一半一半"。
    //   ⚠️ 历史：早先这里试过 AppPalette.of，它当时在 MaterialApp 之外会
    //   **assert 崩掉**；现已改成按 Theme.brightness 兜底（2026-10-10）。
    //   也就是说这里换回 AppPalette 现在也是安全的 —— 留着这条注释是为了
    //   下一个人别再重新踩一次那个坑。
    final danger = colors.error;
    if (d.error != null) {
      return Row(children: [
        Icon(Icons.error_outline, size: 18, color: danger),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(d.error!,
              style: TextStyle(fontSize: FontSizes.sm, color: danger)),
        ),
      ]);
    }
    final pct = d.total > 0 ? '${(d.fraction * 100).toStringAsFixed(0)}%' : '…';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: d.total > 0 ? d.fraction : null),
        const SizedBox(height: Sp.x1),
        Row(
          children: [
            Expanded(
              child: Text('正在下载 $pct',
                  style: TextStyle(
                      fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
            ),
            TextButton(
              onPressed: AppUpdateController.instance.cancelDownload,
              child: const Text('取消', style: TextStyle(fontSize: FontSizes.cap)),
            ),
          ],
        ),
      ],
    );
  }
}