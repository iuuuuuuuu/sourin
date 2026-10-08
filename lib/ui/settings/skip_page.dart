// ═══════════════════════════════════════════════════════════════════════
//  二级页：片头片尾（2026-09-25 任务 ㉙ 从 settings_page.dart 搬来）
// ═══════════════════════════════════════════════════════════════════════
//
// # 搬运说明
//
// 原来这段是 `settings_page.dart` 里 `title: '片头片尾'` 那个 `_Block`，
// 以及它依赖的三样东西：
// ```text
// _skipMarkers 字段 + loadAll() 里的赋值
// _clearSkipMarker()          二次确认 + 清除 + 重拉
// _openSkipHistoryDialog()    showDialog
// _SkipHistoryDialog          弹窗本体
// _SkipMarkerRow              弹窗里的一行
// ```
// 因为二级页是**独立路由**、拿不到设置页的 State，所以这五样**一起搬过来**，
// 本页自己拉数据（`SourinApi.listSkipMarkers()`）。
//
// ★ 逻辑一字未改 —— 只把"读父级字段"改成"读自己的字段"。
//
// # 原注释照搬：为什么要有这个区块
//
// 片头片尾是在**播放器**里设置的（「片头片尾」按钮）。
// 但设完之后用户在设置页**看不到自己设了哪些** —— 想取消
// 某一个就必须回去把那集找出来重播一遍。这个区块解决它。
//
// # ★★★ 2026-09-25 用户要求：**改成「按钮 → 弹窗」**
//
// 用户原话：
// > 片头片尾，我说了 **做成按钮，点击后弹窗显示配置的影片的片头片尾**，
// > 而不是平铺在上面
//
// # 为什么平铺是错的（量化一下）—— ⚠️ 这条只对**一级页**成立
//
// 原来把 `_skipMarkers` 逐行铺在设置页里。设了 N 个作品后
// 这个区块高 ≈ `N × 60px`：
// ```text
// N = 5    300px   还能忍
// N = 20  1200px   ★ 把下面所有区块推到屏幕外
// ```
// 片头片尾是**低频**配置（设一次用很久），却吃掉设置页
// 最多的垂直空间 —— 低频内容挤占高频入口。
//
// ══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-26 task-52：上面那条**已被两次新指令覆盖** —— 现在是平铺
// ══════════════════════════════════════════════════════════════════════
//
// # 指令沿革（按时间顺序，三次，别只读最后一条）
//
// ```text
// ① 2026-09-25 上旬  「做成按钮，点击后弹窗…而不是平铺在上面」
//                    ⇒ 一级页挤不下，收进弹窗。**当时是对的**。
// ② 2026-09-25 任务㉙  「抽到第二级页了，可以平铺了，然后加一个搜索功能，
//                     这个搜索要固定在上面，结果在下面滚动」
//                    ⇒ 二级页是独立整页，不再抢高度 ⇒ 平铺 + 固定搜索框。
//                       **但当时按钮/弹窗被当成"次要入口"保留了**。
// ③ 2026-09-26 本次   「设置页面的 片头片尾 二级页，**重叠了功能**，
//                     就还有一个 片头片尾的管理」
//                    ⇒ ★ 用户点名①留下的那个入口是**功能重复** ⇒ 删掉。
// ```
//
// # 现在的结构（task-52 之后）
//
// ```text
// 片头片尾                    [N 个作品已设置]
// ┌──────────────────────────────────────────┐
// │ 🔍 搜索作品标题                3 / 3      │ ← pinnedHeader（不随滚动）
// ├──────────────────────────────────────────┤
// │ 无职转生 第三季…                          │
// │   片头 00:05-01:09 · 片尾 未设置   [清除] │ ← 平铺（唯一入口）
// │ …                                        │
// └──────────────────────────────────────────┘
// ```
//
// ⚠️ 那条"为什么平铺是错的"的量化理由（`N=20 → 1200px`）针对的是
//    **一级页**（要跟别的区块抢高度）。二级页是**独立整页**，自己就是
//    滚动容器 ⇒ 那个理由在这里**不成立**。这也是为什么平铺是安全的。
//
// ⚠️ 空态仍然**保留引导文案**（原版也是）——
//    没设置过时告诉用户去哪设，而不是一个点了没用的按钮。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import '../widgets/overlay_motion.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

class SkipMarkersSettingsPage extends StatefulWidget {
  const SkipMarkersSettingsPage({super.key, this.initialMarkersForTest});

  /// ★ 测试注入口（`@visibleForTesting` 语义）—— 预置列表，**跳过 FFI 拉取**
  ///
  /// # 为什么必须有这个口子
  ///
  /// 本页真实数据来自 `SourinApi.listSkipMarkers()`（走 FFI 到 Rust 核心）。
  /// `flutter test` 里没有核心 DLL ⇒ 该调用**抛异常**（项目已知：
  /// `Failed to load dynamic library 'sourin_core.dll'`）⇒ 列表恒为空
  /// ⇒ 所有"平铺 / 搜索 / 固定"的断言都变成对**空列表**的断言。
  ///
  /// ⚠️ 这就落进铁律 149 的陷阱：**候选集为空时，全称断言恒真**
  ///    （"搜'作品2'后只剩 0 条"会和"根本没数据"看起来一样）。
  ///    所以必须能注入数据，否则测的是空气。
  ///
  /// ⚠️ 生产代码**永远不传**它（调用点只有一个：
  ///    `settings_page.dart` 的 `_openSubPage(const SkipMarkersSettingsPage())`）
  ///    ⇒ 传 null 时行为与改前**逐字相同**。
  final List<SkipMarker>? initialMarkersForTest;

  @override
  State<SkipMarkersSettingsPage> createState() =>
      _SkipMarkersSettingsPageState();
}

class _SkipMarkersSettingsPageState extends State<SkipMarkersSettingsPage> {
  List<SkipMarker> _skipMarkers = [];

  /// 搜索关键词（空 = 不搜索）
  ///
  /// # 用户要求
  ///
  /// > 然后加一个 **搜索功能**，这个搜索要**固定在上面**
  ///
  /// # 搜什么（我的判断 —— 见任务描述里的依据）
  ///
  /// ```text
  /// ① 数据面：SkipMarker 有 title / provider / nativeId（models.dart L1631）
  /// ② 形态面：用户说「搜索固定在上面，结果在下面滚动」= 列表 + 搜索框形态，
  ///    而改前二级页**根本没有列表** ⇒ 他就是要把列表铺出来再配搜索
  /// ③ 排除"搜设置项"：本页只有 1 个区块 + 1 个按钮，没有可搜项集
  /// ```
  /// ⇒ 搜**作品**。标题为主，provider 兜底（用户可能记得"是 cycani 设的"）。
  ///
  /// ⚠️ 与 `episode_strip.dart` 的 `_query` 同一范式（单一数据源：
  ///    过滤逻辑集中在 `_shown`，控件只报 `onChanged`）。
  String _query = '';
  final _queryCtrl = TextEditingController();

  /// 过滤后的列表（**唯一**的过滤点 —— 别处不许再过滤一次）
  ///
  /// ⚠️ 大小写不敏感 + 去首尾空格：用户不会精确输入。
  List<SkipMarker> get _shown {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _skipMarkers;
    return [
      for (final m in _skipMarkers)
        if (m.title.toLowerCase().contains(q) ||
            m.provider.toLowerCase().contains(q) ||
            m.nativeId.toLowerCase().contains(q))
          m,
    ];
  }

  /// 清除中的标记（防止连点重复发请求）
  bool _busy = false;

  /// 页内提示（替代设置页的 `_flash`）
  ///
  /// ⚠️ 二级页没有设置页那套全局 Toast 层，所以就地显示一行。
  ///    用 `Timer` 而不是 `Future.delayed` —— 后者在 widget 销毁后
  ///    仍会跑（本项目已有教训：设置页 `_flash` 的 3 秒延迟
  ///    会让 widget 测试报 "A Timer is still pending"）。
  String? _toast;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    /*
     * ★ 有测试注入 ⇒ **不拉 FFI**（测试环境没有核心 DLL，拉了必抛）
     *   没有 ⇒ 走真实路径（生产行为不变）
     */
    final seeded = widget.initialMarkersForTest;
    if (seeded != null) {
      _skipMarkers = seeded;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final markers = await SourinApi.listSkipMarkers();
      if (!mounted) return;
      setState(() => _skipMarkers = markers);
    } catch (e) {
      debugPrint('[SKIPPAGE] 片头片尾列表读取失败: $e');
      if (mounted) _flash('加载失败：$e');
    }
  }

  void _flash(String msg) {
    if (!mounted) return;
    _toastTimer?.cancel();
    setState(() => _toast = msg);
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  /// 清除某个作品的片头片尾
  ///
  /// ⚠️ **必须二次确认** —— 这是**不可撤销**的破坏性操作：
  ///    用户可能花了几分钟精调那四个端点，误点一下就没了。
  ///    原版 `SettingsView.vue` 的同类操作也都带确认。
  ///
  /// ⚠️ 清除成功后要**重新拉列表**而不是本地 `remove` ——
  ///    后端是真相（可能有其它设备的同步改动）。
  Future<void> _clearSkipMarker(SkipMarker m) async {
    final name = m.title.isNotEmpty ? m.title : '${m.provider}:${m.nativeId}';
    final ok = await _confirm(
      title: '清除片头片尾',
      message:
          '确定清除「$name」的片头片尾设置吗？\n\n'
          '清除后播放这个作品时不再自动跳过。此操作无法撤销。',
      okLabel: '清除',
      cancelLabel: '取消',
    );
    if (!ok) return;
    try {
      await SourinApi.clearSkipMarker(m.provider, m.nativeId);
      try {
        final fresh = await SourinApi.listSkipMarkers();
        if (mounted) setState(() => _skipMarkers = fresh);
      } catch (e) {
        debugPrint('[SKIPPAGE] 清除后刷新失败: $e');
      }
      _flash('已清除「$name」的片头片尾');
    } catch (e) {
      _flash('清除失败：$e');
    }
  }

  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 2026-09-26 task-52：`_openSkipHistoryDialog()` + `_SkipHistoryDialog`
   *      **整段删除** —— 用户报的「重叠了功能」就是这个
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 用户原话
   *
   * > 设置页面的 片头片尾 二级页，**重叠了功能**，就还有一个 片头片尾的管理
   *
   * # 我实测到的重复（不是读代码推的）
   *
   * 真机隔离实例 + 用户真实数据的只读副本，进「设置 → 片头片尾」二级页：
   * ```text
   * 屏幕上**同时**存在两套"管理片头片尾"：
   *   ① 平铺的 3 行（标题 + 片头 00:05-01:09 · 片尾未设置 + 每行「清除」）
   *   ② 一个按钮「查看 / 管理片头片尾（3）」
   * ⇒ 点 ② 弹出的 `_SkipHistoryDialog` 里，是**逐字相同的 3 行**
   *   （同样标题 / 同样区间 / 同样「清除」）
   * 截图：.probe\t52_subpage.png（两套并存）
   *       .probe\t52_dup_dialog.png（弹窗内容与背后的平铺行完全一致）
   * ```
   *
   * # 为什么删的是按钮/弹窗，而不是删平铺列表
   *
   * 用户**上一条**要求就是「片头片尾抽到第二级页了，**可以平铺了**」
   * （逐字见本文件头 + `test/skip_page_search_test.dart` 文件头），
   * 平铺列表是**用户明确要的**；而按钮/弹窗是更早那版（一级页挤不下
   * 才收进弹窗）的**遗留物** —— 搬到二级页之后它就没有存在理由了：
   * 二级页是独立整页，不再跟别的区块抢高度。
   *
   * ⇒ 删「按钮 + 弹窗」= 删掉**唯一**那个多余入口，保留用户要的平铺。
   *
   * ⚠️ 这一条**推翻了** task-44 ⑤ 时 lead 的裁决（当时判"弹窗作为
   *    次要入口无害，保留"）。依据是：用户在那之后**又**明确说
   *    「重叠了功能」⇒ 新指令覆盖旧裁决。如实记录，不偷偷改。
   */

  /// 通用二次确认（从设置页搬来，本页自用）
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

  /// 页内提示（顺手抽出来 —— 两种结构都要用）
  Widget? _toastWidget(ColorScheme colors) {
    if (_toast == null) return null;
    // ★ 内容带（t509）：带已由 `SettingsSubPage.build` 提供 ⇒ 这里归零。
    return Padding(
      padding: EdgeInsets.zero,
      child: Text(
        _toast!,
        style: TextStyle(fontSize: FontSizes.sm, color: colors.primary),
      ),
    );
  }

  /// 「片头片尾」区块 —— **只剩计数**（管理入口已删，见上面的 task-52 说明）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26 task-52：按钮（`OutlinedButton` → 弹窗）**已删除**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 用户原话：
  /// > 设置页面的 片头片尾 二级页，**重叠了功能**，就还有一个 片头片尾的管理
  ///
  /// 实测证据与删除理由见本文件里 `_openSkipHistoryDialog` 那段注释
  /// （截图 `.probe\t52_subpage.png` / `.probe\t52_dup_dialog.png`）。
  ///
  /// ⇒ 现在这个区块**只负责**在空态给引导文案；有数据时的标题 + 计数
  ///   仍由它承担（`trailing`），唯一的"管理"入口就是下面平铺的列表。
  Widget _block(ColorScheme colors) => SettingsBlock(
    title: '片头片尾',
    trailing: _skipMarkers.isEmpty
        ? null
        : Text(
            '${_skipMarkers.length} 个作品已设置',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
    children: [
      if (_skipMarkers.isEmpty)
        Text(
          '还没有设置过片头片尾。在播放器底栏点「片头片尾」可以设置，'
          '设好后会自动跳过。',
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: colors.onSurfaceVariant,
          ),
        ),
    ],
  );

  /// ★ 返回键的**分层**拦截（task-14 ⑤）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # 借鉴了什么（FlClash）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// .probe\refs\FlClash\lib\widgets\scaffold.dart:497-500
  ///   BackLayerScope(onBack: _handleExitAppBarLayer, child: ...)
  /// ```
  /// 它的页面可以有**内层**（搜索层 / 多选层）：返回键先退最上面那一层，
  /// 层退光了才离开页面。
  ///
  /// # 改前的行为（用户可见缺陷）
  /// ```text
  /// 本页的搜索框是**内层**。改前按返回（Esc / 遥控器返回）直接
  /// `Navigator.maybePop()` **离开整页** ⇒ 用户刚输入的关键词无声丢失；
  /// 想「只退一层」必须先精确点中搜索框右侧那个 16px 的清除图标
  /// —— 在遥控器上基本点不中。
  /// ```
  ///
  /// # 改后
  /// ```text
  /// 搜索词非空 ⇒ 返回键只**清空搜索**（并收起软键盘），不离开页面；
  /// 搜索词已空 ⇒ 与改前完全一致，`Navigator.maybePop()` 退出页面。
  /// ```
  ///
  /// ⚠️ 只在**有搜索框**时才有意义（`_skipMarkers` 为空时空态走原来的
  ///    children 路径、不显示搜索框）—— 但那时 `_query` 本来就是空，
  ///    这个回调会如实返回 `false`，行为与改前一致。
  bool _onBackIntercept(BuildContext context) {
    if (_query.isEmpty) return false;
    _queryCtrl.clear();
    setState(() => _query = '');
    FocusManager.instance.primaryFocus?.unfocus();
    return true;
  }

  /// ★ 搜索框（**固定在顶部**，不随结果滚动）
  ///
  /// # 用户原话
  ///
  /// > 加一个 **搜索功能**，这个搜索要**固定在上面**，结果**在下面滚动**
  ///
  /// # 为什么自己写一个而不是裸装 `TextField`
  ///
  /// ```text
  /// ① 要带"清除"按钮 —— 输了字发现搜错，得能一键清空
  /// ② 要显示"命中几条" —— 用户得知道过滤掉多少（否则以为数据丢了）
  /// ③ 要统一外观 —— 与设置页的 card 语言一致
  /// ```
  /// ⚠️ 与 `episode_strip.dart` 的 `_EpisodeSearchField` 同一范式：
  ///    它是**纯展示 + 回调**，不持有过滤逻辑（过滤只在 `_shown`）。
  Widget _searchBar(ColorScheme colors) => Padding(
    // ★ 内容带（t509）：带已由 `SettingsSubPage.build` 提供 ⇒ 这里归零。
    padding: EdgeInsets.zero,
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _queryCtrl,
            onChanged: (v) {
              /*
                   * ⚠️ 搜索时把**滚动位置归零**。
                   *
                   * 否则结果换了、视口还停在旧位置 —— 看起来像"搜索没生效"
                   * （结果其实在上面）。与 `episode_strip.dart` 的
                   * `_EpisodeSearchField` 用法一致。
                   */
              setState(() => _query = v);
            },
            style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索作品标题',
              hintStyle: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
              prefixIcon: Icon(
                Icons.search,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIcon: _queryCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      tooltip: '清除',
                      onPressed: () {
                        _queryCtrl.clear();
                        setState(() => _query = '');
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Sp.x2,
                vertical: Sp.x2,
              ),
              filled: true,
              fillColor: colors.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Sp.x2),
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Sp.x2),
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
            ),
          ),
        ),
        /*
             * ★ 计数 —— 两个读数，各有用途
             *
             * ```text
             * 没搜索：「共 N 个」        ← 原来由 `_block` 的 trailing 承担
             * 有搜索：「N / M」          ← 让用户知道"过滤掉了多少"
             * ```
             *
             * ⚠️ task-52 之后 `_block` 在数据态**不再渲染**（见 `_resultList`），
             *    所以"共几个"这个读数**必须**搬到这里 —— 否则用户看不到
             *    自己一共设了多少个作品（那是删按钮时容易连带丢掉的信息）。
             */
        const SizedBox(width: Sp.x2),
        Text(
          _query.trim().isEmpty
              ? '共 ${_skipMarkers.length} 个'
              : '${_shown.length} / ${_skipMarkers.length}',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  /// ★ 平铺的结果列表（**在搜索框下面滚动** —— 用户要求）
  ///
  /// ⚠️ `ListView.builder` 而不是 `Column`：
  ///    设了 N 个作品时 N 可能上百，`Column` 会一次性构建全部行。
  ///    `builder` 只构建可视区内的（懒构建）。
  ///
  /// ⚠️ 底部留 `Sp.bottomBarInset`：悬浮底栏**盖在所有路由之上**，
  ///    不留白最后一行会被遮住（与设置页的处理一致）。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26 task-52：这里**不再调用 `_block()`**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 删掉那个「查看 / 管理片头片尾（N）」按钮之后，`_block()` 在**有数据**
  /// 时只剩一个标题行（`SettingsBlock(title:'片头片尾')` + 计数），
  /// 里面**一个子项都没有** —— 那就是一张**空卡片**，而且它的标题
  /// `片头片尾` 跟**页面标题**重复（页面标题已经叫「片头片尾」）。
  ///
  /// 所以数据态**整个不渲染区块**：计数改由搜索框那一行承担
  /// （见 `_searchBar` 的 `共 N 个` / `N / M`）。
  /// ⇒ 页面上"片头片尾"只出现**一次**，管理入口也只有**一个**（平铺列表）。
  ///
  /// ⚠️ `_block()` 本身**保留** —— 空态仍然要走它（那条引导文案
  ///    「还没有设置过片头片尾…」是用户需要的信息，也是
  ///    `test/skip_history_dialog_test.dart` 守着的既有要求）。
  Widget _resultList(ColorScheme colors) {
    final rows = _shown;

    return ListView(
      clipBehavior: Clip.antiAlias,
      padding: EdgeInsets.only(bottom: Sp.bottomBarInset + Sp.x4),
      children: [
        if (_toastWidget(colors) != null) ...[
          _toastWidget(colors)!,
          const SizedBox(height: Sp.x3),
        ],

        // ── ★ 平铺的结果行（用户要的"可以平铺了"）──
        if (rows.isEmpty)
          Padding(
            // ★ 内容带（t509）：带已由 `SettingsSubPage.build` 提供 ⇒ 这里归零。
            padding: const EdgeInsets.symmetric(vertical: Sp.x2),
            child: Text(
              '没有匹配「${_query.trim()}」的作品。',
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final m in rows)
            Padding(
              // ★ 内容带（t509）：带已由 `SettingsSubPage.build` 提供 ⇒ 这里归零。
              padding: const EdgeInsets.symmetric(vertical: Sp.x2),
              child: _SkipMarkerRow(
                marker: m,
                colors: colors,
                onClear: _busy ? () {} : () => _clearSkipMarker(m),
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 有数据 ⇒ 平铺 + 固定搜索框；没数据 ⇒ 走**原来的** children
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么空态不显示搜索框
     *
     * ```text
     * 没有任何作品时，搜索框搜什么都是空的 ——
     * 摆一个搜不到东西的输入框是纯噪音（与 episode_strip 的
     * "集数 ≤ 30 不摆搜索框"同一个判据）。
     * ```
     *
     * # 为什么空态走**原路径**（children）而不是 scrollBody
     *
     * 空态下本来就没有"结果要滚动"这回事，
     * 用原来的整页 ListView 结构**与改前逐字相同** ⇒ 零回归风险。
     * 而 `test/skip_history_dialog_test.dart` 的空态断言
     * （`_skipMarkers.isEmpty` + 引导文案）继续在 `_block` 里成立。
     */
    final hasData = _skipMarkers.isNotEmpty;

    return SettingsSubPage(
      title: '片头片尾',
      subtitle: '查看 / 管理已配置的作品',
      pinnedHeader: hasData ? _searchBar(colors) : null,
      scrollBody: hasData ? _resultList(colors) : null,
      onBack: _onBackIntercept,
      children: [
        if (!hasData) ...[
          if (_toastWidget(colors) != null) ...[
            _toastWidget(colors)!,
            const SizedBox(height: Sp.x3),
          ],
          _block(colors),
        ],
      ],
    );
  }
}

/// 片头片尾历史里的一行
///
/// 原 `settings_page.dart` 的 `_SkipMarkerRow`。
class _SkipMarkerRow extends StatelessWidget {
  const _SkipMarkerRow({
    required this.marker,
    required this.colors,
    required this.onClear,
  });

  final SkipMarker marker;
  final ColorScheme colors;
  final VoidCallback onClear;

  /// 秒 → `mm:ss`（超过 1 小时才显示 `h:mm:ss`）
  ///
  /// 片头片尾通常就几分钟，但**片尾可能落在 2 小时的电影末尾**，
  /// 所以不能固定 `mm:ss`（会显示成 `125:30`，很难读）。
  static String _fmt(int? s) {
    if (s == null) return '未设置';
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// 区间摘要：`00:00-02:03`；两端都为空 → `未设置`
  static String _range(int? a, int? b) {
    if (a == null && b == null) return '未设置';
    return '${_fmt(a)}-${_fmt(b)}';
  }

  @override
  Widget build(BuildContext context) {
    /*
     * 作品名可能很长（比如「剧场版 鬼灭之刃 无限列车篇」）——
     * 用 Expanded + ellipsis，不让它把「清除」按钮挤出屏幕。
     * 标题为空时退回 `provider:nativeId`（至少用户知道是哪个源）。
     */
    final title = marker.title.isNotEmpty
        ? marker.title
        : '${marker.provider}:${marker.nativeId}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontWeight: FontWeights.regular,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '片头 ${_range(marker.introStart, marker.introEnd)}'
                '  ·  片尾 ${_range(marker.outroStart, marker.outroEnd)}',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x2),
        TextButton(onPressed: onClear, child: const Text('清除')),
      ],
    );
  }
}
