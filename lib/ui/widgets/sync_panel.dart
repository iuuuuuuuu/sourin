// ═══════════════════════════════════════════════════════════════════════
//  云盘同步面板（2026-09-29 从 settings_page.dart 搬到「备份与恢复」二级页）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户指令（原话）
//
// > 云盘同步合并到备份二级页去
//
// # 搬了什么
//
// ```text
// 原来（settings_page.dart 一级页）      现在（本文件 + backup_page.dart）
// ────────────────────────────────────  ──────────────────────────────────
// _Block(title: '云盘同步', …)          SyncPanel.build() 里的 SettingsBlock
// _sync / _syncBusy（宿主字段）         _SyncPanelState 的 _sync / _syncBusy
// _configureWebdav / _testSync          同名方法（搬进来，逻辑一字未改）
// _syncNow / _disconnectSync            同名方法（同上）
// class _WebdavDialog                   搬进本文件（私有，仍只被一处引用）
// ```
//
// # ★ 为什么做成「自包含无参 widget」而不是「把 host 传进来」
//
// 与 `backup_panel.dart` 同一个理由（见那个文件头的「为什么这个页面最简单」）：
// `const SyncPanel({super.key})` 无参、无回调、不依赖宿主 State ⇒
// `backup_page.dart` 里只要多写一行 `SyncPanel()`，**零状态传递**。
//
// ⚠️ 而且这**不是**风格偏好，是硬约束 ——
//    `test/task43_plugins_subpage_test.dart` 会扫 `settings_page.dart`，
//    把「名字像二级页（`*PageState`）」**或**「类体里出现 `host`」的
//    `State` 类取**并集**挑出来，要求每个都含
//    `valueListenable: host._dataRev,` 与 `valueListenable: host._toastRev,`。
//    ⇒ 本面板若叫 `_SyncPageState`、或用了 `host`，就会被**要求订阅宿主**，
//      而它根本没有宿主 ⇒ 测试变红。
//    ⇒ 命名 `_SyncPanelState` + 完全不碰 `host` = **正确沉默**
//      （原 `_WebdavDialogState` 的沉默就是这条判据的既有正例）。
//
// # ★ 两个「搬过来才发现」的行为差异（都按更正确的方向处理了）
//
// ## ① `syncStatus()` 失败 = 「未配置」，不是「加载失败」
//
// 原来它挂在 `loadAll()` 的 `Future.wait` 里 —— 那个 `Future.wait` 外层
// 的 `catch` 会把**整页**变成「加载失败：…」。可是
// `about_page.dart:61-69` 已经实测记过：「用户**没配云盘**时这个接口可能
// 直接报错（那是正常状态，不是故障）」。⇒ 没配云盘的用户本来会连
// 设置页都打不开。现在单独 `try/catch`，失败就当作未配置（`_sync` 保持 null）。
//
// ## ② `_disconnectSync` 现在也置 `_syncBusy`
//
// 原来那一个方法**漏了** `_syncBusy` 的 set/finally（另外三个都有）——
// 断开期间按钮仍然可点。这里补上；行为上只是「点不动」而不是「能连点」。
//
// # 消息怎么报（不再有宿主的 toast）
//
// 原来走宿主的 `_flash()`（写宿主 Stack 里的 toast + `_toastRev`）。
// 本面板在另一条路由上，用不了 ⇒ 改用 `backup_panel.dart:523-534` 的
// 现成范式：**面板内联一行** `_msg(text, color)`。
// 好处是同步结果（「同步完成：收藏(12) / 进度(3)」）会**留在页面上**，
// 不会 3 秒后自己消失。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-09-29 第二批：WebDAV 预设 + 保留份数 + 自动 / 手动整体备份
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 配置云盘这里,搞几个预设,点击后自动填充域名和配置信息,比如坚果云,
// > 选择后自动填充坚果云的网址 然后默认也是选择坚果云
//
// > 还要可以配置最多保存数量,按照日期时间保存,最多保存指定数量,默认10个,
// > 可以自动,也可以手动,比如 间隔多长时间保存一次,或者有数据变动就保存,
// > 这可以参考 阅读 app这个保存阅读记录的方式去保存,他那个就耗很低的流量,
// > 好像整体备份和别的备份是拆分开的,你调研一下然后实现
//
// # ① 预设（`_kWebdavPresets`）
//
// 只放**官方文档能查证**的服务地址。联网调研的逐条来源见
// `.probe/t91_sync_iface.md`（契约）与下面预设表里每个条目的注释；
// 凡是「功能存在但地址只有第三方文档」的一律**不收录**
// （123云盘 / 城通 / 天翼云 / 移动云盘），**明确没有 WebDAV 的绝不编**
// （百度网盘 / 阿里云盘 / 腾讯微云 / 夸克 / Box —— Box 官方 2023 年已下线 WebDAV）。
//
// ★ 踩过的坑：坚果云国际版 `nutstore.net` **没有**独立 WebDAV 地址
//   （实测该站所有链接都指回 `jianguoyun.com`）⇒ 全仓**不得**出现
//   `dav.nutstore.net` 之类编造的地址（`test/t91_sync_presets_test.dart` 有断言）。
//
// # ② 为什么是「保留份数」而不是「保留天数」
//
// 用户要的是「最多保存指定数量,默认10个」。后端按**文件名里的日期时间**排序
// （`dsh-backup-<设备>-yyyyMMdd-HHmmss.zip` 定长 ⇒ 字典序即时间序），
// 超出份数就删最旧的；`retainCount` 由 Rust 侧兜底 `max(1, …)`。
//
// ★ 这里用**选项胶囊**而不是数字输入框：
//   ① 本仓已有 `SettingsGestureChoice`（设置页手势配置在用），一点即改、无校验分支；
//   ② 数字框要处理空串 / 0 / 超大值 / 防抖，收益只是「任意 N」——
//      而 API（`SourinApi.setSyncSettings(retainCount: …)`）本来就能收任意 N，
//      将来想改成输入框不必动后端。
//
// # ③ 为什么有**两个**间隔（别合并！）
//
// 这是照「阅读 App 分开存」的结论做的（详见 `models.dart` 里 `SyncSettings`
// 的注释与 `.probe/t91_sync_iface.md` §6）：
//
// ```text
// 增量同步（几 KB）  data/favorites.jsonl + progress.jsonl + providers.json
//                    「多久看一眼云端」= autoIntervalMinutes（默认 30 分钟）
// 整体备份（整包 zip）backup/snapshots/dsh-backup-*.zip
//                    「整包备份间隔」  = autoBackupIntervalMinutes（默认 1 天）
// ```
//
// ★ 如果只有一个间隔，打开自动同步就等于「每 30 分钟上传一个整包」——
//   那正是用户说的「耗流量」。两个间隔分开之后：
//   没数据变动 ⇒ 签名不变 ⇒ **一个写请求都不发**（只 GET 比对）。
//
// # ④ 手动那一路
//
// 「立即备份」= `sync_backup_now`（上传一份 + 按份数清理旧份）；
// 下面的列表列出云端已有的份，可以逐份删除（★ 云盘删除通常**不进回收站**，
// 所以删除前有确认框，确认框里写明这一点）。
//
// ⚠️ 「改小保留份数」不会立刻删 —— 后端是在**下一次上传成功后**才跑清理。
//    所以胶囊下面那句提示写的是「下次备份时自动删掉多出来的」。

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import 'overlay_motion.dart';
import 'settings_kit.dart';

/// 云盘同步面板（WebDAV）
///
/// 自包含：无参、无回调、不依赖宿主 State —— 见文件头。
class SyncPanel extends StatefulWidget {
  const SyncPanel({super.key});

  @override
  State<SyncPanel> createState() => _SyncPanelState();
}

class _SyncPanelState extends State<SyncPanel> {
  SyncStatus? _sync;
  SyncSettings? _settings;
  List<SyncBackupEntry> _backups = const [];
  bool _syncBusy = false;

  /// 面板内联消息（替代原来的宿主 toast，见文件头「消息怎么报」）
  String _ok = '';
  String _err = '';

  /// 忙的时候正在做哪一步（进度圈旁边那行字）
  ///
  /// 用一个字段而不是从 `_ok` 反推：`_ok` 是**结果**，
  /// 一旦某步失败它会被 `_sayErr` 清掉，进度圈就没了文字。
  String _busyHint = '';

  /// 四个动作都用它包一层，把 `_syncBusy` 与提示语绑在一起 ——
  /// 少写一处 `setState(() => _syncBusy = true)` 就少一处忘记置提示的错误。
  Future<T?> _busy<T>(String hint, Future<T> Function() body) async {
    if (!mounted) return null;
    setState(() {
      _syncBusy = true;
      _busyHint = hint;
    });
    try {
      return await body();
    } finally {
      if (mounted) {
        setState(() {
          _syncBusy = false;
          _busyHint = '';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  /// 拉一次同步状态 + 设置 + 云端备份列表
  ///
  /// ⚠️ `syncStatus()` 失败**不是**故障：没配云盘时后端可能直接报错（见文件头 ①）。
  /// 而 `syncSettings()` / `syncBackupList()` 按契约「永不失败」
  /// （没配云盘时前者回默认值、后者回空列表，见 `.probe/t91_sync_iface.md` §3.1）。
  Future<void> _reload() async {
    try {
      final s = await SourinApi.syncStatus();
      if (!mounted) return;
      setState(() => _sync = s);
    } catch (e) {
      debugPrint('[SYNC] 云盘状态读取失败（未配置时属正常）: $e');
    }
    await _reloadSettings();
    await _reloadBackups();
  }

  Future<void> _reloadSettings() async {
    try {
      final s = await SourinApi.syncSettings();
      if (!mounted) return;
      setState(() => _settings = s);
    } catch (e) {
      // 契约上不该发生（§3.1 永不失败）—— 真发生了也别把面板搞崩
      debugPrint('[SYNC] 云盘设置读取失败（契约上不该发生）: $e');
    }
  }

  Future<void> _reloadBackups() async {
    try {
      final list = await SourinApi.syncBackupList();
      if (!mounted) return;
      setState(() => _backups = list);
    } catch (e) {
      debugPrint('[SYNC] 云端备份列表读取失败（未配置时属正常）: $e');
    }
  }

  void _sayOk(String m) {
    if (!mounted) return;
    setState(() {
      _ok = m;
      _err = '';
    });
  }

  void _sayErr(String m) {
    if (!mounted) return;
    setState(() {
      _err = m;
      _ok = '';
    });
  }

  Future<void> _configureWebdav() async {
    final r =
        await showAppDialog<
          ({String url, String user, String pass, String dir})
        >(
          context: context,
          // ★ 把已配置的地址/用户名/目录传进去 ⇒ 对话框打开时就是「当前值」，
          //   而不是每次都空白重填（`_settings` 可能还没拉到，那就走默认 坚果云）
          builder: (_) => _WebdavDialog(initial: _settings),
        );
    if (r == null) return;

    await _busy('正在检查地址并准备目录…', () async {
      try {
        /*
         * ★ 后端会「先建目录再自检」并返回自检结果
         *
         * 原版 2026-09-15 修的 bug：`test()` 会 PROPFIND 含 remote_dir
         * 的完整路径，目录不存在就 404 → 报「路径不存在」让用户
         * 以为填错了地址。所以必须 prepare() 在前。
         */
        final msg = await SourinApi.configureWebdav(
          baseUrl: r.url,
          username: r.user,
          password: r.pass,
          remoteDir: r.dir.isEmpty ? null : r.dir,
        );
        await _reload();
        _sayOk(msg);
      } catch (e) {
        _sayErr('配置失败：$e');
      }
    });
  }

  Future<void> _testSync() async {
    await _busy('正在测试连接…', () async {
      try {
        final msg = await SourinApi.testSync();
        _sayOk(msg);
      } catch (e) {
        _sayErr('测试失败：$e');
      }
    });
  }

  Future<void> _syncNow() async {
    await _busy('正在同步…', () async {
      try {
        final sums = await SourinApi.syncNow();
        await _reload();
        _sayOk(_fmtSyncResult(sums));
      } catch (e) {
        _sayErr('同步失败：$e');
      }
    });
  }

  /// 把每一步的汇总说成人话
  ///
  /// ★ 只列**真的动了**的平面 —— 三个平面全 0 时说「无变化」，
  ///   而不是把「收藏与追更(0) / 播放进度(0) / 内容源配置(0)」端给用户。
  static String _fmtSyncResult(List<SyncSummary> sums) {
    if (sums.isEmpty) return '同步完成（没有可同步的内容）';
    final moved = sums.where((s) => s.total > 0).toList();
    if (moved.isEmpty) return '同步完成（收藏、进度、内容源都没有变化）';

    final parts = <String>[];
    for (final s in moved) {
      final bits = <String>[
        if (s.pulled > 0) '拉取 ${s.pulled}',
        if (s.pushed > 0) '上传 ${s.pushed}',
      ];
      final base = '${s.label}：${bits.join(' / ')}';
      parts.add(s.conflicts > 0 ? '$base（有 ${s.conflicts} 条按较新的一份为准）' : base);
    }
    return '同步完成 —— ${parts.join('；')}';
  }

  // ── 整体备份（手动那一路，契约 §1/§5）─────────────────────────────

  /// 立即上传一份整体备份，并按保留份数清理旧份
  Future<void> _backupNow() async {
    await _busy('正在打包并上传…', () async {
      try {
        final r = await SourinApi.syncBackupNow();
        await _reloadBackups();
        final pruned =
            r.pruned.isEmpty ? '' : '，并清理了 ${r.pruned.length} 份旧备份';
        _sayOk(
          '已备份 ${_fmtBytes(r.bytes)}，云端现有 ${r.total} 份$pruned',
        );
      } catch (e) {
        _sayErr('备份失败：$e');
      }
    });
  }

  Future<void> _deleteBackup(SyncBackupEntry e) async {
    final ok = await _confirm(
      title: '删除云端备份',
      message:
          '确定删掉云端的这一份备份吗？\n\n'
          '${e.name}\n\n'
          '⚠️ 云盘上的删除一般不进回收站，删了就找不回来了。',
      okLabel: '删除',
    );
    if (!ok) return;
    await _busy('正在删除…', () async {
      try {
        await SourinApi.syncBackupDelete(e.name);
        await _reloadBackups();
        _sayOk('已删除这份备份');
      } catch (err) {
        _sayErr('删除失败：$err');
      }
    });
  }

  // ── 设置（保留份数 / 自动同步 / 两个间隔，契约 §1/§2/§6）─────────────

  /// 只改传进来的字段，其余保持不动；返回改完的完整设置
  Future<void> _patch({
    int? retainCount,
    bool? autoEnabled,
    int? autoIntervalMinutes,
    bool? autoOnChange,
    int? autoBackupIntervalMinutes,
  }) async {
    // `SettingsGestureToggle` 的 onChanged 不可为 null（见 settings_kit.dart），
    // 所以「忙时点不动」得在这里挡。
    if (_syncBusy) return;
    await _busy('正在保存设置…', () async {
      try {
        final s = await SourinApi.setSyncSettings(
          retainCount: retainCount,
          autoEnabled: autoEnabled,
          autoIntervalMinutes: autoIntervalMinutes,
          autoOnChange: autoOnChange,
          autoBackupIntervalMinutes: autoBackupIntervalMinutes,
        );
        if (!mounted) return;
        setState(() => _settings = s);
        _sayOk('设置已保存，最多 1 分钟后按新设置自动执行');
      } catch (e) {
        _sayErr('设置保存失败：$e');
      }
    });
  }

  Future<void> _disconnectSync() async {
    final ok = await _confirm(
      title: '断开云盘',
      message:
          '确定断开云盘同步吗？\n\n'
          '凭据仍保留在系统钥匙串里，重新配置时不用再输密码。',
    );
    if (!ok) return;
    await _busy('正在断开…', () async {
      try {
        await SourinApi.disconnectSync();
        await _reload();
        _sayOk('已断开云盘（密码仍保留在系统中）');
      } catch (e) {
        _sayErr('$e');
      }
    });
  }

  /// 本地确认框（原来借用宿主 `SettingsPageState._confirm`）
  Future<bool> _confirm({
    required String title,
    required String message,
    String okLabel = '确定',
    String? cancelLabel = '取消',
  }) async {
    final r = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          if (cancelLabel != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelLabel),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connected = _sync?.connected == true;
    final s = _settings;

    return SettingsBlock(
      title: '云盘同步',
      trailing: Text(
        connected ? '已连接' : '未配置',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: connected ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
      children: [
        Text(
          '收藏、追更、播放进度与内容源配置会跨设备同步。'
          '支持任意 WebDAV 服务（坚果云、Nextcloud、群晖等）。',
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: colors.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        // ★ 已连接时把「连的是哪、账号是谁、目录在哪、上次什么时候同步过」
        //   摆出来 —— 换到第二台设备后用户要靠这三行确认自己没连错地方。
        if (connected) ...[
          const SizedBox(height: Sp.x3),
          _connInfo(colors, s),
        ],
        const SizedBox(height: Sp.x4),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            FilledButton.tonalIcon(
              onPressed: _syncBusy ? null : _configureWebdav,
              icon: const Icon(Icons.cloud_outlined, size: 16),
              label: Text(connected ? '重新配置' : '配置云盘'),
            ),
            if (connected) ...[
              OutlinedButton.icon(
                onPressed: _syncBusy ? null : _testSync,
                icon: const Icon(Icons.network_check, size: 16),
                label: const Text('测试连接'),
              ),
              OutlinedButton.icon(
                onPressed: _syncBusy ? null : _syncNow,
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('立即同步'),
              ),
              FilledButton.tonalIcon(
                onPressed: _syncBusy ? null : _backupNow,
                icon: const Icon(Icons.backup_outlined, size: 16),
                label: const Text('立即备份'),
              ),
              OutlinedButton.icon(
                onPressed: _syncBusy ? null : _disconnectSync,
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('断开'),
              ),
            ],
          ],
        ),
        // ★ 忙时给一行明确的进度文案 ——
        //   网络操作要好几秒到几十秒（整包备份更大），按钮变灰但页面
        //   毫无变化的话，用户会以为「点了没反应」而去连点。
        if (_syncBusy) ...[
          const SizedBox(height: Sp.x3),
          _busyLine(colors),
        ],
        if (connected && s != null) ...[
          const SizedBox(height: Sp.x5),
          _autoSection(colors, s),
          const SizedBox(height: Sp.x5),
          _backupSection(colors),
        ],
        if (_err.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _msg(_err, colors.error),
        ],
        if (_ok.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _msg(_ok, colors.primary),
        ],
      ],
    );
  }

  /// 已连接时的连接详情（地址 / 账号 / 目录 / 上次同步）
  ///
  /// 用户会同时开好几台设备，改错地址的代价（数据写到别人的网盘目录里）
  /// 比什么都大，所以这四行常驻。
  Widget _connInfo(ColorScheme colors, SyncSettings? s) {
    final backend = _sync?.backend;
    final rows = <(String, String)>[
      if (backend != null && backend.isNotEmpty) ('服务', backend),
      if (s != null && s.baseUrl.isNotEmpty) ('地址', s.baseUrl),
      if (s != null && s.username.isNotEmpty) ('账号', s.username),
      if (s != null)
        ('目录', s.remoteDir.isEmpty ? '网盘根目录' : s.remoteDir),
      if (s != null && s.lastSyncAt > 0)
        ('上次同步', _fmtTime(s.lastSyncAt)),
      if (s != null && s.lastBackupAt > 0)
        ('上次备份', _fmtTime(s.lastBackupAt)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$k　',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  TextSpan(
                    text: v,
                    style: TextStyle(color: colors.onSurface),
                  ),
                ],
              ),
              style: TextStyle(fontSize: FontSizes.cap, height: 1.6),
            ),
          ),
      ],
    );
  }

  /// 忙时的那一行
  ///
  /// 用固定尺寸的进度圈而不是 `setState` 里的第二个状态 ——
  /// 动画交给 widget 自己跑，避免每次 `setState` 都重建整页。
  Widget _busyLine(ColorScheme colors) => Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: Sp.x2),
          Text(
            _busyHint,
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      );

  /// 自动同步 / 备份设置（只在已连接时显示 —— 这些参数由云端那一路用）
  Widget _autoSection(ColorScheme colors, SyncSettings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subTitle(colors, '自动备份'),
        const SizedBox(height: Sp.x1),
        _note(
          colors,
          '增量同步只传收藏/追更/进度的接口（几 KB）；'
          '「整体备份」才把整包传上去。参考阅读 App 的做法：进度随时同步，'
          '整包一天一份 —— 数据没变动时后端一个写请求都不发。',
        ),
        const SizedBox(height: Sp.x3),
        SettingsGestureToggle(
          label: '自动同步',
          hint: '关掉后只能手动同步 / 手动备份；改完最多 1 分钟生效',
          value: s.autoEnabled,
          onChanged: (v) => _patch(autoEnabled: v),
        ),
        if (s.autoEnabled) ...[
          const SizedBox(height: Sp.x3),
          SettingsGestureToggle(
            label: '数据变动就同步',
            hint: '收藏 / 追更 / 进度一有变化就同步',
            value: s.autoOnChange,
            onChanged: (v) => _patch(autoOnChange: v),
          ),
          const SizedBox(height: Sp.x3),
          SettingsGestureChoice<int>(
            label: '多久看一眼云端（增量同步）',
            options: _withCurrent(const [0, 10, 30, 60], s.autoIntervalMinutes),
            value: s.autoIntervalMinutes,
            labelOf: _intervalLabel,
            onChanged: (v) => _patch(autoIntervalMinutes: v),
          ),
          const SizedBox(height: Sp.x3),
          SettingsGestureChoice<int>(
            label: '整体备份间隔（上传整包）',
            options: _withCurrent(const [
              0,
              60,
              360,
              720,
              1440,
              4320,
              10080,
            ], s.autoBackupIntervalMinutes),
            value: s.autoBackupIntervalMinutes,
            labelOf: _backupIntervalLabel,
            onChanged: (v) => _patch(autoBackupIntervalMinutes: v),
          ),
        ],
        const SizedBox(height: Sp.x3),
        SettingsGestureChoice<int>(
          label: '云端最多保留几份整体备份',
          options: _withCurrent(const [3, 5, 10, 20, 50], s.retainCount),
          value: s.retainCount,
          labelOf: (n) => '$n 份',
          onChanged: (v) => _patch(retainCount: v),
        ),
        const SizedBox(height: Sp.x1),
        _note(
          colors,
          '超出份数的旧备份会在下一次备份成功后自动删掉。'
          '只会删除本应用自己创建的 dsh-backup- 开头的备份，'
          '该目录里的其它文件一律不动。',
        ),
      ],
    );
  }

  /// 云端已有备份的列表（可逐份删除）
  Widget _backupSection(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subTitle(colors, '云端备份（${_backups.length} 份）'),
        const SizedBox(height: Sp.x1),
        _note(
          colors,
          '每份都是完整的 zip（收藏 / 追更 / 进度 / 源配置 / 插件），'
          '按「设备 + 日期时间」命名。',
        ),
        const SizedBox(height: Sp.x3),
        if (_backups.isEmpty)
          Text(
            '云端还没有备份。点上面的「立即备份」传一份。',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
              height: 1.6,
            ),
          )
        else
          for (final e in _backups) _backupRow(colors, e),
      ],
    );
  }

  Widget _backupRow(ColorScheme colors, SyncBackupEntry e) {
    final meta = _parseBackupName(e.name);
    final when = meta.time.isNotEmpty ? meta.time : _fmtTime(e.modified);
    final sub = [
      if (meta.device.isNotEmpty) meta.device,
      _fmtBytes(e.bytes),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  when,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _syncBusy ? null : () => _deleteBackup(e),
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '删除这一份',
          ),
        ],
      ),
    );
  }

  Widget _subTitle(ColorScheme colors, String text) => Text(
    text,
    style: TextStyle(
      fontSize: FontSizes.sm,
      fontWeight: FontWeight.w600,
      color: colors.onSurface,
    ),
  );

  Widget _note(ColorScheme colors, String text) => Text(
    text,
    style: TextStyle(
      fontSize: FontSizes.cap,
      color: colors.onSurfaceVariant,
      height: 1.6,
    ),
  );

  Widget _msg(String text, Color color) => Text(
    text,
    style: TextStyle(fontSize: FontSizes.sm, color: color, height: 1.6),
  );

  // ── 小工具（`backup_panel.dart` 里同名的两个是**私有**的，跨文件用不了；
  //    抽公共 util 要动那个被断言锁住的文件，不划算 —— 这里各写一份）──

  /// 选项里万一没有当前值（例如设置文件是在别处写的），把当前值补进去
  /// —— 否则 `SettingsGestureChoice` 会一个胶囊都不高亮，看起来像没选中。
  static List<int> _withCurrent(List<int> base, int v) {
    if (base.contains(v)) return base;
    return [...base, v]..sort();
  }

  static String _intervalLabel(int m) {
    if (m <= 0) return '仅变动时';
    if (m < 60) return '$m 分钟';
    if (m % 60 == 0) return '${m ~/ 60} 小时';
    return '$m 分钟';
  }

  static String _backupIntervalLabel(int m) {
    if (m <= 0) return '关';
    if (m < 60) return '$m 分钟';
    if (m < 1440) return '${m ~/ 60} 小时';
    if (m % 1440 == 0) return '${m ~/ 1440} 天';
    return '${(m / 1440).toStringAsFixed(1)} 天';
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _fmtTime(int ms) {
    if (ms <= 0) return '时间未知';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// 拆 `dsh-backup-<设备>-<yyyyMMdd>-<HHmmss>.zip` ⇒ 给人看的「时间 + 设备」
  ///
  /// ★ 时间取**文件名里**那个（= 导出时刻，本地时区），不用远端 mtime ——
  ///   后者是服务器收文件的时刻，时区也未必和用户一致。拆不出来才退回 mtime。
  static ({String time, String device}) _parseBackupName(String name) {
    var s = name;
    if (s.startsWith('dsh-backup-')) {
      s = s.substring('dsh-backup-'.length);
    }
    if (s.toLowerCase().endsWith('.zip')) {
      s = s.substring(0, s.length - 4);
    }
    // 设备名里的 `-`/`_` 是保留的（`backup::default_backup_name` 会净化），
    // 所以设备段本身可能含 `-` ⇒ 前一段用贪婪匹配。
    final m = RegExp(r'^(.*)-(\d{8})-(\d{6})$').firstMatch(s);
    if (m == null) return (time: '', device: s);
    final d = m.group(2)!;
    final t = m.group(3)!;
    return (
      time:
          '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)} '
          '${t.substring(0, 2)}:${t.substring(2, 4)}:${t.substring(4, 6)}',
      device: m.group(1) ?? '',
    );
  }
}

/// WebDAV 配置对话框
///
/// [initial] 非空时用当前已保存的地址/用户名/目录预填（重新配置的场景），
/// 为空时默认选中**坚果云**并把地址填好（用户要求：默认也是选择坚果云）。
class _WebdavDialog extends StatefulWidget {
  const _WebdavDialog({this.initial});

  final SyncSettings? initial;

  @override
  State<_WebdavDialog> createState() => _WebdavDialogState();
}

class _WebdavDialogState extends State<_WebdavDialog> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _dir = TextEditingController();

  /// 最近一次点过的预设（**注意**：它只管「提示文案」，
  /// 胶囊的「选中」是另外算的 —— 见下面 `_urlMatchesPreset`）
  _WebdavPreset? _preset;

  /// 地址校验提示（例如还留着 `<主机>` 占位符没替换）
  String _hint = '';

  /// ★ 远程目录是不是**用户自己定的**
  ///
  /// 用户要求（原话）：「webdav 的默认就用那个占位，软件的名字，
  /// **除非用户主动删除那个输入框的名字或者修改才按照用户的意思来**」。
  ///
  /// 所以默认值 = 软件名（[kDefaultWebdavDir]），但**一旦这个值有了
  /// 用户意志**（自己删空、自己改字、或者来自上一次保存的配置），
  /// 就不再被任何自动逻辑覆盖 —— 尤其是切预设时不许"顺手补回来"。
  bool _dirFromUser = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null && init.baseUrl.trim().isNotEmpty) {
      // 重新配置：把当前值摆出来，并高亮能对上的那个预设
      _url.text = init.baseUrl;
      _user.text = init.username;
      _dir.text = init.remoteDir;
      /*
       * ★ 上一次保存下来的目录 = 用户意志（哪怕它是空的）
       *
       * 用户把目录删空存过一次 ⇒ 那次就是要「用根目录」。
       * 再打开对话框时不能因为「现在是空的」又补回默认值。
       */
      _dirFromUser = true;
      for (final p in _kWebdavPresets) {
        if (_normUrl(p.url) == _normUrl(init.baseUrl)) {
          _preset = p;
          break;
        }
      }
    } else {
      // 首次配置：默认坚果云（用户要求），地址与远程目录一起填好
      _preset = _kWebdavPresets.first;
      _url.text = _preset!.url;
      _dir.text = kDefaultWebdavDir;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _dir.dispose();
    super.dispose();
  }

  void _applyPreset(_WebdavPreset p) {
    setState(() {
      _preset = p;
      _hint = '';
      _url.text = p.url;
      /*
       * ★ 远程目录只在**还没有用户意志**时才补默认值
       *
       * 老写法是 `if (_dir.text.trim().isEmpty) _dir.text = 'sourin';`
       * —— 那会把「用户主动删空（= 想用根目录）」当成「还没填」，
       * 切个预设就悄悄补回来。用户明确说过：
       * 「除非用户主动删除那个输入框的名字或者修改才按照用户的意思来」。
       */
      if (!_dirFromUser && _dir.text.trim().isEmpty) {
        _dir.text = kDefaultWebdavDir;
      }
    });
  }

  /// 地址是否与某个预设完全一致 —— 决定胶囊高不高亮。
  /// （用户手改地址之后预设自动"取消选中"，但提示文案留着，免得边改边丢说明）
  bool _urlMatchesPreset(_WebdavPreset p) =>
      _normUrl(_url.text) == _normUrl(p.url);

  /// 比较地址时忽略结尾斜杠与大小写 —— 后端 `normalize_base_only()`
  /// 会把结尾斜杠去掉再存，所以「刚存的地址」和「预设里的地址」可能差一个 `/`。
  static String _normUrl(String s) {
    var t = s.trim();
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final p = _preset;
    return AlertDialog(
      title: const Text('配置云盘（WebDAV）'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('服务预设', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  for (final item in _kWebdavPresets)
                    SettingsGesturePill(
                      text: item.name,
                      selected: _urlMatchesPreset(item),
                      onTap: () => _applyPreset(item),
                    ),
                ],
              ),
              if (p != null && p.note.isNotEmpty) ...[
                const SizedBox(height: Sp.x2),
                Text(
                  p.note,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
              const SizedBox(height: Sp.x3),
              const Text('地址', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _url,
                onChanged: (_) {
                  // 每次输入都要重建：预设胶囊的「选中」是按当前地址算的
                  // （`_urlMatchesPreset`），不重建就不会跟着变。
                  setState(() {
                    _hint = '';
                  });
                },
                decoration: const InputDecoration(
                  hintText: 'https://dav.jianguoyun.com/dav/',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Sp.x3),
              const Text('用户名', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _user,
                decoration: InputDecoration(
                  hintText: p?.userHint ?? '',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Sp.x3),
              const Text('密码', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: p?.passHint ?? '留空则沿用已保存的密码',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Sp.x3),
              const Text('远程目录', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _dir,
                /*
                 * ★ 用户一动手，这个框就归用户了
                 *
                 * 删空 ⇒ 用户要「用根目录」（后端 `remoteDir: ''` 就是根）；
                 * 改成别的 ⇒ 用用户的名字。
                 * 两种情况都不许再被 `_applyPreset` 补回默认值 ——
                 * 这正是用户说的「除非用户主动删除那个输入框的名字
                 * 或者修改才按照用户的意思来」。
                 */
                onChanged: (_) {
                  if (!_dirFromUser) {
                    setState(() => _dirFromUser = true);
                  }
                },
                decoration: const InputDecoration(
                  hintText: '留空则用根目录',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_hint.isNotEmpty) ...[
                const SizedBox(height: Sp.x2),
                Text(
                  _hint,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.error,
                    height: 1.6,
                  ),
                ),
              ],
              const SizedBox(height: Sp.x3),
              /*
               * ★ 提前告知"会先建目录再自检"
               *
               * 否则用户看到目录被自动创建会疑惑。
               */
              Text(
                '配置时会自动创建远程目录（如果还不存在），然后自检连通性。',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final url = _url.text.trim();
            if (url.isEmpty || _user.text.trim().isEmpty) return;
            /*
             * ★ 占位符没替换就拦下来
             *
             * 预设里带 `<主机>` / `<用户名>` / `<UserID>` 的那几个是模板 ——
             * 直接保存必然连接失败（后端会报「无法连接（检查地址与网络）」），
             * 用户只会以为是自己密码错了。这里当场说清楚。
             */
            if (url.contains('<') || url.contains('>')) {
              setState(() => _hint = '地址里还有 <…> 占位符，请先替换成你自己的信息。');
              return;
            }
            Navigator.pop(context, (
              url: url,
              user: _user.text.trim(),
              pass: _pass.text,
              dir: _dir.text.trim(),
            ));
          },
          child: const Text('保存并测试'),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  WebDAV 服务预设
// ═══════════════════════════════════════════════════════════════════════
//
// ★ 收录标准（只收**官方文档能查证**的）：
//   ✅ 有官方 WebDAV 文档的服务：坚果云 / Nextcloud / ownCloud / 群晖 /
//      pCloud / Koofr / Yandex Disk / InfiniCLOUD
//   ❌ 功能存在但地址只有第三方文档（不收录，宁缺毋滥）：
//      123云盘 / 城通网盘 / 天翼云盘 / 中国移动云盘
//   ❌ 明确没有原生 WebDAV（绝不编地址）：
//      百度网盘 / 阿里云盘 / 腾讯微云 / 夸克 / 115 / 迅雷 / Box（官方已下线）
//
// ★ 哪些能直接填、哪些要替换：见每个 `url` 里的 `<…>` 与 `note`。

/// 一个 WebDAV 服务预设
class _WebdavPreset {
  const _WebdavPreset({
    required this.name,
    required this.url,
    this.userHint = '',
    this.passHint = '',
    this.note = '',
  });

  final String name;

  /// 地址模板；含 `<…>` 的需要用户替换
  final String url;

  /// 用户名输入框的提示（各服务要填的东西不一样）
  final String userHint;

  /// 密码输入框的提示（坚果云 / Koofr 等**必须**用应用密码）
  final String passHint;

  /// 选中后显示在地址框下方的说明
  final String note;
}

/// ★ 第一个 = 默认选中项（用户要求：默认也是选择坚果云）
/// ★ WebDAV 远程目录的**默认值 = 软件的名字**
///
/// 用户原话（2026-09-29）：
/// > webdav 的默认就用那个占位，软件的名字，
/// > **除非用户主动删除那个输入框的名字或者修改才按照用户的意思来**
///
/// 所以：默认填它（不是只写进 `hintText` —— 那样看着像填好了其实没填，
/// 与「默认也是选择坚果云」同一个坑），但用户一旦删空或改成别的，
/// 就以用户的为准（见 `_WebdavDialogState._dirFromUser`）。
const String kDefaultWebdavDir = 'sourin';

const List<_WebdavPreset> _kWebdavPresets = [
  _WebdavPreset(
    name: '坚果云',
    url: 'https://dav.jianguoyun.com/dav/',
    userHint: '坚果云账号邮箱（完整邮箱）',
    passHint: '第三方应用密码（不是登录密码）',
    note:
        '密码要去官网「账户信息 → 安全选项 → 第三方应用管理 → '
        '添加应用密码」生成，用登录密码连不上。地址结尾的 / 必须留着。',
  ),
  _WebdavPreset(
    name: 'Nextcloud',
    url: 'https://<主机>/remote.php/dav/files/<用户名>/',
    userHint: 'Nextcloud 用户名',
    passHint: '应用密码（推荐）',
    note:
        '把 <主机> 换成你的域名（装在子目录就带上路径），'
        '<用户名> 换成你的用户名。建议用「应用密码」，官方说还能明显更快。',
  ),
  _WebdavPreset(
    name: 'ownCloud',
    url: 'https://<主机>/remote.php/dav/files/<用户名>/',
    userHint: 'ownCloud 用户名',
    passHint: '应用密码（推荐）',
    note:
        '把 <主机>、<用户名> 换成你自己的。旧版 ownCloud 也可以用 '
        'https://<主机>/remote.php/webdav',
  ),
  _WebdavPreset(
    name: '群晖 NAS',
    url: 'https://<主机>:5006/',
    userHint: 'DSM 用户名',
    passHint: 'DSM 登录密码',
    note:
        '把 <主机> 换成 NAS 的地址或 IP。要先在「套件中心」安装并启用 '
        'WebDAV Server；走 http 的话端口是 5005。',
  ),
  _WebdavPreset(
    name: 'pCloud',
    url: 'https://webdav.pcloud.com',
    userHint: 'pCloud 账号邮箱',
    passHint: '账号密码（不是应用密码）',
    note:
        '欧洲区换成 https://ewebdav.pcloud.com。'
        '加密文件夹（Crypto Folder）WebDAV 访问不到。',
  ),
  _WebdavPreset(
    name: 'Koofr',
    url: 'https://app.koofr.net/dav/Koofr',
    userHint: '注册邮箱',
    passHint: '应用密码（必须）',
    note:
        '主机名区分大小写，照抄即可。没有应用密码就登不上 —— '
        '官方原话是「without an application-specific password, '
        'you will not be able to set up a WebDAV connection」。',
  ),
  _WebdavPreset(
    name: 'Yandex Disk',
    url: 'https://webdav.yandex.ru',
    userHint: 'Yandex 用户名',
    passHint: '应用密码（类型选 WebDAV）',
    note:
        '密码要用「应用密码」，类型选 WebDAV。'
        '2026-06-22 起需要付费的 Yandex 360 套餐；'
        '另外通过 WebDAV 删掉的文件不进回收站。',
  ),
  _WebdavPreset(
    name: 'InfiniCLOUD',
    url: 'https://<UserID>.infini-cloud.net/dav/',
    userHint: 'Connection ID（= UserID）',
    passHint: 'Apps Password',
    note:
        '你的 ID 就在地址里，把 <UserID> 换成它（旧域名 teracloud.jp 还能用）。'
        '要先在 My Page 打开 Apps Connection 再生成 Apps Password。',
  ),
];
