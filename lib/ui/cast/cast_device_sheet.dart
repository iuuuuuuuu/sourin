// ═══════════════════════════════════════════════════════════════════════
//  投屏设备发现面板 —— task-27
// ═══════════════════════════════════════════════════════════════════════
//
// 一个模态底部弹窗：打开即扫，列出能投的设备，点一台就返回它。
//
// # 三种空态必须分清（本项目铁律：没有的能力不假装有）
//
// ```text
//   ① 搜索请求根本没发出去   → 说"网络不可用/权限"，让用户去查网络
//   ② 发出去了但一台都没回   → 说"没找到设备"，提示同一个 Wi-Fi + 电视开投屏
//   ③ 搜到了但都不能投屏     → ★ 把设备**列出来**并说明原因
// ```
// ③ 是最容易做错的一个：把"搜到一台 NAS"直接吞掉、只显示"没找到设备"，
// 用户会以为是自己电视的问题，反复折腾。列出来才能一眼看出搜到的是谁。

import 'package:material_ui/material_ui.dart';

import '../../core/dlna/cast_manager.dart';
import '../../core/dlna/dlna_http.dart';
import '../tokens.dart';
import '../widgets/overlay_motion.dart';

/// 打开设备选择弹窗；用户选了返回那台设备，取消返回 null
Future<CastDevice?> showCastDeviceSheet(
  BuildContext context, {
  required CastManager manager,
  String? subtitle,
}) {
  return showModalBottomSheet<CastDevice>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    /*
     * ★ task-99：原来不传 ⇒ 吃 material 默认的 250ms/200ms，
     *   与本项目的 token 不一致（弹层比页面切换还慢）。
     *   现在入场 Motion.base(260ms) + Motion.easeOut、
     *   退场 Motion.fast(150ms) —— 见 overlaySheetAnimationStyle 的说明。
     */
    sheetAnimationStyle: overlaySheetAnimationStyle(context),
    builder: (_) => _CastDeviceSheet(manager: manager, subtitle: subtitle),
  );
}

class _CastDeviceSheet extends StatefulWidget {
  const _CastDeviceSheet({required this.manager, this.subtitle});

  final CastManager manager;

  /// 副标题（"即将投屏：第 3 集"）
  final String? subtitle;

  @override
  State<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<_CastDeviceSheet> {
  bool _scanning = true;
  CastScan? _scan;
  String? _error;

  /// 扫描期间用户可能已经把弹窗关了 —— 异步回来后必须先看这个
  bool _alive = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _alive = false;
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final r = await widget.manager.discover();
      if (!_alive) return;
      setState(() {
        _scan = r;
        _scanning = false;
      });
    } catch (e) {
      if (!_alive) return;
      setState(() {
        _error = '搜索投屏设备失败：$e';
        _scanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.72),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.xl),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _grabber(colors),
              _header(colors),
              Flexible(child: _body(colors)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grabber(ColorScheme colors) => Padding(
    padding: const EdgeInsets.only(top: Sp.x3),
    child: Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: colors.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: Radii.rFull,
        ),
      ),
    ),
  );

  Widget _header(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x3, Sp.x2),
    child: Row(
      children: [
        Icon(Icons.cast, size: 20, color: colors.primary),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '投屏到设备',
                style: TextStyle(
                  fontSize: FontSizes.lg,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    widget.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: _scanning ? null : _run,
          icon: const Icon(Icons.refresh, size: 20),
          tooltip: '重新搜索',
          visualDensity: VisualDensity.compact,
          color: colors.onSurfaceVariant,
        ),
      ],
    ),
  );

  Widget _body(ColorScheme colors) {
    if (_scanning) return _scanningView(colors);
    final err = _error;
    if (err != null)
      return _message(colors, Icons.error_outline, err, retry: true);
    final s = _scan;
    if (s == null)
      return _message(colors, Icons.error_outline, '没有拿到搜索结果', retry: true);

    if (s.devices.isEmpty && s.unsupported.isEmpty) {
      // ★ 区分"没发出去"与"发出去没人回"
      if (!s.scan.anySent) {
        return _message(
          colors,
          Icons.wifi_off,
          '没能发出搜索请求（可能是 Wi-Fi 没开或权限被限制）。'
          '${s.scan.errors.isEmpty ? '' : s.scan.errors.first}',
          retry: true,
        );
      }
      return _message(
        colors,
        Icons.search_off,
        '没有找到投屏设备。\n'
        '请确认：电视和手机在同一个 Wi-Fi；电视上已打开「投屏 / 无线显示 / DLNA」；'
        '电视没有处于休眠。',
        retry: true,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(Sp.x3, 0, Sp.x3, Sp.x5),
      shrinkWrap: true,
      children: [
        for (final d in s.devices) _deviceTile(colors, d),
        if (s.unsupported.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x2, Sp.x4, Sp.x2, Sp.x2),
            child: Text(
              '搜到但不能投屏（${s.unsupported.length} 台）',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          for (final d in s.unsupported) _unsupportedTile(colors, d),
        ],
      ],
    );
  }

  Widget _scanningView(ColorScheme colors) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Sp.x10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        const SizedBox(height: Sp.x4),
        Text(
          '正在搜索局域网里的投屏设备…',
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Sp.x1),
        Text(
          '（约 4 秒）',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget _message(
    ColorScheme colors,
    IconData icon,
    String text, {
    bool retry = false,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x6, Sp.x5, Sp.x10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 34, color: colors.onSurfaceVariant),
        const SizedBox(height: Sp.x3),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: FontSizes.sm,
            height: 1.5,
            color: colors.onSurfaceVariant,
          ),
        ),
        if (retry) ...[
          const SizedBox(height: Sp.x4),
          TextButton.icon(
            onPressed: _run,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('再搜一次'),
          ),
        ],
      ],
    ),
  );

  Widget _deviceTile(ColorScheme colors, CastDevice d) => Padding(
    padding: const EdgeInsets.only(bottom: Sp.x2),
    child: Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: Radii.rMd,
      child: InkWell(
        borderRadius: Radii.rMd,
        onTap: () => Navigator.of(context).pop(d),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: Sp.x3,
          ),
          child: Row(
            children: [
              Icon(Icons.tv, size: 22, color: colors.primary),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: FontSizes.base,
                        fontWeight: FontWeights.regular,
                        color: colors.onSurface,
                      ),
                    ),
                    if (d.model.isNotEmpty)
                      Text(
                        d.model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                d.host,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// 搜到但不能投的设备 —— **灰的但可点开看原因**
  Widget _unsupportedTile(ColorScheme colors, CastDevice d) => Padding(
    padding: const EdgeInsets.only(bottom: Sp.x2),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.22),
        borderRadius: Radii.rMd,
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.tv_off, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  d.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Text(
                  d.why,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          Text(
            hostOf(d.location),
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}
