// ═══════════════════════════════════════════════════════════════════════
//  投屏入口按钮 + 投屏中状态条 —— task-27
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件是给别的页面「接一根线」用的（自包含）
//
// ```dart
// // 播放页只要加这一行（url = 当前播放地址，headers = 防盗链头）
// CastButton(url: url, headers: headers, title: '第 3 集');
// ```
//
// 按钮自己负责：设备选择弹窗 → 下发 → 把结果如实告诉用户 → 显示投屏中状态。
// **调用方不需要管 CastManager**（内部用全局单例，理由见 cast_manager.dart）。
//
// # 三态按钮（★ 每一态都不能骗人）
//
// ```text
//   空闲      灰色 cast 图标          点 → 选设备
//   投屏中    高亮 + 设备名           点 → 打开投屏中面板（暂停/停止）
//   失败      cast 图标 + 错误提示    点 → 重试（不残留「投屏中」假状态）
// ```
//
// ⚠️ 本项目铁律：**不做假状态**。SetAVTransportURI 成功但 Play 失败时，
//    按钮绝不能显示成「投屏中」—— 电视那边根本没在播。

import 'package:material_ui/material_ui.dart';

import '../../core/dlna/cast_manager.dart';
import '../tokens.dart';
import '../widgets/overlay_motion.dart';
import 'cast_device_sheet.dart';

// ═══════════════════════════════════════════════════════════════════════
//  按钮
// ═══════════════════════════════════════════════════════════════════════

/// 投屏入口按钮
///
/// [url] 是**原始播放地址**（不要预先替换成代理地址 —— 代理由本组件按需建）。
/// [headers] 是防盗链头（B 站类源必须给 Referer，否则电视拉到 403）。
class CastButton extends StatefulWidget {
  const CastButton({
    super.key,
    required this.url,
    this.headers = const {},
    this.title = '',
    this.iconSize = 22,
    this.showLabel = false,
    this.onLog,
  });

  /// 原始播放地址（http/https）
  final String url;

  /// 注入给上游的附加头
  final Map<String, String> headers;

  /// 标题（DIDL 元数据里显示在电视上的名字；也用作代理日志标签）
  final String title;

  final double iconSize;

  /// true 时按钮右边显示「投屏」两个字（横屏/大屏用）
  final bool showLabel;

  /// 调试日志（接 logcat / debugPrint）
  final void Function(String line)? onLog;

  @override
  State<CastButton> createState() => _CastButtonState();
}

class _CastButtonState extends State<CastButton> {
  CastManager get _m => sharedCastManager;

  CastSession? _session;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _m.onLog ??= widget.onLog;
    _session = _m.session;
  }

  /// 点按钮
  Future<void> _onTap() async {
    if (_busy) return;
    final s = _session;
    if (s != null && s.active) {
      await _openActiveSheet(s);
      return;
    }
    await _startCast();
  }

  /// 选设备 → 投
  Future<void> _startCast() async {
    if (!mounted) return;
    // ★ 先校验地址：本地文件 / magnet / rtsp 投过去只会让电视报 716，
    //   不如在按钮这里就说清楚。
    if (!(widget.url.startsWith('http://') ||
        widget.url.startsWith('https://'))) {
      _toast('这个地址不能投屏（只支持 http/https）');
      return;
    }
    setState(() => _busy = true);
    try {
      final d = await showCastDeviceSheet(
        context,
        manager: _m,
        subtitle: widget.title.isEmpty ? null : '即将投屏：${widget.title}',
      );
      if (d == null) {
        // 用户自己取消的，不是错误 —— 什么都不说
        return;
      }
      if (!mounted) return;
      final s = await _m.cast(
        d,
        widget.url,
        headers: widget.headers,
        title: widget.title.isEmpty ? '投屏' : widget.title,
      );
      if (!mounted) return;
      setState(() {
        _session = s;
        _busy = false;
      });
      // ★ 失败必须把设备的原话说出来（「设备拒绝了投屏地址：设备打不开这个地址…」）
      if (s.phase == CastPhase.failed) {
        _toast(s.error ?? '投屏失败');
      } else {
        _toast('已投到 ${s.device.name}');
      }
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  /// 投屏中面板
  Future<void> _openActiveSheet(CastSession s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      // ★ task-99：与 showCastDeviceSheet 同一套时长（见 overlaySheetAnimationStyle）
      sheetAnimationStyle: overlaySheetAnimationStyle(context),
      builder: (_) => _CastActiveSheet(session: s),
    );
    if (action == null || !mounted) return;
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'pause':
          final n = await _m.pause();
          if (n != null && n.phase == CastPhase.failed)
            _toast(n.error ?? '暂停失败');
        case 'resume':
          final n = await _m.resume();
          if (n != null && n.phase == CastPhase.failed)
            _toast(n.error ?? '继续播放失败');
        case 'stop':
          await _m.stop();
          _toast('已停止投屏');
      }
    } finally {
      if (mounted) {
        setState(() {
          _session = _m.session;
          _busy = false;
        });
      }
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      // 没有 Scaffold 的场合（全屏播放页）也不能静默 —— 落到日志
      widget.onLog?.call('[投屏] $msg');
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final s = _session;
    final active = s != null && s.active;
    final failed = s != null && s.phase == CastPhase.failed;

    final icon = _busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            active ? Icons.cast_connected : Icons.cast,
            size: widget.iconSize,
          );

    final tooltip = _busy
        ? '正在投屏…'
        : active
        ? '投屏中：${s.device.name}'
        : failed
        ? '上次投屏失败：${s.error ?? ''}'
        : '投屏到电视';

    final btn = IconButton(
      onPressed: _busy ? null : _onTap,
      icon: icon,
      tooltip: tooltip,
      iconSize: widget.iconSize,
      visualDensity: VisualDensity.compact,
      color: active
          ? colors.primary
          : failed
          ? colors.error
          : colors.onSurfaceVariant,
    );

    if (!widget.showLabel) return btn;
    return TextButton.icon(
      onPressed: _busy ? null : _onTap,
      icon: icon,
      label: Text(active ? s.device.name : '投屏'),
      style: TextButton.styleFrom(
        foregroundColor: active ? colors.primary : colors.onSurfaceVariant,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  投屏中面板
// ═══════════════════════════════════════════════════════════════════════

/// 返回 'pause' / 'resume' / 'stop' / null（取消）
class _CastActiveSheet extends StatefulWidget {
  const _CastActiveSheet({required this.session});

  final CastSession session;

  @override
  State<_CastActiveSheet> createState() => _CastActiveSheetState();
}

class _CastActiveSheetState extends State<_CastActiveSheet> {
  late CastSession _s;

  @override
  void initState() {
    super.initState();
    _s = widget.session;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final playing = _s.phase == CastPhase.playing;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.xl),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x5, Sp.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.cast_connected, size: 20, color: colors.primary),
                  const SizedBox(width: Sp.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '正在投屏到 ${_s.device.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: FontSizes.base,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                        Text(
                          _stateText(_s),
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Sp.x4),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () =>
                          Navigator.of(context)
                              .pop(playing ? 'pause' : 'resume'),
                      icon: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        size: 18,
                      ),
                      label: Text(playing ? '暂停' : '继续'),
                    ),
                  ),
                  const SizedBox(width: Sp.x3),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop('stop'),
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('停止投屏'),
                    ),
                  ),
                ],
              ),
              if (_s.error != null) ...[
                const SizedBox(height: Sp.x3),
                Text(
                  _s.error!,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// ★ 设备自报的状态优先，没有就用本地状态 —— 但**都不编造**
  static String _stateText(CastSession s) {
    final raw = s.transportState;
    final local = switch (s.phase) {
      CastPhase.playing => '播放中',
      CastPhase.paused => '已暂停',
      CastPhase.connecting => '正在下发…',
      CastPhase.failed => '出错',
      CastPhase.idle => '空闲',
    };
    return raw == null ? local : '$local（设备报告：$raw）';
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  投屏中状态条（给播放页常驻显示用）
// ═══════════════════════════════════════════════════════════════════════

/// 常驻的小条：`[投屏图标] 正在投屏到 客厅电视   [停止]`
///
/// 没有投屏时**不占位置**（返回 `SizedBox.shrink()`），
/// 这样播放页可以无条件把它塞进 Column 里。
class CastStatusBar extends StatefulWidget {
  const CastStatusBar({super.key, this.onStopped});

  /// 用户点了停止之后回调（页面可以据此恢复本地播放）
  final VoidCallback? onStopped;

  @override
  State<CastStatusBar> createState() => _CastStatusBarState();
}

class _CastStatusBarState extends State<CastStatusBar> {
  CastManager get _m => sharedCastManager;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final s = _m.session;
    if (s == null || !s.active) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.10),
          borderRadius: Radii.rMd,
          border: Border.all(color: colors.primary.withValues(alpha: 0.30)),
        ),
        child: Row(
          children: [
            Icon(Icons.cast_connected, size: 16, color: colors.primary),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                '正在投屏到 ${s.device.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurface,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                await _m.stop();
                widget.onStopped?.call();
                if (mounted) setState(() {});
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: colors.primary,
              ),
              child: const Text('停止'),
            ),
          ],
        ),
      ),
    );
  }
}
