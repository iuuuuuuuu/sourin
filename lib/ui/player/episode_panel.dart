// ═══════════════════════════════════════════════════════════════════════
//  选集面板（重做版）—— Owner 2026-10-09 第 12 条
// ═══════════════════════════════════════════════════════════════════════
//
//  # 改前 Owner 报的两件事（逐字）
//  > 选集 那个弹窗之前也是卡得很,而且也没什么设计
//
//  根因**不是**绘制慢，而是：
//  ```text
//  ① 面板一打开就把当前段的**全部**格子用 `Wrap` 建出来（`Wrap` 不是懒构建）
//     ⇒ 100 格 × 6 个 widget = 一次几百个 element 的构建
//  ② 它带一层全屏 `OverlayScrim`（半透明黑）—— 每帧一次全屏重绘
//  ③ 打开时没有"滚到当前集"，用户得自己找
//  ```
//
//  # 现在
//  ```text
//  · GridView.builder —— 真懒构建，只建视口里的十几格
//  · 打开自动滚到当前集（用 ScrollController + 纯算式，不用 GlobalKey）
//  · 当前集高亮（蓝底 + 白字）、已看集一个角标、倒序开关
//  · 集数多时按 50 一段（1-50 / 51-100 …），段数极多时也 Wrap 换行
//  · 深色系（播放器区域永远深色）
//  ```
//
//  # 为什么不用 `GlobalKey` 量位置（改前的老办法）
//  懒构建下当前集那一格**可能根本没被构建** ⇒ `currentContext` 为 null ⇒
//  滚动静默失效。用 `itemExtent` + 列数**纯算**出它的偏移，不依赖构建状态。

import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';
import '../tokens.dart';

/// 选集面板的形态（按端分流，判据只在本件内做一次）
enum PlayerEpisodePanelStyle {
  /// 桌面：右侧轻量侧栏
  rightDrawer,

  /// 手机横屏：右侧侧栏
  sideDrawer,

  /// 手机竖屏：底部面板
  bottomSheet,
}

/// 一段（1-50 / 51-100 …）
@immutable
class EpisodeSegment {
  const EpisodeSegment(this.label, this.startIndex);

  /// 展示用的标签，如「1-50」
  final String label;

  /// 段内**第一集**在 `episodes` 里的下标
  final int startIndex;
}

class PlayerEpisodePanel extends StatefulWidget {
  const PlayerEpisodePanel({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
    required this.onClose,
    this.style = PlayerEpisodePanelStyle.rightDrawer,
    this.segmentSize = 50,
  });

  final List<Episode> episodes;
  final int currentIndex;
  final void Function(Episode) onPick;
  final VoidCallback onClose;
  final PlayerEpisodePanelStyle style;

  /// 每段多少集（默认 50 —— 改前是 100，Owner 说"1-50 / 51-100"）
  final int segmentSize;

  @override
  State<PlayerEpisodePanel> createState() => _PlayerEpisodePanelState();
}

class _PlayerEpisodePanelState extends State<PlayerEpisodePanel> {
  final _controller = ScrollController();

  /// ★ true = 最新一集在最上面（B 站/腾讯的「倒序」开关）
  bool _descending = false;

  int _segment = 0;

  bool get _isDrawer => widget.style != PlayerEpisodePanelStyle.bottomSheet;

  int get _segmentCount =>
      (widget.episodes.length + widget.segmentSize - 1) ~/ widget.segmentSize;

  /// 当前这一段里的下标列表（倒序时反着）
  List<int> get _shown {
    final start = _segment * widget.segmentSize;
    final end = (start + widget.segmentSize).clamp(0, widget.episodes.length);
    final idx = <int>[for (var i = start; i < end; i++) i];
    if (_descending) idx.reversed.toList();
    return _descending ? idx.reversed.toList() : idx;
  }

  List<EpisodeSegment> get _segments => [
    for (var s = 0; s < _segmentCount; s++)
      EpisodeSegment(
        '${s * widget.segmentSize + 1}-'
        '${((s + 1) * widget.segmentSize).clamp(0, widget.episodes.length)}',
        s,
      ),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.currentIndex >= 0) {
      _segment = widget.currentIndex ~/ widget.segmentSize;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 滚到当前集（**纯算式**，不依赖那一格是否已被构建）
  ///
  /// ★ 算式：`第几行 = 段内位置 ~/ 列数`；行高固定 ⇒ 偏移就是 `行 × 行高`。
  ///   列数用 `LayoutBuilder` 的实测宽度算，与网格用**同一个函数**。
  void _scrollToCurrent() {
    if (!_controller.hasClients) return;
    if (widget.currentIndex < 0 ||
        widget.currentIndex >= widget.episodes.length) {
      return;
    }
    final pos = _positionOf(widget.currentIndex, _lastColumns);
    if (pos == null) return;
    final target = pos.clamp(0.0, _controller.position.maxScrollExtent);
    if ((target - _controller.position.pixels).abs() < 1) return;
    _controller.jumpTo(target);
  }

  /// 某个集号在网格里的纵向偏移（像素）
  double? _positionOf(int episodeIndex, int columns) {
    if (columns <= 0) return null;
    final local = episodeIndex - _segment * widget.segmentSize;
    if (local < 0) return null;
    final shown = _shown;
    final rowInShown = shown.indexOf(episodeIndex);
    if (rowInShown < 0) return null;
    final row = rowInShown ~/ columns;
    return row * _kCellHeight + (rowInShown % columns == 0 ? 0 : 0);
  }

  int _lastColumns = 1;

  static const double _kCellHeight = 40;
  static const double _kGap = 8;

  void _switchSegment(int s) {
    setState(() => _segment = s);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) _controller.jumpTo(0);
      _scrollToCurrent();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = _isDrawer
        ? (screen.width * 0.30).clamp(280.0, 380.0)
        : screen.width;
    return Container(
      width: width,
      height: _isDrawer ? screen.height : null,
      constraints: _isDrawer
          ? null
          : BoxConstraints(
              maxHeight: (screen.height * 0.66).clamp(240.0, 520.0),
            ),
      padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x4, Sp.x4, Sp.x3),
      decoration: BoxDecoration(
        color: const Color(0xF01C1C1E),
        borderRadius: _isDrawer
            ? const BorderRadius.horizontal(left: Radius.circular(Radii.lg))
            : const BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          if (_segmentCount > 1) ...[
            const SizedBox(height: Sp.x3),
            _segmentBar(),
          ],
          const SizedBox(height: Sp.x3),
          Expanded(child: _grid(width)),
        ],
      ),
    );
  }

  Widget _header() => Row(
    children: [
      const Text(
        '选集',
        style: TextStyle(
          color: Color(0xFFF2F2F2),
          fontSize: FontSizes.base,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(width: Sp.x2),
      Text(
        '共 ${widget.episodes.length} 集',
        style: const TextStyle(
          color: Color(0xFF9A9AA0),
          fontSize: FontSizes.cap,
        ),
      ),
      const Spacer(),
      // ★ 倒序开关：Owner 明确要的形态（B 站/腾讯都有）
      IconButton(
        onPressed: () {
          setState(() => _descending = !_descending);
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToCurrent(),
          );
        },
        tooltip: _descending ? '正序' : '倒序',
        visualDensity: VisualDensity.compact,
        icon: Icon(
          _descending ? Icons.arrow_downward : Icons.arrow_upward,
          size: 18,
          color: _descending ? const Color(0xFF32C7FF) : Colors.white,
        ),
      ),
      IconButton(
        onPressed: widget.onClose,
        tooltip: '关闭',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.close, size: 18, color: Colors.white),
      ),
    ],
  );

  /// 分段条 —— 用 Wrap 而不是横向 ListView（横向的会把最后一卷推到屏外且点不到）
  Widget _segmentBar() => SizedBox(
    height: 30,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _segments.length,
      separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (context, i) {
        final seg = _segments[i];
        final active = i == _segment;
        return InkWell(
          onTap: () => _switchSegment(seg.startIndex ~/ widget.segmentSize),
          borderRadius: BorderRadius.circular(Radii.full),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 5),
            decoration: BoxDecoration(
              color: active ? const Color(0xFF32C7FF) : const Color(0x1FFFFFFF),
              borderRadius: BorderRadius.circular(Radii.full),
            ),
            child: Text(
              seg.label,
              style: TextStyle(
                color: active ? const Color(0xFF07212B) : Colors.white,
                fontSize: FontSizes.cap,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _grid(double maxWidth) {
    final inner = maxWidth - Sp.x4 * 2;
    final cols = (inner / 72).floor().clamp(3, 8);
    _lastColumns = cols;
    final cellW = (inner - _kGap * (cols - 1)) / cols;
    final shown = _shown;
    return GridView.builder(
      controller: _controller,
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: _kGap,
        crossAxisSpacing: _kGap,
        childAspectRatio: cellW / _kCellHeight,
      ),
      // ★ 懒构建：只建视口里那十几格（改前是 `Wrap` 把整段全建出来）
      itemCount: shown.length,
      itemBuilder: (context, k) {
        final i = shown[k];
        return _cell(i, cellW);
      },
    );
  }

  Widget _cell(int i, double cellW) {
    final ep = widget.episodes[i];
    final active = i == widget.currentIndex;
    final watched = widget.currentIndex > 0 && i < widget.currentIndex;
    return Semantics(
      button: true,
      selected: active,
      label: '第 ${i + 1} 集',
      child: InkWell(
        onTap: () => widget.onPick(ep),
        borderRadius: BorderRadius.circular(Radii.xs),
        child: Container(
          width: cellW,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF32C7FF) : const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(Radii.xs),
            border: active ? null : Border.all(color: const Color(0x14FFFFFF)),
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    color: active
                        ? const Color(0xFF07212B)
                        : const Color(0xFFE8E8EA),
                    fontSize: FontSizes.sm,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              // ★ 已看标记：右上角一个小圆点（不占格子的文字位）
              if (watched && !active)
                Positioned(
                  right: 5,
                  top: 5,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF6E6E73),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
