// ═══════════════════════════════════════════════════════════════════════
//  Provider 导入 / 编辑弹窗
// ═══════════════════════════════════════════════════════════════════════
//
// # 这是什么（原版对照）
//
// 原版 `src/views/SettingsView.vue` 的同一个弹窗承担**两件事**：
// ```text
// ① 新增：「导入源」按钮 → openAdd()              (:1413)
// ② 编辑：第三方源卡片的「编辑」→ edit(p)         (:1365)
// ```
// 两者**共用一套表单**，只是编辑时预填原配置、标题/按钮文案变成"保存"。
// 原版注释解释了为什么必须复用而不是各写一套：
// > 后端本来就支持「同 id 覆盖」（`import_declarative_provider` 里的
// > `list.retain(|x| x.id() != manifest.id)`），所以**编辑不需要新命令** ——
// > 把原配置回填给用户改，改完再提交同一个导入接口即可。
//
// # 两种接入方式（原版 `importMode`）
//
// ```text
// 声明式 JSON    零代码   → import_declarative_provider(json)
// HTTP Provider  任意语言 → install_http_provider(base_url, headers)
// ```
//
// # ⚠️ 编辑态**锁住**接入方式切换（原版 :2746 的注释，照抄）
//
// > 编辑时**隐藏接入方式切换**：源的类型（声明式 / HTTP）是它的身份，
// > 改类型等于换一个源，不是「编辑」。锁住可以避免用户在编辑态
// > 切到另一种模式、填完后把原源覆盖成一个完全不同类型的源。
//
// # 为什么抽成独立 widget 文件
//
// `settings_page.dart` 上有 3~4 个代理同时在改。把弹窗做成**自包含**
// widget（只依赖 `SourinApi`，不碰页面私有状态），页面那边只留
// 「打开它 + 拿返回值」两行，冲突面最小。

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import 'overlay_motion.dart';
import '../tokens.dart';

/// 接入方式
enum ImportMode {
  /// 声明式 JSON —— 粘贴 JSON 描述即可接入标准 CMS 站点
  declarative,

  /// 进程外 HTTP Provider —— 独立进程、任意语言
  http,

  /// TVBox 配置（task-5）—— 粘贴 TVBox 的 sites/spider/jar 配置 JSON
  ///
  /// ★ 与前两种的**本质差别**：前两种是「你告诉我要连什么」，
  ///   这一种是「TVBox 已经告诉过一堆站点，我替你挑出能用的」——
  ///   所以提交时要**探测**（并发请求每个 site），可能要等几秒，
  ///   而且**不保证全成功**（type3 要 Java、站点可能挂）。
  ///   界面必须把「跳过了谁、为什么」如实列出来。
  tvbox,
}

/// 弹窗返回的结果
///
/// # 为什么让弹窗自己调 API 并返回结果，而不是"只填表单、由页面提交"
///
/// 两种做法都可行，选这个的理由：**错误信息要留在弹窗里**。
/// 原版的行为是「导入失败 → `importError` 显示在弹窗内，弹窗不关」
/// （`doImport` 里 catch 后写 `importError.value`，**不**调 `closeImport`）。
/// 如果由页面提交，失败时弹窗已经关了，用户看不到自己填的内容错在哪。
sealed class ProviderImportResult {
  const ProviderImportResult();
}

/// 导入 / 保存成功
class ProviderImportDone extends ProviderImportResult {
  const ProviderImportDone({
    required this.name,
    required this.wasEditing,
    this.version = '',
    this.isHttp = false,
    this.isTvbox = false,
    this.importedCount = 0,
    this.skippedCount = 0,
    this.livesCount = 0,
  });

  final String name;

  /// 编辑态（文案"已保存"）还是新增态（文案"已导入"/"已安装"）
  final bool wasEditing;

  /// 源的 `version` 字段
  ///
  /// # ⚠️ 这里踩过一次，记下来（2026-09-24）
  ///
  /// 我第一版写的 `m.apiVersion` —— 但 Dart 的 `ProviderManifest`
  /// **没有** `apiVersion` 字段，契约版本落在 `version` 上
  ///（Rust 的 JSON 名是 `api_version`，见 `models.dart` 的 `fromJson`）。
  ///
  /// 为什么容易错：原版前端叫 `api_version`、Rust 结构体也叫
  /// `api_version`，**只有 Dart 模型把它收进了 `version`**。
  /// 好在这个差异编译期就能发现（analyze 报 undefined getter）——
  /// 但先跑 analyze 再构建，能省一次几分钟的 release 构建。
  final String version;

  /// 是不是 HTTP 源（决定要不要拼「（契约 v…）」）
  ///
  /// ⚠️ **不能**用 `version.isNotEmpty` 当判据：声明式源的 manifest 里
  ///    `version` 是用户自己在 JSON 里写的（常见 "1.0"），
  ///    拼上去会显示成"契约 v1.0" —— 而声明式源**根本没有契约**，
  ///    那是误导。原版只在 `doInstallHttp` 里拼这一段，就这个原因。
  final bool isHttp;

  /// 是不是 TVBox 导入（task-5）
  ///
  /// ★ 与另外两条的差别：TVBox 是**一次导入 N 个源**，所以文案里
  ///   不能有「」括起来的单个名字 —— 说「已导入「xx」」是错的
  ///   （xx 只是最后一个源）。改为报数量 + 跳过数。
  final bool isTvbox;

  /// 成功导入的源数
  final int importedCount;

  /// 被跳过的 site 数（type 不支持 / 探测失败）
  final int skippedCount;

  /// 配置里的直播源数（**本版本不导入**，只回报）
  final int livesCount;

  /// 原版 `flash()` 的文案，逐字对齐
  ///
  /// ```ts
  /// doImport      : wasEditing ? `已保存「${m.name}」` : `已导入「${m.name}」`
  /// doInstallHttp : wasEditing ? `已保存「${m.name}」（契约 v${m.api_version}）`
  ///                             : `已安装「${m.name}」（契约 v${m.api_version}）`
  /// ```
  ///
  /// ⚠️ TVBox 的跳过数**必须**出现在文案里：一句「已导入 5 个源」
  ///    会让用户以为配置里就只有 5 个，剩下的 40 个去哪了永远是个谜。
  String get toast => isTvbox
      ? '已导入 $importedCount 个源'
            '${skippedCount > 0 ? "，跳过 $skippedCount 个" : ""}'
            '${livesCount > 0 ? "，$livesCount 个直播源未导入" : ""}'
      : isHttp
      ? '${wasEditing ? "已保存" : "已安装"}「$name」（契约 v$version）'
      : '${wasEditing ? "已保存" : "已导入"}「$name」';
}

/// 用户取消（关闭弹窗）
///
/// # ★ TVBox 是「先出结果、再关窗」，所以取消态也要能带结果
///
/// 另外两条路径都是"成功即 pop(结果)"，取消必然意味着什么都没做。
/// TVBox 不一样：探测跑完、源**已经落库**了，弹窗里显示的是结果清单，
/// 用户点「完成」才关。如果那时返回 [ProviderImportCancelled]，
/// 设置页会当成"用户什么都没做" → **不刷新列表** → 用户明明导入成功
/// 却看不到新源，必须手动重进页面。
///
/// 所以这里让取消态也能带上 [done]：有结果 = 事实上的完成。
class ProviderImportCancelled extends ProviderImportResult {
  const ProviderImportCancelled({this.done});

  /// 非 null 表示「虽然走的是关闭按钮，但导入已经成功了」
  final ProviderImportDone? done;
}

/// Provider 导入 / 编辑弹窗
class ProviderImportDialog extends StatefulWidget {
  const ProviderImportDialog({super.key, this.seed, this.editingName});

  /// 编辑态的原配置（null = 新增态）
  final ProviderImportSeed? seed;

  /// 编辑态显示在标题里的源名（`seed` 只有 id，名字要从卡片带过来）
  final String? editingName;

  /// 打开「导入源」（新增）—— 清空所有输入
  ///
  /// ⚠️ 原版 `openAdd()` 的注释（照抄动机）：
  /// > 必须显式清空：否则「编辑 A → 关闭 → 点添加」会把 A 的配置带进来，
  /// > 用户以为在新建，实际会覆盖掉 A（同 id 覆盖语义）。
  ///
  /// 我们每次 `showDialog` 都 new 一个 State，天然是空的 ——
  /// 但 `ProviderImportSeed` 一旦传进来就不是了，所以判据只看 seed。
  static Future<ProviderImportResult> showAdd(BuildContext context) async {
    final r = await showAppDialog<ProviderImportResult>(
      context: context,
      builder: (_) => const ProviderImportDialog(),
    );
    return r ?? const ProviderImportCancelled();
  }

  /// 打开「编辑」—— 预填原配置
  ///
  /// `seed == null` 表示后端说这个 id 没有可编辑的配置
  /// （不是第三方源，或 kind 不认识）。
  static Future<ProviderImportResult> showEdit(
    BuildContext context, {
    required ProviderImportSeed seed,
    required String name,
  }) async {
    final r = await showAppDialog<ProviderImportResult>(
      context: context,
      builder: (_) => ProviderImportDialog(seed: seed, editingName: name),
    );
    return r ?? const ProviderImportCancelled();
  }

  @override
  State<ProviderImportDialog> createState() => _ProviderImportDialogState();
}

class _ProviderImportDialogState extends State<ProviderImportDialog> {
  late ImportMode _mode;
  late final TextEditingController _jsonCtl;
  late final TextEditingController _baseCtl;
  late final TextEditingController _headersCtl;

  /// TVBox 配置（JSON 文本**或**配置地址，两者都收）—— task-5
  late final TextEditingController _tvboxCtl;

  /// TVBox 导入的结果明细（成功/跳过/直播），导入完成后显示在弹窗里
  ///
  /// ★ 为什么结果**留在弹窗内**而不是弹完 toast 就关：
  ///   一次导入动辄几十个 site，其中大部分会被跳过（type3/type0/站点挂了）。
  ///   只弹一句「已导入 5 个」用户根本不知道另外 40 个去哪了。
  TvboxImportResult? _tvboxResult;

  /// 错误信息**留在弹窗内**（原版 `importError`）
  String _error = '';

  /// 提交中（按钮禁用 + 转圈）—— 原版没有，但网络请求要几秒，
  /// 不禁用会被连点两次（第二次是覆盖，用户看到两次 toast）
  bool _busy = false;

  bool get _isEditing => widget.seed != null;

  @override
  void initState() {
    super.initState();
    final seed = widget.seed;

    /*
     * ★ 编辑态按 kind 分派回填（原版 `edit()` :1365 的两条分支）
     *
     * ```ts
     * if (cfg.kind === "declarative") {
     *   importMode.value = "declarative";
     *   importJson.value = prettyJson(cfg.json);   // ← 格式化后再填
     * } else {
     *   importMode.value = "http";
     *   httpBase.value = cfg.base_url;
     *   httpHeadersJson.value = Object.keys(cfg.headers || {}).length
     *     ? JSON.stringify(cfg.headers, null, 2) : "";
     * }
     * ```
     */
    _tvboxCtl = TextEditingController();
    if (seed != null && seed.isHttp) {
      _mode = ImportMode.http;
      _jsonCtl = TextEditingController();
      _baseCtl = TextEditingController(text: seed.baseUrl ?? '');
      _headersCtl = TextEditingController(text: _formatHeaders(seed.headers));
    } else {
      _mode = ImportMode.declarative;
      // 新增态 seed 为 null → 空串（原版 `openAdd` 的清空行为）
      _jsonCtl = TextEditingController(
        text: seed == null ? '' : prettyJson(seed.json ?? ''),
      );
      _baseCtl = TextEditingController();
      _headersCtl = TextEditingController();
    }
  }

  @override
  void dispose() {
    _jsonCtl.dispose();
    _baseCtl.dispose();
    _headersCtl.dispose();
    _tvboxCtl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  提交
  // ═══════════════════════════════════════════════════════════════════

  /// 提交声明式 JSON（原版 `doImport` :1455）
  Future<void> _doImport() async {
    setState(() {
      _error = '';
      _busy = true;
    });
    try {
      final m = await SourinApi.importDeclarativeProvider(_jsonCtl.text);
      if (!mounted) return;
      Navigator.pop(
        context,
        ProviderImportDone(
          name: m.name,
          wasEditing: _isEditing,
          // 声明式源**没有契约版本** —— 不传 isHttp，文案就不拼「契约 v…」
          version: m.version,
        ),
      );
    } catch (e) {
      // ⚠️ 失败**不关弹窗** —— 用户填的内容要留着改（原版行为）
      if (mounted) {
        setState(() {
          _error = _humanError(e);
          _busy = false;
        });
      }
    }
  }

  /// 连接并安装 / 保存 HTTP Provider（原版 `doInstallHttp` :1470）
  Future<void> _doInstallHttp() async {
    setState(() {
      _error = '';
      _busy = true;
    });

    // 自定义头先本地解析 —— 格式错就**不必**发请求了（原版 `parseHeaders`）
    Map<String, String>? headers;
    try {
      headers = parseHeaders(_headersCtl.text);
    } catch (e) {
      setState(() {
        _error = _humanError(e);
        _busy = false;
      });
      return;
    }

    try {
      final m = await SourinApi.installHttpProvider(
        _baseCtl.text.trim(),
        headers: headers,
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        ProviderImportDone(
          name: m.name,
          wasEditing: _isEditing,
          version: m.version,
          // ★ HTTP 才拼「（契约 v…）」
          isHttp: true,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _humanError(e);
          _busy = false;
        });
      }
    }
  }

  /// 导入 TVBox 配置（task-5）
  ///
  /// # 与另外两条路径的差别
  ///
  /// 前两条是**一次请求、一个结果**（成功就 pop）。这一条是
  /// **一次请求、一张清单**：后端会并发探测配置里的每个 site，
  /// 报告「导入了谁 / 跳过了谁 / 为什么」。
  ///
  /// 所以这里**不**在成功时 pop —— 先把清单渲染出来给用户看，
  /// 用户点「完成」才关。否则「导入 5 个、跳过 40 个」的结果
  /// 只会变成一句 toast，用户永远不知道另外 40 个去哪了。
  Future<void> _doImportTvbox() async {
    setState(() {
      _error = '';
      _busy = true;
      _tvboxResult = null;
    });
    try {
      final r = await SourinApi.importTvboxConfig(_tvboxCtl.text.trim());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _tvboxResult = r;
        // 多仓时把子仓清单**同时**铺进输入框下方的提示？不做 ——
        // 面板里已经列了可点的子仓，再铺一份是重复信息。
      });
    } catch (e) {
      // ⚠️ 失败**不关弹窗** —— 与另外两条路径一致（原版 importError 行为）
      if (mounted) {
        setState(() {
          _error = _humanError(e);
          _busy = false;
        });
      }
    }
  }

  /// 合并提交入口（底部主按钮按当前 mode 分派）
  Future<void> _submit() => switch (_mode) {
    ImportMode.declarative => _doImport(),
    ImportMode.http => _doInstallHttp(),
    ImportMode.tvbox => _doImportTvbox(),
  };

  /// 关闭弹窗时带什么结果回去
  ///
  /// 见 [ProviderImportCancelled.done] 的说明：TVBox 已经出过结果
  /// 就说明源已经落库了，此时"取消"在事实层面是"完成"。
  ProviderImportResult _closeResult() {
    final r = _tvboxResult;
    if (r == null) return const ProviderImportCancelled();
    // 多仓：一个源都没导入 —— 如实当作"取消"，不弹"导入完成"的 toast
    if (r.multiRepo) return const ProviderImportCancelled();
    return ProviderImportCancelled(
      done: ProviderImportDone(
        // 一次导入 N 个源，没有单个"名字" —— 拿第一个源的名字当代表
        // 只为满足必填参数（toast 在 isTvbox 分支里不用它）
        name: r.imported.isEmpty ? '' : r.imported.first.name,
        wasEditing: false,
        isTvbox: true,
        importedCount: r.imported.length,
        skippedCount: r.skipped.length,
        livesCount: r.lives.length,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  构建
  // ═══════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    /*
     * ⚠️ 这里用 `Theme.of(context).colorScheme`（Material）而不是
     *    `FTheme.of(context).colors`（forui）—— 两种角色名不同：
     *    ```text
     *    Material : onSurface / onSurfaceVariant / outlineVariant
     *    forui    : foreground / mutedForeground / border
     *    ```
     *    混用编译不过（项目里踩过）。本文件全用 Material 侧的角色名，
     *    与 `settings_page.dart` 的既有写法保持一致。
     */
    final colors = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(_titleText),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 接入方式切换（编辑态隐藏，原版 :2751）──
              /*
               * ⚠️ 编辑态对 TVBox 源**不可达**（task-5）
               *
               * TVBox 源没有可回填的原始配置 —— `ProviderImportSeed.fromJson`
               * 对 kind='tvbox' 返回 null，设置页的「编辑」按钮因此不显示
               * （见 lib/core/sourin_api.dart 与 settings_page.dart 的 _canEdit）。
               * 所以下面这个 else 分支的文案里不需要 TVBox 分支；
               * 真要加编辑能力，得先让后端能吐出原始 sites 片段。
               */
              if (!_isEditing) ...[
                _modeTabs(colors),
                const SizedBox(height: Sp.x3),
              ] else
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x3),
                  child: Text(
                    '正在编辑${_mode == ImportMode.http ? "HTTP 插件" : "声明式源"}，'
                    '保存后立即生效',
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),

              // ── 表单 ──
              if (_mode == ImportMode.declarative)
                ..._declarativeForm(colors)
              else if (_mode == ImportMode.http)
                ..._httpForm(colors)
              else
                ..._tvboxForm(colors),

              // ── TVBox 导入结果（导入成功后留在弹窗里给用户看明细）──
              //
              // 多仓是**另一种结局**：后端一个源都没产出，所以必须用
              // 另一块面板（列出子仓供选择），不能显示"成功 0 个"了事。
              if (_tvboxResult != null) ...[
                const SizedBox(height: Sp.x3),
                if (_tvboxResult!.multiRepo)
                  _tvboxMultiRepoPanel(colors, _tvboxResult!)
                else
                  _tvboxResultPanel(colors, _tvboxResult!),
              ],

              if (_error.isNotEmpty) ...[
                const SizedBox(height: Sp.x3),
                Text(
                  _error,
                  style: TextStyle(fontSize: FontSizes.sm, color: colors.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        // 「填入模板」只在新增态显示（原版 :2788 `v-if="!isEditing"`）
        if (!_isEditing && _mode == ImportMode.declarative)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() => _jsonCtl.text = kDeclarativeTemplate),
            child: const Text('填入模板'),
          ),
        /*
         * ★ TVBox 出结果后，「取消」会变成「完成」
         *
         * 为什么不能保留「取消」：用户看到「导入 5 个」的面板后
         * 点「取消」在语义上是**撤销**，但源其实已经落库了 ——
         * 那是最坏的一种误导。所以出结果后这个按钮改名「完成」，
         * 且**照样把结果带回去**（设置页据此刷新列表 + 弹 toast）。
         */
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.pop(context, _closeResult()),
          // 多仓时**仍然是「取消」**：一个源都没导入，叫「完成」是骗人。
          child: Text(
            _tvboxResult == null || _tvboxResult!.multiRepo ? '取消' : '完成',
          ),
        ),
        FilledButton(
          onPressed: _busy || !_canSubmit ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_submitLabel),
        ),
      ],
    );
  }

  String get _titleText {
    if (!_isEditing) {
      return switch (_mode) {
        ImportMode.declarative => '导入声明式源',
        ImportMode.http => '从 URL 安装 HTTP 插件',
        ImportMode.tvbox => '导入 TVBox 配置',
      };
    }
    final name = widget.editingName ?? widget.seed?.id ?? '';
    return '编辑「$name」';
  }

  /// 主按钮文案（原版：新增 `导入` / `连接并安装`，编辑一律 `保存`）
  String get _submitLabel {
    if (_isEditing) return '保存';
    return switch (_mode) {
      ImportMode.declarative => '导入',
      ImportMode.http => '连接并安装',
      // ★ 「导入并探测」而不是「导入」：这个按钮真的会发几十个
      //   并发请求（可能等好几秒），文案必须让用户有心理预期
      ImportMode.tvbox => '导入并探测',
    };
  }

  /// 主按钮可用性（原版 `:disabled="!importJson.trim()"` / `"!httpBase.trim()"`）
  bool get _canSubmit => switch (_mode) {
    ImportMode.declarative => _jsonCtl.text.trim().isNotEmpty,
    ImportMode.http => _baseCtl.text.trim().isNotEmpty,
    // ★ 已经出过结果之后禁用再次提交：结果面板还开着，再点一次
    //   会把面板内容换掉 —— 用户会以为"刚才那次没生效"
    // ★ 多仓结果**不算"已导入"** —— 后端一个源都没产出，
    //   拦住用户再点一次只会让他卡在"请输入"和"不能点"之间。
    //   子仓链接填回输入框后必须能立刻再导一次。
    ImportMode.tvbox =>
      _tvboxCtl.text.trim().isNotEmpty &&
          (_tvboxResult == null || _tvboxResult!.multiRepo),
  };

  Widget _modeTabs(ColorScheme colors) {
    return Row(
      children: [
        _modeTab(colors, ImportMode.declarative, '声明式 JSON', '零代码'),
        const SizedBox(width: Sp.x2),
        _modeTab(colors, ImportMode.http, 'HTTP Provider', '任意语言'),
        const SizedBox(width: Sp.x2),
        // ⚠️ 三列在窄屏（手机逻辑宽 411）会被挤成一条竖线 ——
        //    文案取最短路（'TVBox' + 'sites/spider'）
        _modeTab(colors, ImportMode.tvbox, 'TVBox 配置', 'sites/spider'),
      ],
    );
  }

  Widget _modeTab(
    ColorScheme colors,
    ImportMode mode,
    String label,
    String hint,
  ) {
    final active = _mode == mode;
    return Expanded(
      child: InkWell(
        onTap: _busy ? null : () => setState(() => _mode = mode),
        borderRadius: Radii.rMd,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x3,
            vertical: Sp.x2,
          ),
          decoration: BoxDecoration(
            color: active
                ? colors.primaryContainer
                : colors.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: Radii.rMd,
            border: Border.all(
              color: active ? colors.primary : colors.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? colors.onPrimaryContainer : colors.onSurface,
                ),
              ),
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
      ),
    );
  }

  /// 声明式 JSON 表单（原版 :2774）
  List<Widget> _declarativeForm(ColorScheme colors) => [
    Text(
      '粘贴 JSON 描述即可接入标准 CMS 站点，无需写代码。'
      '字段用 JSONPath 映射（如 \$.list）。',
      style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
    ),
    const SizedBox(height: Sp.x3),
    TextField(
      controller: _jsonCtl,
      maxLines: 14,
      minLines: 8,
      enabled: !_busy,
      // 每次输入都要重算主按钮的可用性（原版是 v-model 双向绑定）
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.cap),
      decoration: InputDecoration(
        hintText: kDeclarativeTemplate,
        border: const OutlineInputBorder(),
        hintStyle: TextStyle(
          fontFamily: 'monospace',
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    ),
  ];

  /// HTTP Provider 表单（原版 :2798）
  List<Widget> _httpForm(ColorScheme colors) => [
    Text(
      '填入一个实现了契约的 HTTP 服务地址。该 Provider 运行在独立进程，'
      '可用任意语言编写，与主程序天然隔离 —— 安装时会先握手校验契约版本。',
      style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
    ),
    const SizedBox(height: Sp.x3),
    TextField(
      controller: _baseCtl,
      enabled: !_busy,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.sm),
      decoration: const InputDecoration(
        hintText: 'http://127.0.0.1:8787',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: Sp.x3),
    Text(
      '自定义请求头（可选，JSON 对象）',
      style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
    ),
    const SizedBox(height: Sp.x1),
    TextField(
      controller: _headersCtl,
      maxLines: 3,
      minLines: 2,
      enabled: !_busy,
      style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.cap),
      decoration: const InputDecoration(
        hintText: '{ "Authorization": "Bearer xxx" }',
        border: OutlineInputBorder(),
      ),
    ),
  ];

  /// TVBox 配置表单（task-5）
  ///
  /// 一个输入框收两种东西：**配置 JSON 本体**（粘贴）或**配置地址**
  /// （URL，后端自己去拉）。后端靠首字符是不是 `{` 来判，见
  /// `rust/sourin_core/src/tvbox.rs` 的 `import_tvbox_config`。
  List<Widget> _tvboxForm(ColorScheme colors) => [
    Text(
      '粘贴 TVBox 配置 JSON（含 sites 段），或直接填配置地址。'
      '导入时会并发探测每个站点，只把能连上的建成内容源 —— '
      'type1（苹果 CMS）可用；type3 需要 Java JAR / drpy 引擎，本机跑不了；'
      'type0/4 是别的协议。直播源（lives）本版本不导入。',
      style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
    ),
    const SizedBox(height: Sp.x3),
    TextField(
      controller: _tvboxCtl,
      maxLines: 14,
      minLines: 8,
      enabled: !_busy,
      // 每次输入都要重算主按钮的可用性
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.cap),
      decoration: InputDecoration(
        hintText: kTvboxTemplate,
        border: const OutlineInputBorder(),
        hintStyle: TextStyle(
          fontFamily: 'monospace',
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    ),
  ];

  /// 多仓配置面板（task-12）
  ///
  /// # 这是什么情况
  ///
  /// 有些 TVBox 配置只有 `urls`（指向别的配置），没有 `sites` —— 这叫「多仓」。
  /// 它**本身不是一份能用的配置**，但里面的每个子仓都是。
  ///
  /// # ★ 为什么不弹错误
  ///
  /// 旧行为是 `Err("这是一份多仓配置…子仓：· 名称 链接")` ——
  /// 用户拿到一段红字，得自己从里面抠出链接、复制、粘回输入框。
  /// 现在后端结构化返回子仓清单，这里列成**可点的行**：点一下就把地址
  /// 填回输入框，用户再点一次导入即可。
  ///
  /// ⚠️ 但仍然**不会**假装导入成功 —— 面板标题就明说"不能直接导入"，
  ///    成功数仍是 0（后端没产出任何源）。
  Widget _tvboxMultiRepoPanel(ColorScheme colors, TvboxImportResult r) {
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rMd,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '这是一份「多仓」配置（只有 urls，没有 sites），不能直接导入',
            style: TextStyle(
              fontSize: FontSizes.sm,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Sp.x1),
          Text(
            '它指向 ${r.repos.length} 个子仓。点其中一个，地址会自动填进上面的输入框，'
            '再点一次「导入」即可。',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Sp.x2),
          for (final repo in r.repos.take(20))
            InkWell(
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _tvboxCtl.text = repo.url;
                      _error = '';
                      _tvboxResult = null;
                    }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.x1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right,
                      size: 16,
                      color: colors.primary,
                    ),
                    const SizedBox(width: Sp.x1),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            repo.name.isEmpty ? repo.url : repo.name,
                            style: TextStyle(
                              fontSize: FontSizes.cap,
                              color: colors.onSurface,
                            ),
                          ),
                          Text(
                            repo.url,
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
              ),
            ),
          if (r.repos.length > 20)
            Text(
              '…另有 ${r.repos.length - 20} 个子仓未列出',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  /// TVBox 导入结果面板（task-5）
  ///
  /// # 为什么不是一句 toast
  ///
  /// 一份真实 TVBox 配置动辄 40~60 个 site，其中能用的往往只有几个。
  /// 「已导入 5 个源」这句话本身没错，但它**丢掉了剩下 50 多个 site 的去向** ——
  /// 用户没法判断"是我这份配置太老，还是这个 App 能力太弱"。
  /// 所以这里把三类清单都列出来，每条带原因。
  Widget _tvboxResultPanel(ColorScheme colors, TvboxImportResult r) {
    final ok = r.imported;
    final skip = r.skipped;
    final lives = r.lives;
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rMd,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '成功 ${ok.length} 个 · 跳过 ${skip.length} 个'
            '${lives.isNotEmpty ? " · 直播源 ${lives.length} 个（未导入）" : ""}'
            '（配置共 ${r.totalSites} 个 site）',
            style: TextStyle(
              fontSize: FontSizes.sm,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          if (ok.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            Text(
              '✓ 可用',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            for (final s in ok.take(20))
              Text(
                '· ${s.name}（${s.categories} 类 / ${s.total} 部）',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurface,
                ),
              ),
          ],
          if (skip.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            Text(
              '✗ 跳过',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            for (final s in skip.take(20))
              Text(
                '· ${s.name}：${s.reason}',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（可单测）
// ═══════════════════════════════════════════════════════════════════════

/// 导入模板（原版 `SettingsView.vue:837` 的 `TEMPLATE`，逐字照抄）
///
/// 原版注释：`/** 导入模板（用户改改就能用） */`
///
/// ⚠️ 内容**不要"美化"或改字段名** —— 这份模板是给用户当范例改的，
///    里面 `{category}` / `{page}` / `{id}` / `{keyword}` 占位符的
///    写法就是声明式源的参数契约。改错一个词，用户照着填的源会解析失败。
const String kDeclarativeTemplate = '''
{
  "id": "demo",
  "name": "示例站",
  "base": "https://api.example.com",
  "headers": {
    "User-Agent": "Mozilla/5.0",
    "Referer": "https://example.com/"
  },
  "capabilities": { "vod": true, "search": true },
  "endpoints": {
    "categories": {
      "path": "",
      "params": { "ac": "class" },
      "map": {
        "items": "\$.class",
        "id": "\$.type_id",
        "title": "\$.type_name"
      }
    },
    "list": {
      "path": "",
      "params": { "ac": "videolist", "t": "{category}", "pg": "{page}" },
      "map": {
        "items": "\$.list",
        "id": "\$.vod_id",
        "title": "\$.vod_name",
        "cover": "\$.vod_pic",
        "subtitle": "\$.vod_remarks"
      }
    },
    "detail": {
      "path": "",
      "params": { "ac": "detail", "ids": "{id}" },
      "map": {
        "items": "\$.list",
        "id": "\$.vod_id",
        "title": "\$.vod_name",
        "episodes": "\$.list[0].vod_play_url"
      }
    },
    "search": {
      "path": "",
      "params": { "ac": "videolist", "wd": "{keyword}", "pg": "{page}" },
      "map": {
        "items": "\$.list",
        "id": "\$.vod_id",
        "title": "\$.vod_name"
      }
    }
  }
}''';

/// TVBox 配置模板（task-5）
///
/// # 为什么给一份「能跑的」而不是「全字段的」
///
/// 用户手里通常已经有真配置（网上抄的 / 别人发的），这个 hint 的
/// 作用只是**让用户一眼确认格式对不对** —— 所以用最小可跑形状：
/// 一个 sites 数组 + 一个 type1 站点。
///
/// ⚠️ 别把 hint 写成完整 TVBox 配置：那有 60+ 行、含 jar/spider/lives，
///    输入框里会糊成一团，用户反而看不清自己该粘什么。
const String kTvboxTemplate = '''
{
  "sites": [
    {
      "key": "demo",
      "name": "示例采集",
      "type": 1,
      "api": "https://example.com/api.php/provide/vod",
      "searchable": 1,
      "quickSearch": 1
    }
  ]
}''';

/// 尽量美化 JSON；**解析失败就原样返回**
///
/// 原版 `prettyJson`（:1431）：
/// ```ts
/// try { return JSON.stringify(JSON.parse(raw), null, 2); }
/// catch { return raw; }
/// ```
/// 原版注释点出了为什么不能把异常抛出去：
/// > 用户手改坏了也能看到原文 —— 否则打开编辑弹窗的瞬间就报错，
/// > 用户连自己错在哪都看不到。
///
/// ⚠️ Dart 的 `jsonDecode` 对**顶层非对象**（如 `123`、`"x"`）也成功 ——
///    我们会 `jsonEncode` 回去，结果一样，无需特判。
String prettyJson(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return raw;
  try {
    final v = jsonDecode(raw);
    return const JsonEncoder.withIndent('  ').convert(v);
  } catch (_) {
    return raw;
  }
}

/// 解析自定义头输入（空 = 无头）
///
/// 原版 `parseHeaders`（:1440）的两条错误消息**逐字对齐**：
/// ```text
/// 自定义头不是合法 JSON
/// 自定义头必须是 JSON 对象，如 {"Authorization":"Bearer xxx"}
/// ```
/// 返回 `null` 表示"用户没填"（原版返回 `undefined`，
/// 后端 `headers: Option<HashMap>` 收到缺省就是无头）。
Map<String, String>? parseHeaders(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;

  dynamic v;
  try {
    v = jsonDecode(t);
  } catch (_) {
    throw const FormatException('自定义头不是合法 JSON');
  }
  if (v is! Map) {
    throw const FormatException(
      '自定义头必须是 JSON 对象，如 {"Authorization":"Bearer xxx"}',
    );
  }
  return v.map((k, val) => MapEntry('$k', '$val'));
}

/// 把 headers 渲染成回填用的 JSON 文本（空 Map → 空串）
///
/// 原版：
/// ```ts
/// httpHeadersJson.value = Object.keys(cfg.headers || {}).length
///   ? JSON.stringify(cfg.headers, null, 2)
///   : "";
/// ```
/// 空的时候给空串而不是 `{}` —— 否则用户看到的是一对花括号，
/// 以为"这里有配置"。
String _formatHeaders(Map<String, String> headers) =>
    headers.isEmpty ? '' : const JsonEncoder.withIndent('  ').convert(headers);

/// 把异常转成用户能看懂的一行字
///
/// 后端的错误信息是 `"{:?}: {}"` 格式（`SourinCoreException` 的消息里
/// 常带 `InvalidJson: ...` 这样的前缀）。这里**不**做花哨的翻译 ——
/// 原版直接把 `String(e)` 塞进 `importError`，我们保持一致：
/// 用户需要看到后端的**原始**报错才能判断是不是自己 JSON 写错了。
String _humanError(Object e) {
  final s = e.toString();
  // `SourinCoreException` 的 toString 会带类型名，剥掉一层让文案短些
  final m = RegExp(r'^(SourinCoreException|FormatException|Exception):\s*')
      .firstMatch(s);
  return m == null ? s : s.substring(m.end);
}
