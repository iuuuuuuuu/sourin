// ═══════════════════════════════════════════════════════════════════════
//  TVBox 订阅链接 + 检测更新（task-12）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户拍板
//
// > 填入 tvbox 源的链接，然后他有更新我们也能收得到，
// > 不至于更新失效了，之前的插件也是一样的处理
//
// # 与插件那套（`_PluginUpdateDialog`，task-23）的关系
//
// 完全同构，只差一处：
// ```text
// 插件    1 个 .js   ↔ 1 个安装链接 → 一个 id 一个 sidecar 文件
// TVBox   1 份配置   ↔ 1 个订阅链接 → 一份配置产出几十个源
// ```
// 所以 TVBox 的「检测更新」是**按链接**做的：一次下载对比全部源，
// 而不是每个源各下一遍。用户从任意一张卡点进来，看到的都是
// **同一条链接的同一份结果**。
//
// # ★★ 最重要的产品原则：没有的能力不假装有
//
// ```text
// 直接贴 JSON 文本导入的源 → 没有链接可查
//   → 卡片上**不画**「检测更新」入口，只如实说明「无订阅链接」
//   → 绝不显示成「已是最新」（那是假装查过了）
// ```
// 这条与 `settings_page.dart` 的 `onPluginUpdate == null` 是同一条：
// 宁可少一个按钮，也不能给一个点了没反应的按钮。
//
// # 为什么抽成独立 widget 文件
//
// `settings_page.dart` 上同时有 3~4 个代理在改（task-13 / task-14）。
// 把「订阅更新」做成**自包含** widget（只依赖 `SourinApi`），页面那边
// 只留「打开它」一行，冲突面最小 —— 理由与 `provider_import_dialog.dart`
// 的头部注释完全一致。
//
// # 三种结局都不许静默（与 `PluginUpdateInfo` 同一条）
//
// ```text
// ① 没有订阅链接     → 进 skipped，如实说「查不了」
// ② 网络 / 解析失败   → 红字显示**失败原因**
// ③ 查到了           → 新增 / 变更 / 已消失 / 未变，逐条列出来
// ```

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import 'overlay_motion.dart';
import '../tokens.dart';

/// 把一条检测结果压成一行中文摘要（面板与弹窗共用）
///
/// ⚠️ **失败绝不返回「已是最新」** —— 那是本功能唯一不能犯的错。
String tvboxUpdateSummary(TvboxUpdateItem it) {
  if (it.multiRepo) {
    return '远端现在是一份「多仓」配置（只有 urls，没有 sites）';
  }
  if (!it.ok) {
    final why = (it.error ?? '').trim();
    return why.isEmpty ? '检测失败（后端没有给出原因）' : '检测失败：$why';
  }
  final parts = <String>[];
  if (it.added.isNotEmpty) parts.add('新增 ${it.added.length}');
  if (it.changed.isNotEmpty) parts.add('变更 ${it.changed.length}');
  if (it.removed.isNotEmpty) parts.add('远端已消失 ${it.removed.length}');
  if (parts.isEmpty) {
    return '已是最新（远端 ${it.remoteConvertible} 个可转换站点）';
  }
  return parts.join(' · ');
}

/// 打开「TVBox 订阅更新」弹窗
///
/// 返回 `true` 表示**本地源列表变过**（用户点了一键更新），调用方要刷新。
///
/// # 为什么用 `show` 静态方法而不是让调用方自己 `showDialog`
///
/// 与 `ProviderImportDialog.showAdd` 同一个理由：页面那边只留一行，
/// 弹窗内部的布局/状态全部收在这个文件里，别的代理改设置页时不会碰到。
class TvboxUpdateDialog extends StatefulWidget {
  const TvboxUpdateDialog({
    super.key,
    required this.id,
    required this.name,
    this.sourceUrl,
  });

  /// 源 id（后端按它查 sidecar 里的订阅链接）
  final String id;

  /// 显示用名字
  final String name;

  /// 打开时已知的订阅链接（null = 这个源没有链接）
  final String? sourceUrl;

  static Future<bool> show(
    BuildContext context, {
    required String id,
    required String name,
    String? sourceUrl,
  }) async {
    final r = await showAppDialog<bool>(
      context: context,
      builder: (_) =>
          TvboxUpdateDialog(id: id, name: name, sourceUrl: sourceUrl),
    );
    return r ?? false;
  }

  @override
  State<TvboxUpdateDialog> createState() => _TvboxUpdateDialogState();
}

class _TvboxUpdateDialogState extends State<TvboxUpdateDialog> {
  late final TextEditingController _urlCtl;

  bool _savingLink = false;
  bool _checking = false;
  bool _updating = false;

  /// 检测结果（`null` = **还没检测过** —— 与「检测了但失败」是两回事）
  TvboxUpdateCheck? _check;

  /// 一键更新的结果
  TvboxSourceUpdate? _applied;

  /// 弹窗级错误（保存链接失败 / 命令本身抛异常）
  ///
  /// ⚠️ 与「检测失败」分开：检测失败是**这次检测的结论**，
  ///    要显示在检测区域（紧挨着按钮），混在一起用户分不清
  ///    「是链接查不到还是弹窗坏了」。与 `_PluginUpdateDialogState` 一致。
  String? _error;

  /// 后端是否认这个源有订阅链接（保存成功后更新）
  late bool _hasLink;

  /// 有没有改动过本地源列表（关闭时告诉父级要不要刷新）
  bool _changed = false;

  /// 一键更新的两个开关
  ///
  /// ★ 默认值刻意选**最保守**的一侧：
  ///   ```text
  ///   applyNew      = true  → 远端新增的站也一起注册（用户点「更新」就是想要这个）
  ///   deleteMissing = false → 远端已经没有的站**只报告、不删**
  ///   ```
  ///   配置作者临时删掉一个站又加回来是常事；静默删掉用户本地的东西
  ///   是不可逆的伤害。要删必须由用户明确勾选。
  bool _applyNew = true;
  bool _deleteMissing = false;

  @override
  void initState() {
    super.initState();
    _hasLink = (widget.sourceUrl ?? '').trim().isNotEmpty;
    _urlCtl = TextEditingController(text: widget.sourceUrl ?? '');
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  /// 保存 / 清除订阅链接
  ///
  /// ⚠️ 传空字符串是**清除**链接（回到「贴文本导入」状态），不是错误。
  Future<void> _saveLink() async {
    if (_savingLink) return;
    final url = _urlCtl.text.trim();
    setState(() {
      _savingLink = true;
      _error = null;
    });
    try {
      await SourinApi.setTvboxSource(widget.id, url);
      if (!mounted) return;
      setState(() {
        _savingLink = false;
        _hasLink = url.isNotEmpty;
        _check = null;
        _applied = null;
      });
      if (url.isNotEmpty) {
        // 刚填上链接，顺手查一次 —— 用户填链接的**目的**就是想知道有没有更新
        await _checkNow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingLink = false;
        _error = '保存订阅链接失败：$e';
      });
    }
  }

  /// 检测更新（用户**点了才**联网）
  ///
  /// ⚠️ `keepApplied` —— 一键更新后会自动再查一次（让对比数据显示成最新的），
  ///    那次**不能**把更新结果面板清掉，否则用户刚看到的「已更新 3 个」
  ///    会在半秒后消失，像是没生效。
  Future<void> _checkNow({bool keepApplied = false}) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
      if (!keepApplied) _applied = null;
    });
    try {
      final r = await SourinApi.checkTvboxUpdates(id: widget.id);
      if (!mounted) return;
      setState(() {
        _check = r;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = '检测更新失败：$e';
      });
    }
  }

  /// 一键应用远端的变化
  Future<void> _applyUpdate() async {
    if (_updating) return;
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final r = await SourinApi.updateTvboxSource(
        widget.id,
        applyNew: _applyNew,
        deleteMissing: _deleteMissing,
      );
      if (!mounted) return;
      setState(() {
        _applied = r;
        _updating = false;
        if (r.updated) _changed = true;
      });
      if (r.updated) {
        await _checkNow(keepApplied: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updating = false;
        _error = '更新失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final it = _check?.itemOf(widget.id);
    final busy = _savingLink || _checking || _updating;

    return AlertDialog(
      title: Row(
        children: [
          Flexible(
            child: Text(
              '订阅更新 · ${widget.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        // ★ 有界高度（照 _PluginUpdateDialog）：内容再多也只占 480px，内部滚动
        height: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 订阅链接（可编辑：贴文本导入的源在这里补链接）──
              Text(
                '订阅链接',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Sp.x1),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlCtl,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'https://example.com/tvbox.json',
                      ),
                      style: const TextStyle(fontSize: FontSizes.cap),
                      onSubmitted: (_) => _saveLink(),
                    ),
                  ),
                  const SizedBox(width: Sp.x2),
                  FilledButton.tonal(
                    onPressed: busy ? null : _saveLink,
                    child: Text(
                      _savingLink ? '保存中…' : (_hasLink ? '保存' : '填入'),
                    ),
                  ),
                  if (_hasLink) ...[
                    const SizedBox(width: Sp.x2),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              _urlCtl.text = '';
                              _saveLink();
                            },
                      child: const Text('清除'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: Sp.x1),
              Text(
                _hasLink
                    ? '这个链接下的全部源共用同一条订阅，检测一次对比全部。'
                    : '这个源是贴文本导入的，没有订阅链接 —— 查不了更新。填入当初的配置地址即可。',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Sp.x3),

              // ── 检测按钮 + 结果 ──
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: (busy || !_hasLink) ? null : () => _checkNow(),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(_checking ? '检测中…' : '检测更新'),
                  ),
                  const SizedBox(width: Sp.x3),
                  Expanded(child: _checkSummary(colors, it)),
                ],
              ),
              const SizedBox(height: Sp.x2),

              /*
               * ★ 有变化才出现「更新」区 —— **绝不自动应用**
               *
               * 与 _PluginUpdateDialog 同一条：用户要的是「检测更新」，
               * 不是「自动更新」。看到结果再决定要不要改本地。
               */
              if (it != null && it.ok && it.hasChanges) ...[
                _applyBox(colors, it),
                const SizedBox(height: Sp.x2),
              ],

              if (_applied != null) ...[
                _appliedPanel(colors, _applied!),
                const SizedBox(height: Sp.x2),
              ],

              if (it != null &&
                  it.ok &&
                  !it.hasChanges &&
                  it.removed.isNotEmpty) ...[
                _removedPanel(colors, it.removed),
                const SizedBox(height: Sp.x2),
              ],

              if (it != null && it.multiRepo) ...[
                _multiRepoPanel(colors, it),
                const SizedBox(height: Sp.x2),
              ],

              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.error,
                  ),
                ),
                const SizedBox(height: Sp.x2),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  局部渲染
  // ═══════════════════════════════════════════════════════════════════

  /// 检测结果的**一句话结论** —— 三种结局都不许静默
  ///
  /// ```text
  /// 还没查（null）  → 「还没检测过 —— 点「检测更新」才会联网」
  /// 查了但失败      → 红色 + 后端给的**具体原因**（绝不显示成"已是最新"）
  /// 查到了，有变化  → 「发现更新：新增 N · 变更 N」
  /// 查到了，无变化  → 「已是最新（远端 N 个可转换站点）」
  /// ```
  Widget _checkSummary(ColorScheme colors, TvboxUpdateItem? it) {
    if (_checking) {
      return Text(
        '正在检查订阅链接…',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    }
    if (it == null) {
      return Text(
        _hasLink ? '还没检测过 —— 点「检测更新」才会联网' : '没有订阅链接，查不了更新',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    }
    if (it.multiRepo) {
      return Text(
        '远端现在是一份「多仓」配置',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
      );
    }
    if (!it.ok) {
      return _failLine(colors, it.error);
    }
    final text = it.hasChanges
        ? '发现更新：新增 ${it.added.length} · 变更 ${it.changed.length}'
        : '已是最新（远端 ${it.remoteConvertible} 个可转换站点）';
    return Text(
      text,
      style: TextStyle(
        fontSize: FontSizes.cap,
        color: it.hasChanges ? colors.primary : colors.onSurfaceVariant,
      ),
    );
  }

  /// 红色失败行（后端没给原因时也**如实说**没给，不编一个）
  Widget _failLine(ColorScheme colors, String? why) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 14, color: colors.error),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            why == null || why.trim().isEmpty ? '检测失败（后端没有给出原因）' : '检测失败：$why',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
          ),
        ),
      ],
    );
  }

  /// 一块灰底面板（与 `SettingsEntryRow` 同一套视觉）
  Widget _box(ColorScheme colors, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: Radii.rLg,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  /// 一行开关（照 `settings_kit.dart` 的 `SettingsGestureToggle`）
  Widget _toggleRow(
    ColorScheme colors, {
    required String label,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x3),
        Switch(value: value, onChanged: _updating ? null : onChanged),
      ],
    );
  }

  /// 「更新」区 —— **有变化才出现，且绝不自动应用**
  Widget _applyBox(ColorScheme colors, TvboxUpdateItem it) {
    final gone = it.removed.length;
    return _box(colors, [
      Text(
        '远端有 ${it.added.length + it.changed.length} 处变化',
        style: TextStyle(
          fontSize: FontSizes.sm,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
      const SizedBox(height: Sp.x1),
      Text(
        '新增 ${it.added.length} 个站 · 变更 ${it.changed.length} 个接口'
        '${gone > 0 ? ' · 远端已消失 $gone 个' : ''}',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: Sp.x3),
      _toggleRow(
        colors,
        label: '同时加入新增站点',
        hint: '关掉则只更新已有源的接口，不注册新站',
        value: _applyNew,
        onChanged: (v) => setState(() => _applyNew = v),
      ),
      const SizedBox(height: Sp.x2),
      _toggleRow(
        colors,
        label: '同时删除远端已消失的站',
        hint: '默认不删 —— 配置作者临时删站又加回来是常事',
        value: _deleteMissing,
        onChanged: (v) => setState(() => _deleteMissing = v),
      ),
      const SizedBox(height: Sp.x3),
      FilledButton.icon(
        onPressed: _updating ? null : _applyUpdate,
        icon: const Icon(Icons.download_done, size: 16),
        label: Text(_updating ? '更新中…' : '应用更新'),
      ),
    ]);
  }

  /// 一键更新的结果（**如实报**：新增/变更/删除/失败/没应用，一个都不省）
  Widget _appliedPanel(ColorScheme colors, TvboxSourceUpdate r) {
    if (!r.updated) {
      return _box(colors, [
        Text(
          r.reason ?? '远端与本地一致，没有改动',
          style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
        ),
        if (r.removed.isNotEmpty) ...[
          const SizedBox(height: Sp.x1),
          Text(
            '远端已消失 ${r.removed.length} 个站（未删除）',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ]);
    }
    return _box(colors, [
      Text(
        '已更新',
        style: TextStyle(
          fontSize: FontSizes.sm,
          fontWeight: FontWeight.w600,
          color: colors.primary,
        ),
      ),
      const SizedBox(height: Sp.x1),
      Text(
        '新增 ${r.added.length} · 变更 ${r.changed.length} · 删除 ${r.deleted.length}',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
      ),
      if (r.failed.isNotEmpty) ...[
        const SizedBox(height: Sp.x1),
        Text(
          '有 ${r.failed.length} 个新站探测失败，没有注册',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
        ),
      ],
      if (r.notApplied.isNotEmpty) ...[
        const SizedBox(height: Sp.x1),
        Text(
          '按你的选择跳过了 ${r.notApplied.length} 个新增站',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
      if (r.removed.isNotEmpty) ...[
        const SizedBox(height: Sp.x1),
        Text(
          r.deleted.isEmpty
              ? '远端已消失 ${r.removed.length} 个站：只报告，没有删'
              : '远端已消失 ${r.removed.length} 个站，其中 ${r.deleted.length} 个已按你的选择删除',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    ]);
  }

  /// 「远端已经没有这些站」清单（默认**只报告**）
  Widget _removedPanel(ColorScheme colors, List<TvboxLocalSite> removed) {
    return _box(colors, [
      Text(
        '远端配置里已经没有这些站（默认不删，只报告）：',
        style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
      ),
      const SizedBox(height: Sp.x1),
      for (final s in removed.take(8))
        Text(
          '· ${s.name.isEmpty ? s.id : s.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      if (removed.length > 8)
        Text(
          '…另有 ${removed.length - 8} 个',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      const SizedBox(height: Sp.x1),
      Text(
        '要删的话，勾上「同时删除远端已消失的站」再点更新。',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      ),
    ]);
  }

  /// 远端变成了「多仓」配置 —— 列子仓给用户挑，**不假装能一键更新**
  Widget _multiRepoPanel(ColorScheme colors, TvboxUpdateItem it) {
    return _box(colors, [
      Text(
        '远端现在是一份「多仓」配置（只有 urls，没有 sites），不能直接更新。',
        style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
      ),
      const SizedBox(height: Sp.x1),
      Text(
        '点一个子仓，地址会填到上面的输入框，再点「填入」保存。',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: Sp.x2),
      for (final repo in it.repos.take(20))
        InkWell(
          onTap: _updating
              ? null
              : () {
                  setState(() {
                    _urlCtl.text = repo.url;
                    _error = null;
                    _check = null;
                    _applied = null;
                  });
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.x1),
            child: Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: Text(
                    repo.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      if (it.repos.length > 20)
        Text(
          '…另有 ${it.repos.length - 20} 个子仓未列出',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
    ]);
  }
}
