// =======================================================================
//  射手字幕（assrt.net）搜索 / 下载 / 挂载面板 —— task-29⑤
// =======================================================================
//
// 形态照 lib/ui/widgets/danmaku_settings_dialog.dart（task-13⑦）：
//   纯状态类（可脱离 UI 单测）+ 由宿主注入回调的 StatefulWidget。
//
// 本文件**不碰播放页**。拿到字幕文件路径后由宿主调用：
//   PlayerPage._loadExternalSubtitle(path)      // lib/ui/player_page.dart:3017
// 详见 .probe/assrt/INTEGRATION.md。
//
// 署名要求：assrt.net 的 API 文档要求署名「字幕服务由 assrt.net 提供」。
// 面板底部固定显示这一行（SubtitleConfig.showAttribution 默认 true）。

import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/assrt/archive.dart';
import '../../core/assrt/assrt_api.dart';
import '../../core/assrt/subtitle_store.dart';
import '../tokens.dart';
import '../widgets/overlay_motion.dart';

/// 面板的纯状态（不依赖 BuildContext —— 可单测）
class SubtitlePanelState {
  SubtitlePanelState({
    this.keyword = '',
    this.busy = false,
    this.status = '',
    this.error,
    this.results = const <AssrtSubtitle>[],
    this.selectedId,
    this.files = const <SubtitleFileRef>[],
    this.mountedPath,
    this.detail,
  });

  final String keyword;
  final bool busy;

  /// 当前阶段的短状态（「正在搜索…」这类），显示在按钮旁
  final String status;

  /// 出错文案（原样给用户看，不吞）
  final String? error;

  final List<AssrtSubtitle> results;

  /// 当前选中的条目 id（点开过详情的那个）
  final String? selectedId;

  /// 已解出并落盘的字幕文件
  final List<SubtitleFileRef> files;

  /// 已经交给播放页挂上的字幕路径
  final String? mountedPath;

  final AssrtSubtitleDetail? detail;

  bool get hasResults => results.isNotEmpty;

  SubtitlePanelState copyWith({
    String? keyword,
    bool? busy,
    String? status,
    String? error,
    bool clearError = false,
    List<AssrtSubtitle>? results,
    String? selectedId,
    List<SubtitleFileRef>? files,
    String? mountedPath,
    AssrtSubtitleDetail? detail,
    bool clearDetail = false,
  }) {
    return SubtitlePanelState(
      keyword: keyword ?? this.keyword,
      busy: busy ?? this.busy,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      results: results ?? this.results,
      selectedId: selectedId ?? this.selectedId,
      files: files ?? this.files,
      mountedPath: mountedPath ?? this.mountedPath,
      detail: clearDetail ? null : (detail ?? this.detail),
    );
  }
}

/// 字幕面板
class SubtitlePanel extends StatefulWidget {
  const SubtitlePanel({
    super.key,
    required this.onClose,
    this.videoTitle = '',
    this.episodeTitle = '',
    this.videoUrl = '',
    this.initialKeyword,
    this.onMount,
    this.config,
    this.client,
    this.fill = true,
  });

  /// 关闭面板
  final VoidCallback onClose;

  /// 当前播放的视频标题（用于自动填关键词 + 生成 videoKey）
  final String videoTitle;
  final String episodeTitle;
  final String videoUrl;

  /// 打开面板时预填的搜索词（不传则用 videoTitle）
  final String? initialKeyword;

  /// 用户点了「挂到当前播放」
  ///
  /// 宿主应当调用 PlayerPage._loadExternalSubtitle(path)。
  /// 不传 = 只下载不挂载（设置页里的独立入口就是这个模式）。
  final void Function(SubtitleFileRef file)? onMount;

  /// 偏好；不传则读 UiPrefs
  final SubtitleConfig? config;

  /// 测试注入
  final AssrtClient? client;

  /// 根节点是否由**本面板**写成 `Positioned.fill`（默认 true，= 既有行为）
  ///
  /// ★ 传 `false` 的唯一场景：宿主用 `SheetExitMotion` 包住本面板
  ///   （退场淡出）。那时面板的父链里多了 `Opacity` / `IgnorePointer`
  ///   （都产生 RenderObject）⇒ 面板**不能再**自己写 `Positioned`
  ///   —— 它只能做 `Stack` 的直接孩子，否则两个 ParentDataWidget 争同一个
  ///   StackParentData ⇒ 抛 `Incorrect use of ParentDataWidget`
  ///   （阻断级教训：`player_page.dart` 的 `_SheetScrim` 类文档）。
  ///   `fill: false` 时定位交给宿主（本面板的 `Center` 撑满有界约束 ⇒
  ///   与 `Positioned.fill` 几何等价）。
  final bool fill;

  @override
  State<SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<SubtitlePanel> {
  late final TextEditingController _ctl;
  late SubtitleConfig _cfg;
  AssrtClient? _client;
  bool _ownsClient = false;
  SubtitlePanelState _st = SubtitlePanelState();

  String get _videoKey => SubtitleStore.videoKey(
    title: widget.videoTitle,
    episodeTitle: widget.episodeTitle,
    url: widget.videoUrl,
  );

  @override
  void initState() {
    super.initState();
    _cfg = widget.config ?? SubtitleConfig.fromPrefs();
    final kw = (widget.initialKeyword ?? '').trim().isNotEmpty
        ? widget.initialKeyword!.trim()
        : (_cfg.lastKeyword.trim().isNotEmpty
              ? _cfg.lastKeyword.trim()
              : widget.videoTitle.trim());
    _ctl = TextEditingController(text: kw);
    _st = _st.copyWith(keyword: kw);
  }

  @override
  void dispose() {
    _ctl.dispose();
    if (_ownsClient) _client?.close();
    super.dispose();
  }

  AssrtClient get _api {
    final injected = widget.client;
    if (injected != null) return injected;
    final existing = _client;
    if (existing != null) return existing;
    final c = AssrtClient();
    _client = c;
    _ownsClient = true;
    return c;
  }

  void _set(SubtitlePanelState next) {
    if (!mounted) return;
    setState(() => _st = next);
  }

  Future<void> _search() async {
    final kw = _ctl.text.trim();
    if (kw.isEmpty) {
      _set(_st.copyWith(error: '请输入要搜的字幕关键词'));
      return;
    }
    _set(
      _st.copyWith(
        busy: true,
        status: '正在搜索…',
        clearError: true,
        keyword: kw,
        results: const <AssrtSubtitle>[],
        selectedId: '',
        files: const <SubtitleFileRef>[],
        clearDetail: true,
      ),
    );
    try {
      final list = await _api.search(kw);
      // 语言偏好排序（同分保持站点原顺序 —— 站点按相关度排过了）
      final ranked = <AssrtSubtitle>[];
      final withScore = list
          .map((e) => (item: e, score: _cfg.languageScore(e)))
          .toList();
      withScore.sort((a, b) => b.score.compareTo(a.score));
      ranked.addAll(withScore.map((e) => e.item));
      _cfg = _cfg.copyWith(lastKeyword: kw);
      _cfg.save();
      _set(
        _st.copyWith(
          busy: false,
          status: ranked.isEmpty ? '没有找到字幕' : '找到 ${ranked.length} 条',
          results: ranked,
        ),
      );
    } on AssrtException catch (e) {
      _set(_st.copyWith(busy: false, status: '', error: e.message));
    } catch (e) {
      AppLog.write('subtitle', '搜索失败: $e');
      _set(_st.copyWith(busy: false, status: '', error: '搜索失败：$e'));
    }
  }

  Future<void> _openDetail(AssrtSubtitle s) async {
    _set(
      _st.copyWith(
        busy: true,
        status: '正在读取详情…',
        clearError: true,
        selectedId: s.id,
        files: const <SubtitleFileRef>[],
        clearDetail: true,
      ),
    );
    try {
      final d = await _api.detail(s.id);
      _set(_st.copyWith(busy: false, status: '详情已加载', detail: d));
    } on AssrtException catch (e) {
      _set(_st.copyWith(busy: false, status: '', error: e.message));
    } catch (e) {
      AppLog.write('subtitle', '详情失败: $e');
      _set(_st.copyWith(busy: false, status: '', error: '读取详情失败：$e'));
    }
  }

  Future<void> _download(AssrtSubtitle s) async {
    final path = s.downloadPath.isNotEmpty
        ? s.downloadPath
        : (await _api.detail(s.id)).downloadPath;
    if (path.isEmpty) {
      _set(_st.copyWith(error: '这个条目没有可用的下载链接'));
      return;
    }
    _set(
      _st.copyWith(
        busy: true,
        status: '正在下载…',
        clearError: true,
        selectedId: s.id,
        files: const <SubtitleFileRef>[],
      ),
    );
    try {
      final dl = await _api.download(
        downloadPath: path,
        referer:
            '$kAssrtBase/sub/?searchword=${Uri.encodeQueryComponent(_st.keyword)}',
      );
      if (!mounted) return;
      _set(_st.copyWith(status: '已下载 ${dl.length ~/ 1024} KB，正在解压…'));
      final kind = sniffKind(dl.bytes);
      final items = extractSubtitles(dl.bytes, hintName: dl.fileName);
      final res = await SubtitleStore.save(
        videoKey: _videoKey,
        items: items,
        sourceTitle: s.title,
        sourceId: s.id,
      );
      if (res.isEmpty) {
        _set(_st.copyWith(busy: false, status: '', error: '解出来的字幕写盘失败'));
        return;
      }
      final note = res.truncatedFrom != null
          ? '（共 ${res.truncatedFrom} 个，只保存了前 ${res.files.length} 个）'
          : '';
      _set(
        _st.copyWith(
          busy: false,
          status: '已保存 ${res.files.length} 个字幕 $note · 原始格式 ${kind.label}',
          files: res.files,
        ),
      );
    } on AssrtException catch (e) {
      _set(_st.copyWith(busy: false, status: '', error: e.message));
    } catch (e) {
      AppLog.write('subtitle', '下载失败: $e');
      _set(_st.copyWith(busy: false, status: '', error: '下载失败：$e'));
    }
  }

  void _mount(SubtitleFileRef f) {
    final cb = widget.onMount;
    if (cb == null) {
      _set(_st.copyWith(status: '已保存到 ${f.path}'));
      return;
    }
    cb(f);
    _set(_st.copyWith(mountedPath: f.path, status: '已挂载 ${f.name}'));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width > Layout.narrowBreakpoint;
    /*
     * ★ task-104：根节点形态由 `fill` 决定（理由见 `fill` 字段的文档）
     *   fill = true （默认，= 改前行为）  Positioned.fill(...) → 只能直接挂在 Stack 下
     *   fill = false（SheetExitMotion 包着） 直接返回内容 → 定位交给宿主
     */
    final body = GestureDetector(
      onTap: widget.onClose,
      // ★ task-99：遮罩**淡入**（原来是一帧硬切 —— Owner 说的「生硬」）
      //   颜色/覆盖范围一字不改，动画结束后 Opacity 恒为 1.0。
      child: OverlayScrim(
        color: Colors.black.withValues(alpha: 0.72),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            // ★ task-99：卡片**淡入 + 轻微上浮**（24px，Motion.base）
            child: OverlayCardMotion(
              child: Container(
                width: wide ? 720 : double.infinity,
                margin: wide
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: Sp.x3),
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.86,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _header(colors),
                    if (_cfg.showAttribution) _attribution(colors),
                    _searchRow(colors),
                    Flexible(child: _body(colors)),
                    _footer(colors),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // ★ 默认形态与改前**逐像素相同**（只多一个局部变量）
    return widget.fill ? Positioned.fill(child: body) : body;
  }

  Widget _header(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x3, Sp.x3),
      child: Row(
        children: <Widget>[
          Icon(Icons.subtitles_outlined, color: colors.onSurface),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '字幕',
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.videoTitle.trim().isNotEmpty)
                  Text(
                    widget.videoTitle.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: FontSizes.sm,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: _st.busy ? null : widget.onClose,
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            color: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _attribution(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x5, 0, Sp.x5, Sp.x3),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: Sp.x1),
          Expanded(
            child: Text(
              '字幕服务由 assrt.net 提供（射手网）。下载到的字幕仅在本机保存与使用。',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: FontSizes.cap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchRow(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _ctl,
              enabled: !_st.busy,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              style: TextStyle(
                color: colors.onSurface,
                fontSize: FontSizes.base,
              ),
              decoration: InputDecoration(
                hintText: '剧名 / 片名 / 关键词',
                hintStyle: TextStyle(color: colors.onSurfaceVariant),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Sp.x3,
                  vertical: Sp.x3,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
              ),
            ),
          ),
          const SizedBox(width: Sp.x2),
          FilledButton(
            onPressed: _st.busy ? null : _search,
            child: Text(_st.busy ? '处理中' : '搜索'),
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme colors) {
    final err = _st.error;
    final children = <Widget>[
      if (err != null) _errorBox(colors, err),
      if (_st.files.isNotEmpty) ..._fileTiles(colors),
      if (_st.detail != null && _st.files.isEmpty)
        _detailBox(colors, _st.detail!),
      if (_st.results.isEmpty && err == null && !_st.busy && _st.files.isEmpty)
        Padding(
          padding: const EdgeInsets.all(Sp.x6),
          child: Text(
            _st.keyword.trim().isEmpty
                ? '输入关键词后点「搜索」。结果来自 assrt.net 的公开搜索页。'
                : '没有结果。可以换个更短的关键词（站点按片名匹配，别带季集号）。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: FontSizes.sm,
            ),
          ),
        ),
      for (final s in _st.results) _resultTile(colors, s),
    ];
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, Sp.x4),
      children: children,
    );
  }

  Widget _errorBox(ColorScheme colors, String msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: Sp.x3),
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colors.error.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: colors.error),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: SelectableText(
              msg,
              style: TextStyle(color: colors.onSurface, fontSize: FontSizes.sm),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _fileTiles(ColorScheme colors) {
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: Sp.x2),
        child: Text(
          '已保存的字幕文件',
          style: TextStyle(
            color: colors.onSurface,
            fontSize: FontSizes.sm,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      for (final f in _st.files)
        Container(
          margin: const EdgeInsets.only(bottom: Sp.x2),
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      f.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontSize: FontSizes.sm,
                      ),
                    ),
                    Text(
                      '${_kb(f.bytes)}${f.episode != null ? ' · 第 ${f.episode} 集' : ''}',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: FontSizes.cap,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x2),
              if (widget.onMount != null)
                FilledButton.tonal(
                  onPressed: _st.busy ? null : () => _mount(f),
                  child: Text(_st.mountedPath == f.path ? '已挂载' : '挂到当前播放'),
                ),
            ],
          ),
        ),
      const SizedBox(height: Sp.x3),
    ];
  }

  Widget _detailBox(ColorScheme colors, AssrtSubtitleDetail d) {
    return Container(
      margin: const EdgeInsets.only(bottom: Sp.x3),
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            d.title,
            style: TextStyle(
              color: colors.onSurface,
              fontSize: FontSizes.sm,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Sp.x1),
          Text(
            <String>[
              if (d.format.isNotEmpty) '格式 ${d.format}',
              if (d.languages.isNotEmpty) '语言 ${d.languages.join(' ')}',
              if (d.packSizeText.isNotEmpty) '体积 ${d.packSizeText}',
              if (d.files.isNotEmpty) '${d.files.length} 个文件',
            ].join(' · '),
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: FontSizes.cap,
            ),
          ),
          if (d.files.isNotEmpty) ...<Widget>[
            const SizedBox(height: Sp.x2),
            for (final f in d.files.take(6))
              Text(
                '· ${f.name}${f.sizeText.isEmpty ? '' : '（${f.sizeText}）'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: FontSizes.cap,
                ),
              ),
            if (d.files.length > 6)
              Text(
                '… 还有 ${d.files.length - 6} 个',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: FontSizes.cap,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _resultTile(ColorScheme colors, AssrtSubtitle s) {
    final selected = _st.selectedId == s.id;
    return Container(
      margin: const EdgeInsets.only(bottom: Sp.x2),
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.35)
            : colors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            s.title,
            style: TextStyle(
              color: colors.onSurface,
              fontSize: FontSizes.sm,
              fontWeight: FontWeights.regular,
            ),
          ),
          const SizedBox(height: Sp.x1),
          Text(
            <String>[
              if (s.languages.isNotEmpty) s.languages.join(' '),
              if (s.format.isNotEmpty) s.format,
              if (s.downloads > 0) '下载 ${s.downloads}',
              if (s.rating != null) '评分 ${s.rating!.toStringAsFixed(1)}',
              if (s.date.isNotEmpty) s.date,
            ].join(' · '),
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: FontSizes.cap,
            ),
          ),
          const SizedBox(height: Sp.x2),
          Row(
            children: <Widget>[
              TextButton(
                onPressed: _st.busy ? null : () => _openDetail(s),
                child: const Text('详情'),
              ),
              const SizedBox(width: Sp.x2),
              FilledButton.tonal(
                onPressed: _st.busy ? null : () => _download(s),
                child: const Text('下载'),
              ),
              const Spacer(),
              if (s.extensionHint.isNotEmpty)
                Text(
                  s.extensionHint,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: FontSizes.cap,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footer(ColorScheme colors) {
    final st = _st.status;
    return Container(
      padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x3, Sp.x5, Sp.x4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          if (_st.busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (_st.busy) const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              st.isEmpty ? '只下载不播放，不会改动你的片库。' : st,
              maxLines: 2,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: FontSizes.cap,
              ),
            ),
          ),
          if (widget.onMount == null)
            Text(
              '未连接播放页',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: FontSizes.cap,
              ),
            ),
        ],
      ),
    );
  }

  static String _kb(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
