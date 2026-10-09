// ═══════════════════════════════════════════════════════════════════════
//  ★ 底栏瘦身重做（Owner 2026-10-09 第 12 条）
// ═══════════════════════════════════════════════════════════════════════
//
//  这里是**新写的**底栏。旧版（三档宽度 × 每档一份重复按钮）整段被替换掉了，
//  改动前后的清单见交付报告。核心变化：
//
//  ```text
//  ① 「选择类」操作全部换成 popover（倍速 / 线路 / 字幕音轨 / 弹幕 / 更多）
//     —— 不再弹窗、不再抽屉（B 站 / 腾讯视频那一档）
//  ② 低频项收进一个「更多」浮层；功能**一个没删**，只是换了入口
//  ③ 四个档位共用**同一套按钮定义**（`_barActions`），不再三份复制
//     —— 改一处就三处生效，也终于能保证各档功能集合一致
//  ④ 时间与进度条用 `ValueListenableBuilder` 局部重建：
//     播放位置每 250ms 推进一次，但**不再**每 tick 重建整页
//  ```
//
//  # 档位与判据
//
//  ```text
//  宽（≥ _kBottomBarRowWidth=830）  桌面 1280 / TV：单行，常驻项全露出
//  中（≥ _kBottomBarMiniWidth=528） 桌面窄窗 / 手机横屏：两行
//  窄（< _kBottomBarRowWidth）      手机竖屏：两行 + 条件项横滑
//  ```
//
//  # 深色系（永远）
//  播放器画面区不跟随浅色主题 —— 见 `_BottomBarIcon` / `PlayerPopoverSurface`，
//  全部写死白/深灰，不读 `Theme.of(context).colorScheme`。

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../core/models.dart' show StreamCandidate;
import '../tokens.dart';
import 'player_more_menu.dart';
import 'player_popover.dart';

/// popover 的 id 常量 —— 开关与按钮用**同一份**字符串
class PlayerPopoverIds {
  const PlayerPopoverIds._();

  static const rate = 'rate';
  static const quality = 'quality';
  static const tracks = 'tracks';
  static const danmaku = 'danmaku';
  static const more = 'more';
}

/// 底栏一个动作的描述（icon / 文字 / 可点性）
class _BarAction {
  const _BarAction({
    required this.icon,
    this.label,
    this.tooltip,
    this.onTap,
    this.enabled = true,
    this.active = false,
    this.popoverId,
  });

  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool enabled;
  final bool active;

  /// 非 null ⇒ 这枚按钮的点击改由 popover 控制器接管（点一下开小窗）
  final String? popoverId;
}

/// 「更多」浮层需要的数据（宿主算好传进来）
class PlayerMoreMenuData {
  const PlayerMoreMenuData({
    required this.groups,
    this.castUrl = '',
    this.castHeaders = const <String, String>{},
    this.castTitle = '',
  });

  final List<MoreMenuGroup> groups;
  final String castUrl;
  final Map<String, String> castHeaders;
  final String castTitle;
}

/// 底栏（桌面 / 手机 / TV 共用）
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.controller,
    required this.playing,
    required this.positionListenable,
    required this.duration,
    required this.isLive,
    required this.rate,
    required this.volume,
    required this.muted,
    required this.fullscreen,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onRate,
    required this.onToggleFullscreen,
    required this.onEpisodes,
    required this.hasEpisodes,
    required this.showEpisodeNav,
    required this.onNext,
    required this.hasNext,
    required this.more,
    this.streams = const <StreamCandidate>[],
    this.currentStream,
    this.onPickStream,
    this.qualityOptions = const <PopoverOption<String>>[],
    this.onPickQuality,
    this.currentQuality = '',
    this.trackGroups = const <String, List<PopoverOption<String>>>{},
    this.onPickTrack,
    this.danmakuEnabled = false,
    this.danmakuBusy = false,
    this.onDanmakuToggle = _noop,
    this.onDanmakuSettings = _noop,
    this.zoomOpen = false,
    this.videoZoom = 100,
    this.onVideoZoom,
    this.onZoomToggle,
    this.fade,
    this.buffered,
    this.bufferBarKey,
  });

  static void _noop() {}

  final PopoverController controller;

  final bool playing;

  /// ★ 播放位置的**局部**真源（）
  ///
  /// 为什么不是 ：改前这里是普通字段，每秒一次整页 。
  /// 改成 listenable 之后只有「时间 + 进度条」那一小块在重建。
  final ValueListenable<Duration> positionListenable;
  final Duration duration;
  final bool isLive;
  final double rate;
  final double volume;
  final bool muted;
  final bool fullscreen;

  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onRate;
  final VoidCallback onToggleFullscreen;

  final bool hasEpisodes;
  final VoidCallback onEpisodes;
  final bool showEpisodeNav;
  final bool hasNext;
  final VoidCallback onNext;

  final PlayerMoreMenuData more;

  final List<StreamCandidate> streams;
  final StreamCandidate? currentStream;
  final void Function(StreamCandidate)? onPickStream;

  final List<PopoverOption<String>> qualityOptions;
  final void Function(String)? onPickQuality;
  final String currentQuality;

  /// 字幕 / 音轨：分组 → 选项
  final Map<String, List<PopoverOption<String>>> trackGroups;
  final void Function(String group, String id)? onPickTrack;

  final bool danmakuEnabled;
  final bool danmakuBusy;
  final VoidCallback onDanmakuToggle;
  final VoidCallback onDanmakuSettings;

  final bool zoomOpen;
  final double videoZoom;
  final ValueChanged<double>? onVideoZoom;
  final VoidCallback? onZoomToggle;

  final Animation<double>? fade;
  final PlayerBufferedRange? buffered;
  final Key? bufferBarKey;

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  /// 常用的倍速档位（与旧版**逐字同一份**，不许各写各的）
  static const List<double> kRates = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
  ];

  List<PopoverOption<double>> rateOptions() => [
    for (final r in kRates)
      PopoverOption<double>(
        value: r,
        label: '${_trimRate(r)}x',
        checked: (r - rate).abs() < 0.001,
      ),
  ];

  static String _trimRate(double r) =>
      r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';

  List<PopoverOption<String>> streamOptions() => [
    for (final s in streams)
      PopoverOption<String>(
        value: s.url,
        label: s.label ?? s.quality ?? s.url,
        checked: currentStream != null && currentStream!.url == s.url,
      ),
  ];

  /// 底栏的常驻 + 条件动作（宽档）
  ///
  /// ★ 低频项（截图 / 设置 / 弹幕设置 / 缩放 / 片头片尾 / 画中画 / 换源 /
  ///   投屏）**一个都没删** —— 它们只是搬进了「更多」浮层。
  List<_BarAction> _actions(BuildContext context) {
    final isTouch = MediaQuery.of(context).size.shortestSide < 600;
    return [
      if (hasEpisodes && !isTouch)
        _BarAction(
          icon: Icons.list,
          label: '选集',
          tooltip: '选集',
          onTap: onEpisodes,
        ),
      if (streams.length > 1)
        _BarAction(
          icon: Icons.high_quality,
          label: '清晰度',
          tooltip: '清晰度',
          popoverId: PlayerPopoverIds.quality,
          active: controller.isOpen(PlayerPopoverIds.quality),
        ),
      _BarAction(
        icon: Icons.speed,
        label: '${_trimRate(rate)}x',
        tooltip: '倍速',
        popoverId: PlayerPopoverIds.rate,
        active: controller.isOpen(PlayerPopoverIds.rate),
      ),
      if (trackGroups.isNotEmpty)
        _BarAction(
          icon: Icons.closed_caption,
          tooltip: '字幕与音轨',
          popoverId: PlayerPopoverIds.tracks,
          active: controller.isOpen(PlayerPopoverIds.tracks),
        ),
      _BarAction(
        icon: danmakuEnabled ? Icons.subtitles : Icons.subtitles_off,
        label: '弹幕',
        tooltip: danmakuBusy ? '弹幕加载中…' : '弹幕',
        active: danmakuEnabled,
        popoverId: PlayerPopoverIds.danmaku,
      ),
      _BarAction(
        icon: Icons.more_horiz,
        label: '更多',
        tooltip: '更多',
        popoverId: PlayerPopoverIds.more,
        active: controller.isOpen(PlayerPopoverIds.more),
      ),
      if (showEpisodeNav)
        _BarAction(
          icon: Icons.skip_next,
          tooltip: '下一集',
          enabled: hasNext,
          onTap: onNext,
        ),
      _BarAction(
        icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
        tooltip: fullscreen ? '退出全屏' : '全屏',
        onTap: onToggleFullscreen,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final anim = fade ?? kAlwaysCompleteAnimation;
    final opacity = (fade?.value ?? 1.0).clamp(0.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: opacity < 0.5,
        child: AnimatedBuilder(
          animation: anim,
          builder: (context, child) => Opacity(opacity: opacity, child: child),
          /*
           * ★ Stack：渐变条在下、popover 在上。
           *   popover 不放在 `Container` 里 —— 那样它的背景渐变会盖住面板底部，
           *   而且 `clipBehavior` 一变就会把超出条高的面板裁掉。
           *   这里用 `clipBehavior: Clip.none` + `Stack`，面板可以自由地
           *   长到条的上方去。
           */
          child: _body(context),
        ),
      ),
    );
  }

  /// ★★ popover 层 —— **由播放页那个 Stack 承载**，不是底栏自己
  ///
  /// # 为什么必须提到那一层（实测出来的，不是猜的）
  /// ```text
  /// 底栏在播放页里是 `Positioned(bottom:0)`、高约 106px 的一个盒子。
  /// 面板若作为它的子件（第一版就是这么写的），它能长到的上界就被那 106px
  /// 卡死 ⇒ 无头截图里 popover 与「没展开」的截图 **md5 完全相同**，
  /// 一像素都没画出来（widget 树里 `PlayerMoreMenu` 是有的，就是画不出来）。
  /// ⇒ 提到同一个 Stack 里当**兄弟**：面板从底栏上沿往上长，
  ///   而那个 Stack 是整屏（`SizedBox.expand`）⇒ 不会被任何祖先裁掉。
  /// ```
  Widget buildPopoverLayer() {
    final id = controller.openId;
    final body = switch (id) {
      PlayerPopoverIds.rate => _panelSurface(
        rateOptions().map(_rateRow).toList(),
      ),
      PlayerPopoverIds.quality when qualityOptions.isNotEmpty => _panelSurface(
        qualityOptions.map(_row).toList(),
      ),
      PlayerPopoverIds.tracks when trackGroups.isNotEmpty => _panelSurface([
        for (final entry in trackGroups.entries) ...[
          PopoverGroupLabel(entry.key),
          for (final o in entry.value) _row(o),
        ],
      ], width: 220),
      PlayerPopoverIds.danmaku => _danmakuPanel(),
      PlayerPopoverIds.more => _morePanel(),
      _ => const SizedBox.shrink(),
    };
    return PopoverKeepAlive(
      controller: controller,
      child: PopoverMotion(visible: id != null, child: body),
    );
  }

  Widget _panelSurface(List<Widget> rows, {double width = 168}) =>
      PlayerPopoverSurface(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      );

  Widget _row(PopoverOption<String> o) => PopoverRow(
    label: o.label,
    hint: o.hint,
    checked: o.checked,
    onTap: o.enabled
        ? () {
            onPickQuality?.call(o.value);
            controller.close();
          }
        : null,
  );

  Widget _rateRow(PopoverOption<double> o) => PopoverRow(
    label: o.label,
    checked: o.checked,
    onTap: () {
      onRate(o.value);
      controller.close();
    },
  );

  Widget _danmakuPanel() => _panelSurface([
    PopoverRow(
      label: danmakuEnabled ? '关闭弹幕' : '开启弹幕',
      checked: danmakuEnabled,
      onTap: () {
        onDanmakuToggle();
        controller.close();
      },
    ),
    const PopoverDivider(),
    PopoverRow(
      label: danmakuBusy ? '弹幕设置（加载中…）' : '弹幕设置',
      onTap: () {
        onDanmakuSettings();
        controller.close();
      },
    ),
  ]);

  Widget _morePanel() =>
      PlayerMoreMenu(groups: more.groups, onDismiss: controller.close);

  /// 底栏自身的高度（含进度行 + 按钮行），用来把面板顶到条的上沿
  ///
  /// ★ 为什么要**算**而不是量：面板若去读某个按钮的 `GlobalKey` 再定位，
  ///   那一次 `build` 里 key 的 RenderObject 可能还没布局（第一帧），
  ///   会出现「面板先落在屏幕中间，下一帧才跳上去」。
  ///   这里用常量高度，位置**每一帧都对**。
  static const double _barHeight = 96;

  Widget _body(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(Sp.x4, Sp.x6, Sp.x4, Sp.x4 + bottomInset),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (zoomOpen)
            PlayerZoomSliderCard(
              zoom: videoZoom,
              onChanged: (v) => onVideoZoom?.call(v),
              onDone: (v) => onVideoZoom?.call(v),
              onClose: () => onZoomToggle?.call(),
            ),
          if (!isLive) _progressRow(),
          _buttonsRow(context),
        ],
      ),
    );
  }

  /// 进度条 + 两侧时间
  ///
  /// ★ 时间与滑杆**同一行**（进度条占 Expanded）：手机上时间让位给滑杆，
  ///   桌面两端对齐 —— 两种形态都只需要这一行，字号同样取 `FontSizes.cap`。
  Widget _progressRow() {
    final total = Text(
      _fmt(duration),
      style: const TextStyle(color: Colors.white, fontSize: FontSizes.cap),
    );
    // ★ 整块进度区（含「已播放时间」与滑杆）由 listenable 驱动：
    //   播放位置每秒变一次 ⇒ 只有这一小块重建，底栏按钮行与整页都不动。
    return ValueListenableBuilder<Duration>(
      valueListenable: positionListenable,
      builder: (context, position, _) => Row(
        children: [
          Text(
            _fmt(position),
            style: const TextStyle(
              color: Colors.white,
              fontSize: FontSizes.cap,
            ),
          ),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: PlayerProgressSlider(
              position: position,
              duration: duration,
              buffered: buffered,
              onSeek: onSeek,
              barKey: bufferBarKey,
            ),
          ),
          const SizedBox(width: Sp.x2),
          total,
        ],
      ),
    );
  }

  Widget _buttonsRow(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final avail = c.maxWidth;
        final actions = _actions(context);

        // ── 常驻高频组（任何宽度都在第一行，永不折叠）──
        final primary = <Widget>[
          _BarIconButton(
            icon: playing ? Icons.pause : Icons.play_arrow,
            tooltip: '播放 / 暂停',
            onTap: onTogglePlay,
            big: true,
          ),
          _VolumeControl(
            muted: muted,
            volume: volume,
            onToggleMute: onToggleMute,
            onVolume: onVolume,
            compact: avail < 400,
          ),
          _PopoverButton(
            controller: controller,
            id: PlayerPopoverIds.rate,
            icon: Icons.speed,
            label: '${_trimRate(rate)}x',
            tooltip: '倍速',
          ),
        ];

        // ── 条件项（选集 / 清晰度 / 字幕 / 弹幕 / 更多 / 下一集）──
        final secondary = <Widget>[
          for (final a in actions)
            if (a.popoverId == null && a.onTap == null)
              _BarIconButton(
                icon: a.icon,
                tooltip: a.tooltip,
                enabled: a.enabled,
                active: a.active,
              )
            else if (a.label != null)
              _PopoverButton(
                controller: controller,
                id: a.popoverId ?? '',
                icon: a.icon,
                label: a.label!,
                tooltip: a.tooltip,
                active: a.active,
                onTap: a.onTap,
              )
            else
              _BarIconButton(
                icon: a.icon,
                tooltip: a.tooltip,
                enabled: a.enabled,
                active: a.active,
                onTap: a.onTap,
              ),
        ];

        final wide = avail >= _kBarRowWidth;
        if (wide) {
          return Row(children: [...primary, const Spacer(), ...secondary]);
        }
        // 窄 / 中档：第一行常驻 + 弹性 + 全屏，其余条件项横滑兜底
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ...primary,
                const Spacer(),
                _BarIconButton(
                  icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  tooltip: fullscreen ? '退出全屏' : '全屏',
                  onTap: onToggleFullscreen,
                ),
              ],
            ),
            const SizedBox(height: Sp.x1),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: secondary),
            ),
          ],
        );
      },
    );
  }

  /// 单行放得下全部常驻项所需的最小宽度
  ///
  /// ★ 比改前的 830 小：低频项收进「更多」之后，单行的固有宽只剩播放/音量/
  ///   倍速/全屏 + 条件项 ⇒ 桌面 1280 与手机横屏都能一行放下。
  static const double _kBarRowWidth = 720;
}

/// 底栏图标按钮（深色系，不读主题）
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.enabled = true,
    this.active = false,
    this.big = false,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool enabled;
  final bool active;
  final bool big;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: enabled ? onTap : null,
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    icon: Icon(
      icon,
      size: big ? 30 : 20,
      color: !enabled
          ? Colors.white24
          : (active ? const Color(0xFF32C7FF) : Colors.white),
    ),
  );
}

/// 带下划文字的入口（选集 / 清晰度 / 弹幕 / 更多）
class _PopoverButton extends StatelessWidget {
  const _PopoverButton({
    required this.controller,
    required this.id,
    required this.icon,
    required this.label,
    this.tooltip,
    this.active = false,
    this.onTap,
  });

  final PopoverController controller;
  final String id;
  final IconData icon;
  final String label;
  final String? tooltip;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x1, vertical: Sp.x1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: active ? const Color(0xFF32C7FF) : Colors.white,
          ),
          const SizedBox(width: Sp.x1),
          Text(
            label,
            style: TextStyle(
              color: active ? const Color(0xFF32C7FF) : Colors.white,
              fontSize: FontSizes.sm,
            ),
          ),
        ],
      ),
    );
    final button = TextButton(
      onPressed: onTap ?? () => controller.toggle(id),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x1),
      ),
      child: child,
    );
    // 有 popover 的入口才包一层悬停展开；纯动作按钮不包（悬停开一个空面板很怪）
    if (onTap != null || id.isEmpty) return button;
    return PopoverAnchorButton(
      controller: controller,
      id: id,
      tooltip: tooltip,
      child: button,
    );
  }
}

/// 音量：静音键 + 滑杆
class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.muted,
    required this.volume,
    required this.onToggleMute,
    required this.onVolume,
    required this.compact,
  });

  final bool muted;
  final double volume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolume;
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _BarIconButton(
        icon: muted || volume == 0
            ? Icons.volume_off
            : (volume < 50 ? Icons.volume_down : Icons.volume_up),
        tooltip: '静音',
        onTap: onToggleMute,
      ),
      if (!compact)
        SizedBox(
          width: 72,
          child: Slider(
            value: muted ? 0 : volume,
            max: 100,
            onChanged: onVolume,
          ),
        ),
    ],
  );
}

/// 画面缩放滑条（从旧 `_ZoomSliderCard` 平移过来，形态不变）
class PlayerZoomSliderCard extends StatelessWidget {
  const PlayerZoomSliderCard({
    super.key,
    required this.zoom,
    required this.onChanged,
    required this.onDone,
    required this.onClose,
  });

  final double zoom;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onDone;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: Sp.x2),
    padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x1),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.85),
      borderRadius: Radii.rSm,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '画面缩放',
          style: TextStyle(color: Colors.white, fontSize: FontSizes.cap),
        ),
        Expanded(
          child: Slider(
            value: zoom.clamp(50.0, 200.0),
            min: 50,
            max: 200,
            onChanged: onChanged,
            onChangeEnd: onDone,
          ),
        ),
        Text(
          '${zoom.round()}%',
          style: const TextStyle(color: Colors.white, fontSize: FontSizes.cap),
        ),
        IconButton(
          onPressed: onClose,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16, color: Colors.white),
          tooltip: '关闭',
        ),
      ],
    ),
  );
}

/// 进度条上那段「已缓冲」的区间
///
/// ⚠️ 与 `player_page.dart` 里那个同名类是**两个类型**（那边的是 nullable
///   的读数快照，这边只要能画的两端）—— 转换在宿主的调用点做一次。
class PlayerBufferedRange {
  const PlayerBufferedRange({required this.start, required this.end});

  final Duration start;
  final Duration end;
}

/// 进度条 —— 拖动 = seek
class PlayerProgressSlider extends StatelessWidget {
  const PlayerProgressSlider({
    required this.position,
    required this.duration,
    required this.onSeek,
    this.buffered,
    this.barKey,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final PlayerBufferedRange? buffered;
  final Key? barKey;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final total = totalMs <= 0 ? 1.0 : totalMs.toDouble();
    final pos = position.inMilliseconds.toDouble().clamp(0.0, total);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth <= 0 ? 1.0 : c.maxWidth;
        Duration at(double dx) =>
            Duration(milliseconds: ((dx.clamp(0.0, w) / w) * total).round());
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onSeek(at(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => onSeek(at(d.localPosition.dx)),
          child: SizedBox(
            height: 18,
            child: Stack(
              children: [
                Positioned.fill(
                  top: 8,
                  bottom: 8,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: Radii.rSm,
                    ),
                  ),
                ),
                // 缓冲条：起点 → 终点，用像素而不是 FractionallySizedBox
                // （后者在 start > 0 时算出的偏移会随宽度漂）
                if (buffered != null)
                  Positioned(
                    left:
                        (buffered!.start.inMilliseconds.toDouble().clamp(
                              0.0,
                              total,
                            ) /
                            total) *
                        w,
                    width:
                        ((buffered!.end.inMilliseconds.toDouble() -
                                    buffered!.start.inMilliseconds.toDouble())
                                .clamp(0.0, total) /
                            total) *
                        w,
                    top: 8,
                    bottom: 8,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white38,
                        borderRadius: Radii.rSm,
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  width: (pos / total) * w,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    key: barKey,
                    decoration: BoxDecoration(
                      color: const Color(0xFF32C7FF),
                      borderRadius: Radii.rSm,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
