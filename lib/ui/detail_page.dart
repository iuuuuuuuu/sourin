// ═══════════════════════════════════════════════════════════════════════
//  详情页 —— 对齐原版 DetailView.vue（794 行）
// ═══════════════════════════════════════════════════════════════════════
//
// # 三级嵌套选择
//
// ```text
// 一级：播放源   （cycani 的 play_from / 央视的 CDN）
// 二级：剧集     （sections）
// 三级：清晰度   （播放页的候选流切换）
// ```
// 每层只有 1 个选项时自动隐藏，避免无意义选择。
//
// # ★★★ 这个文件里有两个"修过好几次"的真 bug，绝不能改回去
//
// ## ① 收藏与追更是**完全独立**的两个状态
//
// Owner 两次纠正：
// > 追更并不代表就要收藏，这是独立的状态
// > 我发现我现在点击收藏就会触发追更，这是两个完全不同的功能啊
//
// 四个组合都必须能用：
// ```text
// 只收藏         ✅ 点收藏
// 只追更         ✅ 点追更（不碰收藏）
// 既收藏又追更   ✅ 两个都点
// 都不要         ✅ 各自取消
// ```
//
// ## ② 取消收藏时**不能**顺手关掉追更
//
// Owner：
// > 在追更和收藏都打开的情况下，无法取消收藏
// > 必须要取消追更，才能取消收藏，这两个是不需要联动的
//
// 详见 [_toggleFav] 里的长注释 —— 那里有完整的根因分析。

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/app_log.dart';
import '../core/download_dir.dart';
import '../core/download_queue.dart';
import '../core/sourin_api.dart';
import '../core/ui_prefs.dart';
import 'widgets/overlay_motion.dart';
// ★ task-58：`PlayRequestData` / `MediaSession` 现在住这里（中立契约文件）。
//   ⚠️ 这条 `import` 是**本文件自己用**那些名字所必需的；
//      下面的 `export` 只对 import 本文件的人生效（Dart 语义）。
// ★ task-12 ⑤：只取一个常量（kLocalProvider）—— 本地命名空间必须**只有一处定义**，
//   在本文件里再写一份字面量就是第二个契约（本仓反复踩过这个形态）。
import 'cache_page.dart'
    show CachedDelete, CachedWork, humanBytes, kLocalProvider;
import 'media_session.dart';
import '../core/network_status.dart';
import 'tokens.dart';
import 'widgets/app_loading.dart';
import 'widgets/cover_image.dart';
import 'widgets/detail_raw_meta.dart';
import 'widgets/provider_name.dart';
import 'widgets/source_switch_dialog.dart';

/// 播放请求（交给播放器页）
///
/// ⚠️ 必须把**当前源 + 该源下的剧集列表 + 剧集下标**一起交给播放器：
///    右侧栏的「选集」与「下一集」都依赖它们。若只传单集 id，
///    播放器就无法知道下一集是谁，自动连播无从实现。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ task-58：定义已搬到 `media_session.dart`，这里只做**转发**
/// ══════════════════════════════════════════════════════════════════════
///
/// # 为什么搬走
///
/// 合并页（`media_page.dart`）与播放器（`player_page.dart`）都需要这个类型，
/// 而两者之间**不能互相 import**（`media_page` → `player_page` 已有依赖
/// ⇒ 反向 import 会成环）。所以它住进中立的 `media_session.dart`。
///
/// # 为什么这里保留 `export`（而不是让调用方改 import）
///
/// 引用面只有 3 个文件（本文件 / `shell.dart` / `delivery_test.dart`）。
/// 保留转发 ⇒ **它们一行都不用改**，迁移风险最小。
/// ★ 等 task-58 的功能验证通过、`DetailPage` 正式退役后，
///   再把这个 `export` 与那 3 处 import 一起清理（那是纯机械改动）。
///
/// ⚠️ **不要**在这里重新定义 `PlayRequestData` —— 两份定义会静默分叉
///    （本仓反复踩的"第二份契约"，见 `detail_page.dart` 文件头那段）。
///
/// ⚠️ `export` **不会**把名字引入**本文件**的作用域（Dart 语义：它只对
///    import 本文件的人生效）⇒ 本文件自己用 `PlayRequestData` 的地方
///    仍然需要文件顶部那条 `import 'media_session.dart';`。
///    我第一版只写了 `export`，`flutter analyze` 立刻报
///    `Undefined class 'PlayRequestData'`（L206 与 L700 两处）
///    —— 记在这里免得后人重踩。
export 'media_session.dart' show PlayRequestData, MediaSession;

/// 从「收藏列表 + 追更列表」里解析出某个条目的 (是否收藏, 是否追更)
///
/// ═══════════════════════════════════════════════════════════════════════
/// ★★★ 为什么必须**两个列表都查**（用户报的真 bug —— 2026-09-26）
/// ═══════════════════════════════════════════════════════════════════════
///
/// 用户原话：
/// > 我已追更的作品，我的追更还显示有这个，但是点进去 **追更状态根本没选中**，
/// > 再点击收藏，然后会变成 **收藏中 追更中 两个状态都生效**，这是 bug
///
/// # 根因：用「收藏列表」去判定「追更状态」
///
/// 修之前 `detail_page.dart:309` 只调了**一个**查询：
/// ```dart
/// final favs = await SourinApi.listFavorites();   // followingOnly 默认 false
/// final hit = favs.where((f) => f.key == key).firstOrNull;
/// _isFav     = hit?.favorited ?? false;
/// _following = hit?.following ?? false;           // ★ hit 为 null ⇒ 恒 false
/// ```
/// 而 `followingOnly: false` 在**后端**是：
/// ```text
/// SourinApi.listFavorites()        (sourin_api.dart:459  followingOnly = false)
///   → FFI 'list_favorites'         (ffi.rs:962)
///     → commands::list_favorites   (commands.rs:298)
///       → store.list_favorites(false)   (store.rs:730)
///         → SQL: SELECT ... FROM favorites WHERE **favorited=1**
/// ```
/// ⇒ ★★★ **只返回"收藏过的行"**。而「只追更、未收藏」
///   （`favorited=0, following=1`）是 Owner 明确要求支持的**合法状态**，
///   它**根本不在结果里** ⇒ `hit == null` ⇒ `_following` 恒为 `false`
///   ⇒ **详情页显示"未追更"**（现象 2）。
///
/// 而点「收藏」后 `favorited` 变 1，这行**才第一次**进入结果集 ——
/// 它的 `following` **一直是 1**（`commands_write.rs:316-331`：
/// 不传 `following` 就原样保留）⇒ 于是"两个都亮"（现象 3）。
///
/// ⇒ ★★ **现象 3 不是第二个 bug** —— 它只是现象 2 的必然结果。
///   修掉取值口径，现象 3 自动消失（用户不会再被误导去点收藏）。
///
/// # ★ 为什么"两个状态都亮"是**对的**，不能加互斥
///
/// Owner 两次纠正过（见 `_toggleFav` 的长注释与 `store.rs:716-726`）：
/// ```text
/// 「追更并不代表就要收藏，这是独立的状态」
/// 「我发现我现在点击收藏就会触发追更，这是两个完全不同的功能啊」
/// ```
/// ⇒ `favorited` 与 `following` 是**两个独立位，可以同时为真**。
///   所以修法**绝不能**是"加互斥" —— 那会破坏产品语义。
///
/// # ★★★ 原版有同样的 bug（这不是"照原版"能解决的）
///
/// ```javascript
/// // 原版 src/views/DetailView.vue L219-224 —— 与我们修之前**逐字相同**
/// const favs = await favApi.list(false);          // 只含 favorited=1
/// const hit = favs.find((f) => f.key === key);
/// isFav.value = !!hit;
/// following.value = !!hit?.following;             // ★ 同一个错
/// ```
/// ★ 但原版**在另一个文件里已经知道这个坑**：
/// ```javascript
/// // 原版 src/components/MyShelf.vue L200-209
/// // 但 `list(false)` 在**后端**是 `list_favorites(false)`，其 SQL 是
/// // `WHERE favorited=1` —— 它**只返回收藏过的行**。
/// // 于是 `following` 那份永远拿不到「**只追更不收藏**」的条目
/// //   → ★ 首页「最近追更」里看不到它
/// ```
/// ⇒ ★★★ **原版在 MyShelf 里修了，漏了 DetailView** ——
///   我们忠实地移植了那个被漏掉的 bug。
///   ⇒ 所以「与原版一致 = 正确」在这里**不成立**：原版自己有缺陷。
///
/// # 修法：取两个列表的并集（与 `follow_page.dart:324-325` 同一口径）
///
/// `follow_page.dart` 早就是"两个列表分别查"，这里只是**对齐既有口径**：
/// ```text
/// listFavorites(followingOnly: false)  → 收藏（WHERE favorited=1）
/// listFavorites(followingOnly: true)   → 追更（WHERE deleted=0 AND following=1）
/// ```
/// 为什么不用 `get_favorite`（`store.rs:776` 有）：
/// ★ **FFI 没暴露它**（`ffi.rs` 只有 `list_favorites`）⇒ 要用就得改 Rust +
///   重编 DLL，而 DLL 重编会影响交付包。多一次本地 SQLite 查询是毫秒级，
///   代价远小于动 Rust。这个取舍是刻意的。
///
/// ⚠️ 返回**两个独立的值**，不是"哪个命中就用哪个" ——
///    两个列表可能**同时**命中（`favorited=1, following=1` 是合法状态），
///    此时必须两个都为 true。
({bool favorited, bool following}) resolveFavFollowState({
  required List<Favorite> favorites,
  required List<Favorite> following,
  required String key,
}) {
  /*
   * ★ 分别查**各自的判据字段**，而不是"先找到行再读两个 bool"
   *
   * 为什么这个区别是本质的：
   * ```text
   * 旧写法：先在一份列表里找行 → 找不到就两个都 false
   *          ⇒ 一份列表缺失 ⇒ **另一个状态也被误判**
   * 新写法：收藏只看收藏列表、追更只看追更列表
   *          ⇒ 一份列表缺失**不会污染**另一个状态
   * ```
   * 后者才是"两个独立状态"的正确表达。
   */
  final favHit = favorites.where((f) => f.key == key).firstOrNull;
  final folHit = following.where((f) => f.key == key).firstOrNull;

  return (
    // 收藏：只信收藏列表（它已 `WHERE favorited=1`，命中即为 true）
    favorited: favHit?.favorited ?? false,
    // 追更：只信追更列表（它已 `WHERE following=1`，命中即为 true）
    following: folHit?.following ?? false,
  );
}

/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-09-26 第二轮：右侧面板的**布局常量**
/// ══════════════════════════════════════════════════════════════════════
///
/// # 为什么抽成顶层常量（而不是留在 `_buildHeader` 里当字面量）
///
/// ```text
/// ① 测试要能**引用同一个数** —— 否则测试里抄一份、源码里写一份，
///    改了一处另一处不动 ⇒ 测试变假绿（本仓铁律⑥：断言锁死字面量）
/// ② 注释要解释"为什么是这个数"，而那段解释很长，
///    塞进 build 方法里会把真正的布局逻辑淹掉
/// ```
///
/// ⚠️ 这些常量是**可用宽度**（`LayoutBuilder.constraints.maxWidth`）
///    的阈值，**不是窗口宽度** —— 详见 [_buildHeader] 的说明。
///
/// 窄档封面宽度（可用宽 300..420）
///
/// ```text
/// 361px 可用宽（= 侧栏 409 − contentPadding 24×2）下并排：
///   封面 96 + 间距 16 + 信息 **249px**
/// ```
/// ★ 96 的取值理由：信息区（标题 2 行 + 徽章行 + 三个按钮）需要 ≥ 240px
///   才不挤；而 `361 − 16 − 240 = 105` ⇒ 96 留了一点余量。
///   海报 96×144（2:3）虽小，但**信息区的价值远高于海报**。
const double kCoverNarrow = 96;

/// 紧凑档阈值（可用宽 < 300 ⇒ 封面在上、信息在下）
///
/// ```text
/// 并排所需的最小宽度 = 封面 96 + 间距 16 + 信息下限 188 = **300**
/// ```
/// ★ 低于 300 时并排会把信息压成一条缝（标题每行只放得下两三个字），
///   那时**上下堆叠**反而更好用 ⇒ 这就是保留紧凑档的理由。
///
/// ⚠️ 旧阈值是 420 —— 而 Owner 的侧栏可用宽只有 **361** ⇒ 走紧凑档
///    ⇒ 封面右边 **273px 永久空着**（那正是 Owner 报的"空白区域太多"）。
const double kHeaderCompactMax = 300;

/// 选集区的**固定高度**（可滚视口高）
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-09-26 第二轮：Owner 要「下面剧集高度固定一下」
/// ══════════════════════════════════════════════════════════════════════
///
/// # 取值理由（不是拍的）
///
/// 单个 `_EpisodeButton` 的高度：
/// ```text
/// 文字 FontSizes.sm(14) 行高 ≈ 20
/// + 上下 padding Sp.x2(8) × 2 = 16
/// + 边框 1 × 2               =  2
/// ─────────────────────────────
/// 一个按钮 ≈ **38px**
/// ```
/// 而 `Wrap` 的 `runSpacing = Sp.x2 = 8` ⇒ **一行 ≈ 46px**。
///
/// ```text
/// 3 行 = 38×3 + 8×2 = **130**   ⇒ 整 3 行可见
/// + 再露 18px                   ⇒ 第 4 行**露出一点**
/// ─────────────────────────────
/// 148
/// ```
///
/// # ★ 为什么故意让第 4 行"露一点"（而不是正好 3 行）
///
/// ```text
/// 正好 130（3 行整）⇒ 底部是干净的边界 ⇒ 用户**看不出还能滚**
///    ⇒ 以为"就这 3 行"，不会去滚 ⇒ 后面 20 集像消失了
/// 148（第 4 行露一半）⇒ 视觉上"还有内容" ⇒ 用户会去滚 ✓
/// ```
/// ★ 这是**可用性**取舍，不是凑数：集数多时（27 集 = 9 行 = 406px）
///   固定 148 能把页面高度**从 406 压到 148**（省 258px）。
///
/// # ⚠️ 为什么不用"按集数动态算高度"
///
/// Owner 要的是「**高度固定**」—— 动态算（如 `min(集数, 3) 行`）会让
/// **每部作品的页面高度都不同**，而用户抱怨的正是"剧集把页面撑得很长"。
/// 固定值让**任何**作品的选集区都一样高 ⇒ 下面的区块位置可预期。
const double kEpsViewportH = 148;

/// 选集自动滚动：算出**该滚到哪个 offset**（纯函数，可独立测）
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 为什么抽成纯函数
/// ══════════════════════════════════════════════════════════════════════
///
/// 这段计算有三个容易写错的点（居中 / 夹取 / "已可见就不动"），
/// 而它们**都只依赖数字**，不依赖 Flutter 的渲染树。
/// ⇒ 抽出来就能用普通单测把边界全钉住（不用起 widget）。
///
/// 剩下的"取 RenderBox 尺寸"那部分留在 [_DetailPageState] 里 ——
/// 那部分确实需要真实布局，widget 测试才测得了。
///
/// # 参数
///
/// ```text
/// itemDy        目标按钮**顶边**相对视口顶边的 y（已可见时 0 <= dy）
/// itemH         目标按钮高
/// viewH         视口高
/// currentOffset 选集区当前滚动位置
/// maxExtent     选集区最大可滚距离
/// ```
///
/// # 返回
///
/// ```text
/// null  ⇒ **不用滚**（已经完整可见，或算出来跟当前位置一样）
/// value ⇒ 该滚到的 offset（已夹进 [0, maxExtent]）
/// ```
///
/// ⚠️ "已经完整可见就返回 null"是**刻意的**：
///    否则用户每点一次选集，那一集都会被挪到视口正中间 ——
///    看起来像"我点错了/页面乱跳"。
/// 由「选集之上实测高」算出**选集视口高度**（纯函数 —— 便于边界值验证）
///
/// # 为什么需要它（Owner 第二次投诉）
///
/// > 还是有留白，可以好好优化一下吗？看着不协调
///
/// 真机实测（pid 33212）的量化根因：
/// ```text
/// 内容到 y=618 就结束了，面板高到 y=799
/// ⇒ ★ 底部死区 **181px**
/// ```
/// 因为选集视口是**定值** `kEpsViewportH = 148`，不随面板高度变化。
///
/// # 规则
///
/// ```text
/// epsH = max(kEpsViewportH, 可用高 − 选集之上高 − 尾距)
/// 尾距 = Sp.x6（选集与下一区块的间距）+ Sp.x16（ListView 底部内边距）
/// ```
///
/// ★ 它**仍然不随集数增长** —— Owner 那句「下面剧集高度固定一下」的本意
///   是"别让 24 集撑成 8 行把页面顶下去"，而不是"固定成 148"。
///
/// ⚠️ 必须减掉**尾距**：漏了会让总高超出可用高 ⇒ `ListView` 底部多出
///    一截可滚空白（"修了死区又造出滚动条"）。
///
/// ⚠️ `availH` 为 null/非有限（= 外层没给确定高度，如放进可滚列表里）
///    ⇒ 退回 `kEpsViewportH`（= 改动前的行为）—— 那时"剩余空间"无意义。
double episodeViewportHeight({
  required double topH,
  required double? availH,
}) {
  if (availH == null || !availH.isFinite) return kEpsViewportH;
  final rest = availH - topH - Sp.x6 - Sp.x16;
  return rest > kEpsViewportH ? rest : kEpsViewportH;
}

double? episodeScrollTarget({
  required double itemDy,
  required double itemH,
  required double viewH,
  required double currentOffset,
  required double maxExtent,
}) {
  if (viewH <= 0) return null;

  // ① 已完整可见 ⇒ 不动
  if (itemDy >= 0 && itemDy + itemH <= viewH) return null;

  // ② 让它居中
  var want = currentOffset + itemDy - (viewH - itemH) / 2;

  // ③ 夹取（越界会让 animateTo 抛/回弹）
  want = want.clamp(0.0, maxExtent);

  // ④ 几乎没差 ⇒ 不动（避免无意义的一帧动画）
  if ((want - currentOffset).abs() < 1.0) return null;

  return want;
}

/// 详情页
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ task-58：本页现在有**两种用法**（见 [embedded]）
/// ══════════════════════════════════════════════════════════════════════
///
/// ```text
/// embedded = false  独立页面（旧行为）：自带 Scaffold + SafeArea + 返回按钮
/// embedded = true   ★ 合并页的**下半屏**：由 MediaPage 提供外层布局，
///                    本页不画返回按钮（顶层负责返回）
/// ```
///
/// ⚠️ 为什么用参数而不是"搬成独立 widget"
/// ```text
/// 本页 1610 行、10 个私有 widget 类 + 10 个私有方法。整体搬到
/// `widgets/media_detail_section.dart` 会把**所有既有测试**（它们读
/// `lib/ui/detail_page.dart` 的源码字符串）一起作废，而收益只是"文件更干净"。
/// ⇒ 用 `embedded` 开关达到同样目的，且**不破坏任何既有验证**。
///   （搬迁可以在功能验证通过后单独做 —— 那是纯机械改动。）
/// ```
/// ★ task-12 ⑤：标题**归一化** —— 只为「逐字相等」这一个判据服务
///
/// ```text
/// ① 大小写折叠（toLowerCase）—— 中文不受影响，英文剧名/番号不受大小写差异干扰
/// ② 全部 Unicode 空白剥离（含全角空格 U+3000、NBSP U+00A0、制表/换行）
/// ```
///
/// ⚠️ **不做**任何「相似」处理（不改写繁简、不删标点、不截断）——
///    那是把「对得上」变成「看起来像」，而本判据的全部价值恰恰在前者。
String _normalizeTitle(String raw) =>
    raw.replaceAll(RegExp(r'[\s\u00A0\u3000]+'), '').toLowerCase();

/// 解 HTML 实体（★ 简介兜底用 —— 防"老插件文件没重转"）
///
/// # 为什么详情页还要再解一次
///
/// 实体的**正路**在数据源头就解掉了（Rust 的 `tvbox::strip_tags` /
/// 转换器模板的 `stripTags` —— 本次一并修了）。但用户的插件目录里
/// 还躺着**已经转换好的老 .js 文件**（28 个），它们不会因为宿主升级
/// 而自动重转 ⇒ 那些源的简介仍然带 `&nbsp;`。
/// ⇒ 显示前再解一次，把老文件也覆盖掉（新文件解过一遍，这里是幂等的：
///    已经解开的文本里没有 `&` 开头的实体了）。
///
/// # ⚠️ 写法**刻意**与 assrt / bili 那两份保持一致
///
/// `lib/core/assrt/assrt_api.dart:276 htmlUnescape` 与
/// `lib/core/bili/bili_api.dart:943 unescapeXml` 已经有同样的解码。
/// 这里**不 import 它们**，因为：
///   · 那两个是**源专属**文件（assrt 的 API / B 站的 API），
///     详情页 import 它们是错的依赖方向（详情页不认识任何具体源）；
///   · 它们俩自己也互相重复（谁都不是"公共 util"）。
/// ⇒ 本函数与 bili 那份**逐条等价**（实体表相同、顺序相同），
///   将来若要抽公共 util，这三处一起搬。
///
/// # ★★ 顺序：`&amp;` 必须**最后**（实测定的，不是推理定的）
///
/// 实测（`.probe/t9_order_test.mjs`，真跑）：
/// ```text
/// 输入 "&amp;nbsp;"
///   · &amp; 最先解 ⇒ 得 "&nbsp;" ⇒ 再被 nbsp 规则换成空格 ⇒ " "        ← 错
///   · &amp; 最后解 ⇒ 得 "&nbsp;" ⇒ 没有后续规则 ⇒ 字面量 "&nbsp;"      ← 对
/// ```
/// 语义上 `&amp;nbsp;` 表示"用户想显示 `&nbsp;` 这 6 个字符"，
/// 所以解码后必须**停**在字面量上。把 `&amp;` 放最后，
/// 其它规则跑完时它还是 `&amp;`，**不可能**触发第二轮替换 ——
/// 这正是"只解一遍"的语义。
///
/// ⚠️ 只解**标准 HTML 实体**，不许顺手改别的字符
///    （例如把 U+00A0 当 nbsp 处理 —— 那是另一件事，本函数不做）。
String _decodeHtmlEntities(String s) {
  // 没有 & 就一定是纯文本（省一次正则扫描）
  if (!s.contains('&')) return s;
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'");
  // &#xHHHH;（十六进制）
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final v = int.tryParse(m.group(1)!, radix: 16);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  // &#DDDD;（十进制）
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final v = int.tryParse(m.group(1)!);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  // ★ `&amp;` 最后（见上）
  return out.replaceAll('&amp;', '&');
}

/// ★ 仅供测试调用 —— 上面那个私有函数的转发入口
///
/// 为什么不直接把 _decodeHtmlEntities 改成公开：
/// 它没有对外语义（只有详情页简介这一个调用点），公开会让"谁能调"变模糊。
/// 这里只开一个测试专用门（与文件里其它 @visibleForTesting 一致）。
@visibleForTesting
String decodeHtmlEntitiesForTest(String s) => _decodeHtmlEntities(s);

/// 本地页"认回来源"要读的那两张表（生产路径来自 FFI）
typedef LocalOriginRecords = ({
  List<Progress> progress,
  List<Favorite> favorites,
});

/// ★ CR-12（**仅供测试**）：替换"读应用自己的记录"那两步
///
/// # 为什么需要这个口子（真实原因，不是"为了测试而测试"）
/// ```text
/// [_resolveLocalOrigin] 靠 [SourinApi.listAllProgress] / [SourinApi.listFavorites]
/// 去认"本地这一集是从哪个站的哪一条下载下来的"。
/// 而 `flutter test` 里 FFI **必然失败**
///   （`Failed to load dynamic library 'sourin_core.dll'`，error 126）
/// ⇒ 那两张表恒为空 ⇒ 恒"未命中" ⇒ **CR-12 这条缺陷根本造不出来**：
///   造不出"带 cover 的命中记录"，就量不到"认回来源把刚铺好的封面与简介抹掉"。
/// ```
///
/// # 为什么把口子开在这个文件，而不是 [SourinApi]
/// ```text
/// `sourin_api.dart` 里已有同形态的先例
///（`debugSyncStatusFetcher` / `debugHomeFetcher` / `debugListFetcher`），
/// 但改那个文件会牵动全仓所有调用点 —— 而这里只有**一个页面的一个调用点**要测。
/// ⇒ 就在被测代码旁边开一条，生产路径一字未动（为 null 时就是原来那两句 FFI）。
/// ```
@visibleForTesting
LocalOriginRecords Function()? debugLocalOriginRecords;

/// 装上/卸掉这两张表的来源（传 `null` = 回到生产路径）
@visibleForTesting
void debugSetLocalOriginRecords(LocalOriginRecords Function()? f) {
  debugLocalOriginRecords = f;
}

/// ★ task-12 ⑤：本地文件模式的「来源」文案
///
/// # 为什么不是空、也不是某个站点名
/// Owner：「本地播放详情页 **来源** 也还是要用下载的」。
/// 但本地播放的**前提**就是"没有旁文件"（`shell.dart:4773`：有旁文件走在线），
/// 所以"下载时记录的来源"在多数情况下**根本不存在**。
/// ⇒ 存在时用站点名（见 `_DetailPageState._resolveLocalOrigin`），
///   不存在时**如实写「本地」** —— 不空着、也不冒充任何站点。
const String kLocalSourceLabel = '本地';

/// 本地文件模式下，「已下载」那一段的最大高度（超出**内部**滚）
///
/// ```text
/// 4 行 × 行高 36 = 144
/// + 一点余量让第 5 行"露一点"（同 kEpsViewportH 的可用性理由：
///   底边正好卡在整行上时，用户看不出下面还有内容）
/// ```
const double kLocalEpsViewportH = 160;

/// ★ task-12 ⑤：本地文件模式里「已下载的一集」（一集一行）
///
/// 与 [Episode] **刻意分开**：`Episode` 是**在线源**的剧集（有流地址、有源 code），
/// 而本地这一集只有一个**文件**。混用同一个类型会让"点了要播哪个 URL"变得含糊。
@immutable
class LocalEpisodeRef {
  const LocalEpisodeRef({
    required this.fileName,
    required this.episodeTitle,
    required this.absolutePath,
    this.bytes = 0,
    this.watchRatio = 0,
  });

  /// 磁盘上的文件名（含扩展名）—— 也是这一行的稳定 key
  final String fileName;

  /// 展示名（默认 = 去掉扩展名的文件名）
  final String episodeTitle;

  /// 文件**绝对路径**（交给播放器的就是它）
  final String absolutePath;

  /// 这个文件占的字节数（来自扫盘读数）
  ///
  /// ★ task-17 ③：批量删除的确认正文要写「共 X MB」，而**不能在弹窗前**去 stat ——
  ///    实测（探针）那样会让"点删除"到"弹窗出现"之间卡一段真实 IO，
  ///    在 flutter_test 的假时钟下那次 IO 甚至永不完成（弹窗永远不出现）。
  ///    而扫盘**本来就量过**这个数（CachedEpisode.bytes）⇒ 直接带过来。
  final int bytes;

  /// 这一集的**观看进度**（0..1；0 = 没看过 / 看过但不到 1%）
  ///
  /// ★ 为什么需要（Owner：「已缓存的 一集一行」，并要从一眼看出看过没看过）
  /// ```text
  /// 进度存在 `local` 命名空间（provider='local', contentId=文件绝对路径），
  /// 而那是**本地页自己的主键**——所以这里能直接问库，不用去推测。
  /// ★ 不读为它发请：进度表是**本地 SQLite**，不需要网络，且小快。
  /// ```
  final double watchRatio;

  /// 看过一矩以上（Owner：「已看标记」）
  bool get watched => watchRatio > 0.01;

  @override
  bool operator ==(Object other) =>
      other is LocalEpisodeRef && other.absolutePath == absolutePath;

  @override
  int get hashCode => absolutePath.hashCode;
}

/// ★ task-17 ②：一条"本地文件是从哪个站来的"候选记录
///
/// 字段全部来自应用自己的 progress / favorites 表（**不联网**）——
/// 见 `_DetailPageState._resolveLocalOrigin` 的排序规则说明。
@immutable
class LocalOriginHit {
  const LocalOriginHit({
    required this.provider,
    required this.id,
    required this.title,
    required this.at,
    this.cover,
  });

  final String provider;
  final String id;
  final String title;

  /// 该记录的"有多近"（progress.updatedAt / favorite.updatedAt，毫秒）
  ///
  /// ⚠️ 两条来源的语义**不同**（一个是"看到哪"、一个是"收藏何时更新"），
  ///    但排序只需要"谁更近"这个**序**，不需要它们的绝对含义一致。
  final int at;

  /// 站点给的封面 URL（可能为 null —— 老记录 / 该源没填）
  final String? cover;
}

/// ★ task-17 ②：把候选按**确定性**规则排好（第一条 = 采用的那条）
///
/// 四级比较（每一级都要能解释，见调用点的长注释）：
/// ```text
/// ① 有 cover 的优先
/// ② 有 id 的优先
/// ③ at 更大（更近）的优先
/// ④ provider 名字典序 —— 只为确定性
/// ```
///
/// ★ 抽成**顶层纯函数**（不是 State 的私有方法）是为了能被单测直接钉住 ——
///   排序规则是这一轮的核心判据，埋在 UI 类里就只能靠真机截图验。
List<LocalOriginHit> rankLocalOriginHits(List<LocalOriginHit> hits) {
  final out = List<LocalOriginHit>.of(hits);
  out.sort((a, b) {
    // ① 有封面优先
    final ca = (a.cover?.isNotEmpty ?? false) ? 0 : 1;
    final cb = (b.cover?.isNotEmpty ?? false) ? 0 : 1;
    if (ca != cb) return ca.compareTo(cb);
    // ② 有 id 优先
    final ia = a.id.isNotEmpty ? 0 : 1;
    final ib = b.id.isNotEmpty ? 0 : 1;
    if (ia != ib) return ia.compareTo(ib);
    // ③ 更近的优先（降序）
    if (a.at != b.at) return b.at.compareTo(a.at);
    // ④ 字典序（升序）—— 兜底，保证同一份数据两次运行结果相同
    final pc = a.provider.compareTo(b.provider);
    if (pc != 0) return pc;
    return a.id.compareTo(b.id);
  });
  return out;
}

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.provider,
    required this.id,
    this.onPlay,
    this.onOpenDetail,
    this.onLoaded,
    this.isTv = false,
    this.embedded = false,
    this.currentEpisodeId,
    /*
     * ★★★ task-12 ⑤：本地文件模式的参数（全部有默认值 ⇒ 在线路径一个字都不用改）
     */
    this.localFile,
    this.localEpisodeCount = 0,
    this.onPlayLocalEpisode,
    this.localTitle,
    this.localCover,
    this.localEpisodes = const <LocalEpisodeRef>[],
    this.onLocalEpisodesChanged,
    this.localMeta,
  });

  final String provider;
  final String id;

  /// 点「播放」/ 选集 → 进播放器
  final void Function(PlayRequestData req)? onPlay;

  /// 换源后跳到新源的详情页（整页重新加载）
  final void Function(String provider, String id)? onOpenDetail;

  /// ★ task-58：详情加载完成 ⇒ 通知外层
  ///
  /// # 为什么需要它（合并页的标题来源）
  ///
  /// 旧流程里播放器拿得到标题：用户在详情页点「播放」⇒
  /// `PlayRequestData.title = d.title` ⇒ 播放器顶栏显示它。
  ///
  /// 合并页里**播放器先于详情加载**（它一进页就起播）⇒ 那一刻没有标题。
  /// 若不给外层一个通知通道，顶栏会**一直空着** —— 这是可见的功能退化。
  /// ⇒ 详情拉到 `MediaDetail` 后回调一次，由 `MediaPage` 转给播放器。
  ///
  /// ⚠️ 只在**成功**时回调；失败/加载中不回调（外层保持原值）。
  final void Function(MediaDetail detail)? onLoaded;

  final bool isTv;

  /// ★ task-58：是否作为**合并页的下半屏**渲染
  ///
  /// ```text
  /// true  ⇒ 不画 Scaffold/SafeArea（外层已有），不画返回按钮，
  ///          且**不响应返回键**（返回由合并页统一处理 ⇒ 回首页）
  /// false ⇒ 旧行为完全不变（独立页面）
  /// ```
  final bool embedded;

  /// ★★★ 2026-09-26 第二轮：**播放器正在播的**那一集 id（`null` = 还没报告）
  ///
  /// # 为什么详情页需要外层告诉它（Owner 原话）
  ///
  /// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
  /// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
  ///
  /// 本页原来的"当前集"（`_activeEpisodeId`）只由**两个**来源决定：
  /// ```text
  /// ① `_pickedEpisodeId`  —— 用户在本页点了哪一集
  /// ② `_selectedEpisodeId` —— 上次观看记录（`_resume.episodeId`）
  /// ```
  /// ⇒ ★ 它**感知不到**播放器自己切了集（按「下一集」/ 自动连播）⇒
  ///   高亮不动、也不滚动 —— 这正是 Owner 报的那个缺口。
  ///
  /// # 三者的优先级（**必须**是这个顺序，否则会"跳回去"）
  ///
  /// ```text
  /// ① `currentEpisodeId`（播放器，最权威 —— 它**真的在播**那一集）
  /// ② `_pickedEpisodeId`（用户刚点的，用于"点了但还没起播"的瞬间）
  /// ③ `_selectedEpisodeId`（上次观看记录，兜底）
  /// ```
  /// ⚠️ 若把 ① 排在后面，用户按「下一集」后本页会**先滚回旧集再滚过去**
  ///    （因为 `_selectedEpisodeId` 还是旧的）⇒ 视觉上"抖一下"。
  ///
  /// ⚠️ `null` 的语义是"播放器**还没报告**"，**不是**"没有当前集" ⇒
  ///    此时必须**回退**到 ② / ③，不能当成"没有"。
  final String? currentEpisodeId;

  /// ★★★ task-12 ⑤（2026-10-09）：**本地文件模式** —— 非 null ⇒ 本页不向核心要详情
  ///
  /// # 为什么必须「不去要」（而不是"要了失败再兜底"）
  ///
  /// 本地播放时 [provider] 恒为 local、[id] 恒为规范化后的**绝对路径**
  /// （见 cache_page.dart 的 buildLocalPlayRequest 与 canonicalLocalPath）。
  /// 而核心的注册表里**没有**叫 local 的 provider：
  /// ```text
  /// SourinApi.getDetail(local, <路径>)
  ///   → Rust playback.rs registry.route(MediaId::new("local", <路径>))
  ///   → 抛 SourinCoreException: 无法路由: local:c:/…
  /// ```
  /// ⇒ 那是**必然**失败的一次 IPC，而不是"可能失败"。
  ///
  /// ★ 判据是**这一个字段**，不是 provider == local：
  ///   local 只是 cache_page.kLocalProvider 的当前取值（一个字符串），
  ///   拿它当判据的话，将来改个名就会静默失效；而本字段是**类型化**的。
  final String? localFile;

  /// 是否本地文件模式（语义化判据，供调用方与测试读）
  bool get isLocalFile => localFile != null;

  /// 本地模式下**已下载的集数**（0 = 外层还没扫到 / 一集都没下）
  ///
  /// ⚠️ 只用于徽章那一行的「已下载 N 集」。它与在线页那个「N 集」**不是一回事**：
  /// ```text
  /// 在线「N 集」      这个源一共更新到第几集
  /// 本地「已下载 N 集」 你在这台机器上真正下好了几集
  /// ```
  /// Owner：「其他都要跟在线播放页一致，**除了集数的展示**」—— 所以本地模式
  /// **不**渲染前者，只渲染后者。
  final int localEpisodeCount;

  /// 本地模式下点「某一集」⇒ 交给外层切到那个**文件**
  ///
  /// ⚠️ 传的是 [LocalEpisodeRef]（里面是**绝对路径**），不是 Episode.id：
  /// 本地会话的主键是 canonicalLocalPath(绝对路径)，而真正要交给播放器的
  /// 是**原始绝对路径**（见 player_page.dart 的 _bootLocalFile）。
  final void Function(LocalEpisodeRef ref)? onPlayLocalEpisode;

  /// 本地模式下的**标题**（扫盘给的目录名 / 旁文件里的真标题）
  ///
  /// ⚠️ 本页本来**没有** title / cover 字段：在线路径的标题与封面来自拉回来的详情。
  ///    而本地路径**拿不到**站点详情 ⇒ 只能用外层喂进来的这两个值。
  ///    null ⇒ 退回 widget.id（那里是文件绝对路径，总比空白强）。
  final String? localTitle;

  /// 本地模式下的**封面**（只有旁文件里记过才有；扫盘那条路为 null）
  ///
  /// ⚠️ 它**不是**下载时记录的封面一定存在：本地播放的前提就是没有旁文件
  ///    （shell.dart:4773）。真拿到了才会显示，否则走标题首字占位。
  final String? localCover;

  /// ★ task-12 ⑤：本地模式下**已下载的集**（一集一个文件）
  ///
  /// 数据源在外层（cache_page 扫盘出来的 CachedWork.episodes）——
  /// 本页**不自己扫盘**：那是外层的职责，两边各扫一次必然出现两处结果不一致。
  final List<LocalEpisodeRef> localEpisodes;

  /// ★ task-17 ③：删除完成后通知外层**重新扫盘**（真刷新）
  ///
  /// ⚠️ 本页**不自己扫盘**（见 localEpisodes 的注释）—— 扫盘是外层的职责。
  ///    删完不刷新的话，列表会一直挂着已经不存在的行（假刷新比不刷新更糟）。
  final VoidCallback? onLocalEpisodesChanged;

  /// ★★★ Owner 1009 ⑬：本地模式下**随下载缓存下来的作品信息**
  ///
  /// （简介 / 年份 / 地区 / 类型 / 角标 / 本地封面文件）
  ///
  /// # 为什么需要它（这一轮之前本地页为什么是"半成品"）
  /// ```text
  /// 本地页原本只填 title + cover ⇒ 页面上只有一行标题 + 一个徽章，
  /// 跟在线播放页一比就是"少了大半截"，Owner 说的「半成品」正是这个。
  /// 而这些字段**只有详情接口能给**，离线时核心也路由不到（provider='local'）
  /// ⇒ 唯一出路就是下载那一刻把它们缓存下来（见 DownloadQueue._writeSidecarFor）。
  /// ```
  ///
  /// ⚠️ null / 字段为空 ⇒ **降级显示**（少几行），绝不编造，也绝不报错。
  final CachedWork? localMeta;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  MediaDetail? _detail;
  bool _loading = true;
  String? _error;

  /// ★★★ task-64：测试口子 —— 直接注入详情与剧集，**跳过 FFI**
  ///
  /// # 为什么必须加（否则 task-64 的核心契约**无法**被测）
  /// ```text
  /// 生产路径：`initState` ⇒ `SourinApi.getDetail(...)` ⇒ **FFI**
  /// ★ 而 `flutter test` 里 FFI **必然失败**
  ///   （`Failed to load dynamic library 'sourin_core.dll'`，error 126）
  /// ⇒ `_detail` 恒为 null ⇒ `_buildBody` **从不执行**
  /// ⇒ 「头部固定 + 选集内部滚」这条契约在测试里**永远看不到**
  ///   （本仓实测：`t59_embed_theme_test.dart` 就是因此只能做静态断言，
  ///     它在注释里明说了"`_detail == null` ⇒ `_buildBody` 不跑"）。
  /// ```
  ///
  /// # 为什么这不是"影子副本"（本仓铁律②）
  /// ```text
  /// 它注入的是**真 `MediaDetail` 数据**，跑的是**真 `_buildBody`**，
  /// 渲染出**真的 widget 树** —— 只是绕过了取数据那一步。
  /// ★ 与"复刻一份布局来测"有本质区别：这里被测的就是生产代码本身。
  /// ```
  ///
  /// ⚠️ 与 `MyShelf.debugSetData` 同一手法（本仓既有先例）。
  @visibleForTesting
  void debugSetDetail(MediaDetail d, {List<Episode>? episodes}) {
    setState(() {
      _detail = d;
      _loading = false;
      _error = null;
      if (episodes != null) _episodes = episodes;
    });
  }

  /// 注入"上次看到"进度（widget 测试用）
  ///
  /// ★ 与 [debugSetDetail] 同一手法：绕过的只是 `getProgress` 那一次 FFI，
  ///   **渲染路径**（`_resumeTitle` / `_resumeRemaining` 拼串 + 那颗
  ///   chip 的真实布局）全是生产代码。
  ///
  /// 存在的理由：续播 chip 的溢出缺陷（桌面端第 4 条）**只能**在
  /// "标题很长 + 面板很窄"这个真实约束下复现，而真约束只有在
  /// widget 测试里把 `_resume` 填进去才拿得到 —— 生产路径里它来自
  /// 用户真实观看记录，测试里造不出来。
  @visibleForTesting
  void debugSetResume(Progress? p) {
    setState(() => _resume = p);
  }

  /// 注入一条**错误信息**（widget 测试用）
  ///
  /// ★ 与 [debugSetDetail] / [debugSetResume] 同一手法：绕过的只是
  ///   「FFI 调用失败」那一步，渲染的是**真的 `_ErrorView`**。
  ///
  /// # 为什么需要它（2026-10-08，macOS CI 逼出来的）
  /// ```text
  /// macOS 上缺 libsourin_core.dylib ⇒ DetailPage 落进 _ErrorView，
  /// 而 dlopen 的失败文本是**平台相关**的：
  ///   Windows ≈100 字符（`… (error code: 126)`）⇒ 塞得下
  ///   macOS   ≈1500 字符（一长串 `tried: '…' (no such file), …`）⇒ 溢出 580px
  /// ⇒ 同一段布局代码只在 macOS 溢出，本地怎么跑都是绿的。
  /// ```
  /// 有了这个注入口，就能**直接构造等长的文本**在两端复现，
  /// 不再依赖「本机恰好缺哪个库、报错文本恰好多长」这种偶然。
  ///
  /// ⚠️ 与上面两个 debug 方法一样：**生产代码无调用点**（`@visibleForTesting`）。
  @visibleForTesting
  void debugSetError(String message) {
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  /// 线路树（带真实 title / count / nested）
  ///
  /// ★ 直接就是 `MediaDetail.sources` —— 不再有"原始 JSON 的第二份读取"。
  ///
  /// # 这里原先是什么样（绕行已撤）
  ///
  /// `models.dart` 的 `PlaySource` 曾经三个键名全错
  /// （读 `name` / `episode_count`，且**没有** `nested` 字段），
  /// 于是详情页额外调一次 `get_detail` 拿原始 JSON，
  /// 再用 `widgets/detail_raw_meta.dart` 里的 `DetailSourceNode` /
  /// `parseDetailSources` 自己解一遍。
  ///
  /// 那是**第二份契约** —— 根因修好后必须撤：
  /// ```text
  /// 留着的话，以后 Rust 改了字段名，两处都要改，
  /// 而漏掉哪一处都不报错（正是这三个缺口本身的形态）。
  /// ```
  /// 现在数据只有**一条来源**：`MediaDetail.sources`（`PlaySource`）。
  List<PlaySource> get _sourceNodes => _detail?.sources ?? const [];

  /// 当前选中的播放源 code
  String _activeSource = '';

  /// 当前源所属**站点**的显示名（task-32）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 用户原话
  /// ══════════════════════════════════════════════════════════════════
  /// > 播放页和详情页都不能看到当前播放源是哪一个
  ///
  /// # 为什么需要它（原版对照的结论）
  ///
  /// `SourcePicker.vue:28-34` 的注释解释了"单源时隐藏该层"的理由：
  /// ```text
  /// * 因为单独一个源没有「选择」的意义，**详情页标题区已展示过站名**。
  /// ```
  /// ★ 但逐行读过 `DetailView.vue:585-593` 的 `hero__badges` ——
  ///   **根本没有站名**（只有后端 badges + 「N 集」+「N 个播放源」）。
  ///
  /// ⇒ **那条注释的立论不成立** ⇒ 单源条目在详情页
  ///   **完全看不到任何源信息** —— 这正是用户抱怨的机制。
  ///
  /// # 所以这不是"发明新 UI"，而是实现原版承诺却没做到的那件事
  ///
  /// 位置就选在注释说"已展示过站名"的地方：`hero__badges`
  /// （见 [_Info] 里那个 chip）。**位置有依据，样式复用 `_Chip`。**
  ///
  /// # 为什么显示的是**站点名**而不是线路名
  ///
  /// ```text
  /// widget.provider   = 站点（cycani / tyyszy / cctv）  ← 用户说的"源"
  /// _activeSource     = 站内的线路 code（cychub / cdn）  ← 另一层
  /// ```
  /// 用户在这个 app 的词汇里（首页 SourceBar / 设置页 / 换源弹层）
  /// 说的"源"指**站点**。线路名由下面「播放源」区块的**高亮**回答
  /// （与原版 `SourcePicker` 的 `is-active` 一致）。
  String? _providerName;

  /// 当前源下的剧集
  List<Episode> _episodes = [];
  bool _epsLoading = false;

  // ══════════════════════════════════════════════════════════════════════
  //  ★★★ 2026-09-26 第二轮：选集的**独立滚动**（B + C）
  // ══════════════════════════════════════════════════════════════════════

  /// ★ 选集区**自己的**滚动控制器
  ///
  /// # 为什么必须"自己的"（而不是用 `Scrollable.ensureVisible`）
  ///
  /// `Scrollable.ensureVisible(ctx)` 会**向上遍历所有 `Scrollable`** ——
  /// 本页外层就是一个 `ListView`（见 [_buildBody]）⇒
  /// 它会**顺带把整页滚走**，用户看到的是"页面自己跳了一下"。
  ///
  /// 本仓有同族真实事故：task-3「设置页往下滑会被自动拉回」
  /// （`spatial_nav.dart` 的 `_scrollIntoView` 用了同一个 API）。
  ///
  /// ⇒ ★ 这里**只**动这个控制器 ⇒ 外层 `ListView` 的 offset 不变。
  ///    判据见 `test/t61_panel_scroll_test.dart`（含红度证明）。
  final ScrollController _epsCtrl = ScrollController();

  /// ★ 选集**视口**的 key —— 用来算"某一集相对于视口在哪"
  ///
  /// 挂在固定高度那个盒子上（它的 RenderBox 尺寸 == 视口尺寸）。
  final GlobalKey _epsViewportKey = GlobalKey();

  /// ★★★ 2026-09-27 第三轮：「选集**之上**」那块的总高（用于算剩余空间）
  ///
  /// # 为什么需要实测而不是估算
  ///
  /// Owner 第二次投诉「还是有留白」的量化根因是**底部 181px 死区**
  /// （真机实测：内容到 y=618 就结束，面板高到 799）——
  /// 因为选集视口是**定值** `kEpsViewportH = 148`，不随面板高度变化。
  ///
  /// ⇒ 要让选集**吃掉剩余高度**，就得知道"剩余"是多少，即"上面用了多少"。
  ///
  /// ⚠️ **不能估算**：上面那块的高度取决于
  /// ```text
  /// · 标题折几行（随宽度/字号变）
  /// · 徽章折几行（随徽章数量变）
  /// · 简介有没有、折几行
  /// · 有没有「续播」条
  /// · 有没有「播放源」区（多源时才画）
  /// ```
  /// 估算必然漂移，而**漂移的判据 = 假的判据**（本仓铁律）。
  /// ⇒ 用 `_topKey` 的 `RenderBox.size.height` **实测**。
  final GlobalKey _topKey = GlobalKey();

  /// 上一帧实测到的"选集之上"高度（首帧为 `null`）
  ///
  /// ⚠️ 只在 `post-frame` 回调里写 ⇒ 首帧读不到 ⇒ 首帧退回
  ///    `kEpsViewportH`（= 改动前的行为），第二帧起撑开。
  ///    **不会闪烁**，只是首帧矮一点（用户看不到，因为首帧还没上屏）。
  double? _topH;

  /// 每一集按钮的 key（按 episode id 索引）
  ///
  /// ⚠️ 必须**稳定复用**：每帧新建 `GlobalKey` 会让 Flutter
  ///    重新挂载整棵子树（闪烁 + 丢状态）。
  final Map<String, GlobalKey> _epKeys = <String, GlobalKey>{};

  GlobalKey _epKeyFor(String id) =>
      _epKeys.putIfAbsent(id, () => GlobalKey());

  /// ★ task-12 ⑤：本地行（「已下载」那段）的 key，按**绝对路径**索引
  ///
  /// ⚠️ 与 [_epKeys] 分开两张表：本地行的身份是**路径**，在线行的身份是 Episode.id。
  /// ⚠️ 同样必须**稳定复用**（每帧新建 GlobalKey 会重挂整棵子树）。
  final Map<String, GlobalKey> _localRowKeys = <String, GlobalKey>{};

  GlobalKey _localRowKeyFor(String path) =>
      _localRowKeys.putIfAbsent(path, () => GlobalKey());

  /// 把当前集滚进可视区（**只滚选集区**）
  ///
  /// # 触发时机（Owner 要求的三条路径，都要）
  ///
  /// ```text
  /// ① 进页（详情/剧集加载完）           ⇒ _init / _loadEpisodes 末尾
  /// ② 用户点选集                        ⇒ _play(ep) 里
  /// ③ 播放器「上一集/下一集/自动连播」   ⇒ didUpdateWidget（currentEpisodeId 变了）
  /// ```
  ///
  /// # 为什么用"自己算 offset"而不是 `ensureVisible`
  ///
  /// 见 [_epsCtrl] 的说明 —— `ensureVisible` 会连外层 `ListView` 一起滚。
  /// 这里改成：
  /// ```text
  /// ① 取目标按钮的 RenderBox，算出它相对**视口**的 y（dy）
  /// ② 目标 offset = 当前 offset + dy − (视口高 − 按钮高)/2   ← 让它**居中**
  /// ③ 夹到 [0, maxScrollExtent]
  /// ④ 只对 _epsCtrl 做 animateTo
  /// ```
  ///
  /// ⚠️ **已经完整可见时不动** —— 否则用户刚点的那一集会被莫名挪到中间，
  ///    看起来像"我点错了"。
  void _scrollEpisodesIntoView() {
    /*
     * ★ task-12 ⑤：本地模式的"当前集"身份是**绝对路径**（播放器报的文件名换来的），
     *    在线模式是 Episode.id —— 两套 key 表各查各的（见 [_localRowKeyFor]）。
     */
    final local = widget.isLocalFile;
    final id = local ? _activeLocalPath : _activeEpisodeId;
    if (id == null) return;
    if (!_epsCtrl.hasClients) return;

    final itemCtx = (local ? _localRowKeys[id] : _epKeys[id])?.currentContext;
    if (itemCtx == null) return;
    final itemBox = itemCtx.findRenderObject();
    if (itemBox is! RenderBox || !itemBox.hasSize) return;

    final vpCtx = _epsViewportKey.currentContext;
    if (vpCtx == null) return;
    final vpBox = vpCtx.findRenderObject();
    if (vpBox is! RenderBox || !vpBox.hasSize) return;

    final dy = itemBox.localToGlobal(Offset.zero, ancestor: vpBox).dy;
    final itemH = itemBox.size.height;
    final viewH = vpBox.size.height;

    /*
     * ★ 计算部分抽成了纯函数 [episodeScrollTarget] ——
     *   那里有"居中 / 夹取 / 已可见就不动"三条规则的完整说明，
     *   而且有独立单测把边界钉住（见 t61 测试）。
     */
    final want = episodeScrollTarget(
      itemDy: dy,
      itemH: itemH,
      viewH: viewH,
      currentOffset: _epsCtrl.offset,
      maxExtent: _epsCtrl.position.maxScrollExtent,
    );
    if (want == null) return; // 已可见 / 无需动

    debugPrint('[DETAIL] 选集自动滚动: $id '
        '（offset ${_epsCtrl.offset.toStringAsFixed(0)} → '
        '${want.toStringAsFixed(0)}，dy=${dy.toStringAsFixed(0)}）');

    // ★ 只滚**选集**控制器 —— 外层 ListView 不受影响（见 [_epsCtrl]）
    _epsCtrl.animateTo(
      want,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// 排到**下一帧**再滚（布局完成后尺寸才是准的）
  void _scheduleEpisodeScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollEpisodesIntoView();
    });
  }

  /// 剧集列表变了 ⇒ 清掉已消失的 key（防无限增长）
  void _pruneEpisodeKeys() {
    _epKeys.removeWhere((k, _) => !_episodes.any((e) => e.id == k));
  }

  /// ★ task-12 ⑤：本地模式解析出来的「来源」显示名
  ///
  /// 三档（见 _loadLocalOrigin）：站点显示名 / 「本地」/ null（还没解析完）。
  /// ⚠️ null 与「本地」**语义不同**：前者是"还没算出来"，后者是"算过了，认不回来"。
  String? _localOrigin;

  /// ★ Owner ⑬：本地页此刻**能不能上网**（决定那几枚操作按钮画不画）
  ///
  /// ★ 初始 true（=「先按有网画」）：探测是异步的，首帧不能等它；
  ///   联网用户因此零感知，断网用户顶多看到按钮"闪一下再消失"。
  ///   反过来（初始 false）会让联网用户白等一下才能用按钮 —— 更糟。
  bool _online = true;

  /// ★ task-12 ⑤：本地模式认回来的那条**站点记录**（provider + nativeId）
  ///
  /// 用途：① 溯源（日志/排查）② 补真详情时用它去拉（见 _loadLocalOrigin 的第 ② 步）。
  /// ⚠️ **不覆盖** widget.provider / widget.id —— 那一对是续播与自包含层的主键，
  ///    必须留在 local 命名空间里。
  ({String provider, String id})? _localOriginItem;
  bool _isFav = false;
  bool _following = false;
  Progress? _resume;
  String? _toast;

  /// 用户**手动点过**的选集（优先级高于自动推导）
  ///
  /// 场景：用户点开第 5 集，但还没产生观看进度（播放器刚打开、
  /// 或 position 太小没落库），此时若完全依赖 `_resume`，
  /// 高亮会跳回第一集 —— 看起来像"我点的那一集没选上"。
  String? _pickedEpisodeId;

  /// ★★★ 当前**选中**的剧集 id（选集区高亮用）
  ///
  /// # Owner 的要求（2026-09-21）
  ///
  /// > 这个页面如果有观看记录，下面的应该默认选中上次观看的集数
  /// > 然后如果是只有一个，默认也应该选择第一个，
  /// > 不应该显示没选中的效果
  ///
  /// # 原先错在哪
  ///
  /// 选集按钮只有一个 `is-played` 判据（`resume?.episode_id === ep.id`），
  /// 它表达的是"**看过**这一集"：
  /// ```text
  /// 没有记录  → ★ 一集都不高亮，整片灰着，看起来像"没选中任何一集"
  /// 只有一集  → ★ 同样不高亮（resume 为 null），最明显的不合理
  /// ```
  ///
  /// # 取值优先级
  ///
  /// ```text
  /// ① 上次观看的那一集（有观看记录时）
  /// ② 否则第一集
  /// ③ 没有剧集（电影等）→ null，此时选集区根本不渲染
  /// ```
  String? get _selectedEpisodeId {
    if (_episodes.isEmpty) return null;
    final last = _resume?.episodeId;
    if (last != null && _episodes.any((e) => e.id == last)) return last;
    return _episodes.first.id;
  }

  /// 真正用于高亮的 id —— 优先级见下面 `_activeEpisodeId` 的说明
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26 第二轮：优先级**必须**是这个顺序
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// ① widget.currentEpisodeId  播放器**真的在播**那一集（最权威）
  /// ② _pickedEpisodeId         用户刚点的（"点了但还没起播"的瞬间）
  /// ③ _selectedEpisodeId       上次观看记录 / 第一集（兜底）
  /// ```
  ///
  /// ⚠️ **为什么 ① 必须排在 ② 前面**（顺序错了会"抖一下"）：
  /// ```text
  /// 用户按「下一集」⇒ 播放器切到第 5 集 ⇒ 外层把 currentEpisodeId 传下来
  ///   若顺序是 ②→①：
  ///     · 本页先用**旧的** `_pickedEpisodeId`（第 4 集）高亮/滚动
  ///     · 再被 ① 纠正成第 5 集
  ///     ⇒ 用户看到"先滚回第 4 集再滚到第 5 集"
  ///   现在顺序 ①→②：直接就是第 5 集，**一次到位** ✓
  /// ```
  ///
  /// ⚠️ `widget.currentEpisodeId == null` 的语义是
  ///    「播放器**还没报告**」—— **不是**"没有当前集" ⇒ 必须回退到 ②/③。
  ///
  /// ⚠️ 还要**校验它真的在这一集的列表里**：换源/换线路后剧集列表会变，
  ///    旧 id 可能已不存在 ⇒ 直接拿来高亮会"一集都不亮"。
  String? get _activeEpisodeId {
    final fromPlayer = widget.currentEpisodeId;
    if (fromPlayer != null && _episodes.any((e) => e.id == fromPlayer)) {
      return fromPlayer;
    }
    return _pickedEpisodeId ?? _selectedEpisodeId;
  }

  /// 当前看到第几集（1 起）—— 从已有进度里推
  int get _currentEpisodeIndex {
    final r = _resume;
    if (r == null) return 0;
    final i = _episodes.indexWhere((e) => e.id == r.episodeId);
    return i >= 0 ? i + 1 : 0;
  }

  bool get _hasMultiSource => _sourceNodes.length > 1;

  /// ★★★ 触发路径 ③：播放器切集（上一集/下一集/自动连播）
  ///
  /// 外层（`media_page.dart`）把 `MediaSession.currentEpisodeId` 传下来；
  /// 播放器一切集它就会变 ⇒ 这里要**跟着滚**。
  ///
  /// ⚠️ 为什么必须在 `didUpdateWidget`（而不是在 build 里）：
  /// ```text
  /// build 里做副作用 ⇒ 每帧都可能触发滚动（用户在手动滚时被拽回去）
  /// didUpdateWidget 只在**父级传下来的值真的变了**时调一次 ✓
  /// ```
  /// ⚠️ 用 `oldWidget.currentEpisodeId != widget.currentEpisodeId` 判"变了"，
  ///    **不能**只判"非 null"—— 否则每次父级 rebuild（很频繁）都会滚一次。
  @override
  void didUpdateWidget(covariant DetailPage old) {
    super.didUpdateWidget(old);
    if (old.currentEpisodeId == widget.currentEpisodeId) return;
    if (widget.currentEpisodeId == null) return;
    debugPrint('[DETAIL] 播放器切集 → ${widget.currentEpisodeId}（自动滚动）');
    _scheduleEpisodeScroll();
  }

  @override
  void initState() {
    super.initState();
    /*
     * ★★★ task-12 ⑤：本地模式**短路**掉"向核心要详情"那条路。
     *
     * ```text
     * 本地播放的 provider 恒为 local、id 恒为绝对路径，
     * 而核心注册表里**没有** local 这个 provider ⇒ getDetail 必然抛
     * 「无法路由: local:…」（真机截图里那块红叹号）。
     * ```
     * ⚠️ 必须放在这里（其它初始化之前）—— 否则下面照旧发那次注定失败的请求。
     */
    if (widget.isLocalFile) {
      unawaited(_initLocal());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
    /*
     * ★ 站名与详情**并行**取（task-32）
     *
     * 它走本地注册表（无网络），而且失败也不影响详情 —— 所以
     * **不 await**，也不放进 `_init` 的 try 里（那里的失败会让整页报错）。
     */
    unawaited(_loadProviderName());
  }

  /// ★★★ 2026-09-27 第三轮：实测「选集之上」的高度（每帧后）
  ///
  /// # 为什么每帧都量（而不是只在 initState 量一次）
  ///
  /// ```text
  /// 那块的高度**会变**：
  /// · 详情/剧集是**异步**到的 ⇒ 首帧还是骨架屏，之后才变高
  /// · 窗口 resize ⇒ 标题/简介折行数变
  /// · 续播条出现/消失
  /// · 「播放源」区（多源时才画）
  /// ⇒ 只量一次 ⇒ 后面所有帧都用错的剩余空间（选集要么溢出、要么留白）
  /// ```
  ///
  /// # 为什么写成"量到不同才 setState"
  ///
  /// ```text
  /// 每帧无条件 setState ⇒ 无限重建循环（post-frame 里 setState 会再排一帧）
  /// ⇒ ★ 必须**比较**：差 > 0.5px 才更新（浮点布局的抖动不值得重建）
  /// ```
  void _measureTop() {
    final ro = _topKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final h = ro.size.height;
    if (_topH != null && (h - _topH!).abs() < 0.5) return;
    /*
     * ★ 打一行日志 —— 与 `[MEDIA] build:` 同一用途：让**真机**能读到
     *   布局判据的实际取值（否则只能靠截图量像素，而锁屏时截不到）。
     */
    debugPrint('[DETAIL] 选集之上实测高 = ${h.toStringAsFixed(1)}px'
        ' ⇒ 选集视口 ${_epsHFor(h).toStringAsFixed(1)}px');
    setState(() => _topH = h);
  }

  /// 由"选集之上实测高"算出选集视口高度（薄封装，规则见顶层
  /// [episodeViewportHeight] 的文档）
  double _epsHFor(double topH) =>
      episodeViewportHeight(topH: topH, availH: _lastAvailH);

  /// 最近一次布局到的可用高（`LayoutBuilder` 的 `maxHeight`）
  double? _lastAvailH;

  @override
  void dispose() {
    // ★ 自己创建的控制器要自己释放（否则热重载/反复进页会泄漏）
    _epsCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ★★★ task-12 ⑤（2026-10-09）：**本地文件模式**的全部逻辑
  // ══════════════════════════════════════════════════════════════════════
  //
  // Owner 原话（逐字）：
  // > 本地播放详情页 **来源** 也还是要用下载的，**封面也要展示**，
  // > 其他都要跟在线播放页一致，除了**集数的展示**，还有那些**操作按钮不显示**，
  // > 其他都要一样的
  //
  // # ★★★ 动手前先核实过的一件事（任务描述里的根因**不成立**）
  //
  // ```text
  // shell.dart:4773 的裁决是：**有**旁文件 ⇒ 走在线路径（provider/id 用站点的、localPath=null）
  //                      **没有**旁文件 ⇒ 才走本地播放（provider=local、id=绝对路径）
  // ⇒ 生产路径上「本地播放」与「下载时记录的 provider/封面」**互斥** ——
  //   本地播放的前提恰恰就是"旁文件不存在"。
  // ```
  //
  // 只读核实的证据（2026-10-09，已报 lead）：
  // · %USERPROFILE% Videos 源影 无职转生 第三季 那个目录里**只有 1 个 mp4，没有 _sourin-cache.json**；
  // · 应用自己的库 dsh-media.db 里 local:… 那两行（progress / history）的 cover 都是 **NULL**。
  //
  // ⇒ 所以"来源与封面"必须**另找出处**，三档（lead 裁决 (b) + 三条硬约束）：
  // ```text
  // ① 能按标题**唯一**认回站点条目  ⇒ 来源=站点名、封面与全部元信息都从该站点真详情来
  // ② 认不回来（0 条 / 命中多条）   ⇒ 来源=「本地」、封面=标题首字占位（**不猜**）
  // ③ 认回来但详情拉失败            ⇒ 来源仍是站点名（那是**记录**，不是猜的），元信息缺席
  // ```
  //
  // ⚠️ 全程**不碰**在线路径的字段（_isFav / _following / _activeSource / _episodes）：
  //    本地文件不属于任何站点，收藏/追更/换线路在它身上没有意义
  //    （Owner 也明确说那几个按钮不要）。

  /// 本地模式的"加载" —— **零 FFI 取详情、零网络**（见上面那段说明）
  Future<void> _initLocal() async {
    final file = widget.localFile;
    if (file == null) return;
    /*
     * ① 首帧就用**缓存下来的作品信息**铺满（Owner ⑬）——
     *    零网络、零 FFI ⇒ 断网时这一页也是完整的。
     *    ⚠️ 本地页本来没有 title/cover 字段（在线路径的标题来自拉回来的详情），
     *      而本地拿不到站点详情 ⇒ 只能用外层给的那几样。
     */
    final meta = widget.localMeta;
    setState(() {
      _detail = MediaDetail(
        id: file,
        title: widget.localTitle ?? widget.id,
        cover: widget.localCover ?? meta?.localCoverPath ?? meta?.cover,
        description: meta?.description,
        year: meta?.year,
        area: meta?.area,
        kind: meta?.kind,
        badges: meta?.badges ?? const <String>[],
      );
      _loading = false;
      _error = null;
    });

    /*
     * ★ 联网探测（Owner ⑬：「有网络那几个按钮也要显示,如没网络就不显示操作按钮」）
     * ⚠️ unawaited ⇒ 绝不影响首帧；结果到了只改 `_online` 重建一次。
     */
    unawaited(_probeNetwork());

    /*
     * ② 来源 + （可能的）真详情 —— 见 [_resolveLocalOrigin]。
     *    ⚠️ await 它：它在**首帧之后**才 setState，不影响首帧显示。
     */
    await _loadLocalOrigin();

    /*
     * ③ 续播条 —— 走 local 命名空间（键就是本页的 provider/id，
     *    与播放器 _saveProgress 写的是**同一对**，见 cache_page 的说明）。
     *    ⚠️ 独立 try/catch：读进度失败不该影响页面其它部分。
     */
    try {
      final p = await SourinApi.getProgress(widget.provider, widget.id);
      if (mounted) setState(() => _resume = p);
    } catch (e) {
      debugPrint('[DETAIL] 本地模式读续播进度失败（不影响其它区块）: $e');
    }
  }

  /// 联网探测（结果只驱动 `_online`，**不阻塞首帧**）
  ///
  /// ⚠️ 失败一律降级成"有网"：按钮少显示一次，好过整页报错。
  Future<void> _probeNetwork() async {
    try {
      await NetworkStatus.probe();
      if (mounted) setState(() => _online = NetworkStatus.online.value);
    } catch (e) {
      AppLog.write('DETAIL', '联网探测失败（按有网处理）: $e');
    }
  }

  /// 本地模式下「那几枚操作按钮」画不画（Owner ⑬：没网就不显示）
  bool get _showLocalActions => !widget.isLocalFile || _online;

  /// ★★★ OPS-9：**这一集磁盘上已经有可播文件** ⇒ 不画那枚「换源」
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// > 这个好像是概率性的,**缓存到本地就不要显示换源按钮了**
  /// ```
  ///
  /// # ⚠️ 与 [_showLocalActions] 是**两件不同的事**（别合并、别互相顶替）
  /// ```text
  /// _showLocalActions  整条操作行画不画   （离线 ⇒ 四枚全不画）
  /// _hasLocalPlayable  只摘掉「换源」     （有本地文件 ⇒ 其余三枚照旧）
  /// ```
  /// ⇒ 上一版把它们混成了一个开关，结果就是"要么四枚都在、要么四枚都不在"，
  ///   而 Owner 要的是**在**的那三枚一个不少、只有换源消失。
  ///
  /// # 三条判据（按优先级；全部读**真实** widget / 队列状态）
  ///
  /// ```text
  /// ① 播放器报了这一集（currentEpisodeId != null）
  ///    ⇒ 这一集的文件名在 localEpisodes 里吗？
  ///       ★ 判据与 [_activeLocalPath] **逐字同源**（本地会话的 episodeId
  ///         就是磁盘文件名 —— 见 cache_page.buildLocalPlayRequest 的调用点），
  ///       ⇒ 本页**不自己拼路径**、不自己 stat 磁盘。
  ///
  /// ② 播放器还没报（currentEpisodeId == null，语义是"还没报"而**不是**
  ///    "没有当前集"—— 见 [_activeEpisodeId] 的长注释）
  ///    ⇒ 进的就是本地页（本页在放一个本地文件），且本地页的选集只列
  ///      **已下载**的那几集 ⇒ localEpisodeCount > 0 即成立。
  ///
  /// ③ 都还没定（在线页 / 本地页刚进来）
  ///    ⇒ 队列里有没有**这一集**的活任务、且**已经落了片**？
  /// ```
  ///
  /// # ③ 为什么必须要求 `done > 0`
  /// ```text
  /// 只有落了片才有"能播的东西"（.part 也算，播放器支持边下边播）；
  /// done == 0 时清单都还没拿到 ⇒ 盘上一个字节都没有 ⇒ 换源照画。
  /// ⚠️ 刻意**不**去扫磁盘上有没有 .part：仓库口径里 .part **不算**"已下好"
  ///    （见 media_page 的 _localEpisodeRefs 只收 e.isComplete）。
  /// ```
  /// ⚠️ [DownloadQueue.tasks] 只在内存（无持久化）⇒ 重启后"已下好"这件事
  ///    只由 ①② 覆盖；③ 管的是"这次会话里正在下的那一集"。
  bool get _hasLocalPlayable {
    final episodes = widget.localEpisodes;

    // ① 播放器报了这一集 —— 复用既有判据（文件名比对），不拼路径
    final reported = widget.currentEpisodeId;
    if (reported != null) {
      for (final e in episodes) {
        if (e.fileName == reported) return true;
      }
      // ★ 报的这一集不在已下载列表里 ⇒ 落到 ③ 看队列（在线页切集的情形）
    }

    // ② 进的就是本地页，且本地页有已下载的集
    if (widget.isLocalFile &&
        (episodes.isNotEmpty || widget.localEpisodeCount > 0)) {
      return true;
    }

    // ③ 这一集正在下载、且已经有可播片段
    final ids = <String>{
      if (reported != null) reported,
      if (_pickedEpisodeId != null) _pickedEpisodeId!,
      if (_selectedEpisodeId != null) _selectedEpisodeId!,
    };
    if (ids.isEmpty) return false;
    for (final t in DownloadQueue.tasks.value) {
      if (t.state != DownloadState.running) continue;
      if (t.done <= 0 || t.total <= 0) continue;
      if (t.provider != widget.provider) continue;
      if (t.mediaId != widget.id) continue;
      if (!ids.contains(t.episodeId)) continue;
      return true;
    }
    return false;
  }

  /// 解析本地模式的「来源」，并把**真封面**用上（task-17 ②）
  ///
  /// 三档行为见上面那段长注释。**无论哪一档都必然给 _localOrigin 一个值** ——
  /// 所以界面上「来源」永远不会空着。
  ///
  /// # ★★★ task-17：**不再调 getDetail**（这是有意的取舍，不是漏了）
  /// ```text
  /// 上一轮（task-12）这里会 `SourinApi.getDetail(hit.provider, hit.id)` 去补一份真详情，
  /// 目的是拿到封面/简介/评分/演员/类型（Owner 当时说"其他都要跟在线播放页一致"）。
  ///
  /// 这一轮去掉了它，三条理由（lead 裁决，逐条落地）：
  /// ① 本地播放的核心价值就是"断网也能看" —— 联网补详情会让它在断网时变慢/变空；
  /// ② 简介/评分/演员/类型**不是这一轮的需求** ——
  ///    Owner 这一轮点名要的是「原来的封面」与「原来源」，而这两样
  ///    progress / favorites 表里**本来就有**（见下面的 cover 字段）；
  /// ③ 真要补也该由**用户主动点**才发请求，而不是进页面就自动打一次网络。
  /// ```
  /// ⚠️ 取舍的**代价**（如实写在代码里，免得下一个人以为是 bug）：
  ///    这里**不会**去补简介/评分/演员/类型 —— 本地页显示什么，取决于
  ///    [_initLocal] 从本地 meta 里铺出来的字段；若 Owner 之后要在线详情，
  ///    正确做法是加一个"查看在线详情"的**显式入口**，不是把网络请求加回这里。
  Future<void> _loadLocalOrigin() async {
    final hit = await _resolveLocalOrigin();
    if (!mounted) return;

    // 认不回来 ⇒ 如实写「本地」（记录里确实没有这一部）
    if (hit == null) {
      setState(() => _localOrigin = kLocalSourceLabel);
      return;
    }

    /*
     * ★★★ task-17 ②：**真来源** —— 走与在线页**同一个** providerDisplayName
     *    （拿不到时它自己退回 id ⇒ 一定非空）。
     */
    final name = await providerDisplayName(hit.provider);
    if (!mounted) return;
    /*
     * ★ task-17 ②：把"从哪一条记录认回来的"写进日志（可溯源）——
     *    这也是 [_localOriginItem] 的**唯一读者**：它让"界面上显示的来源"
     *    与"日志里记的来源"必然同源，排查时不会各说各话。
     */
    final origin = _localOriginItem;
    AppLog.write(
      'LOCAL',
      '采用 ${hit.provider}:${hit.id} 作为来源「$name」'
          '（已存为 ${origin?.provider}:${origin?.id}）',
    );
    setState(() {
      _localOriginItem = (provider: hit.provider, id: hit.id);
      _localOrigin = name;
      /*
       * ★★★ task-17 ②：**真封面** —— 只在本页**还没有**封面时才用记录里的。
       *
       * ⚠️ 只在非空时覆盖：`hit.cover == null` 表示"这条记录没封面"，
       *    那时**保留**外层给的那张（可能来自旁文件），不能用一个 null 把它抹掉。
       * ⚠️ 标题**不动**：外层给的标题就是本地目录名（用户看得见的那个），
       *    而 hit.title 是站点标题 —— 两者归一化后相等，换过去只会让标题"跳一下"。
       *
       * ★★ CR-12：这里**原来**是只要 `hit.cover` 非空就 `MediaDetail(id:,
       *    title:, cover:)` 整个换掉 —— 而 [MediaDetail] 剩下每一个字段都
       *    取默认值，于是 [_initLocal] 刚铺好的 description / year / area /
       *    kind / badges **一起消失**，本地封面路径也被换成记录里的网络图 URL。
       *    最常见的触发路径恰恰是"先在线看过、再下载"（本地目录里 meta 齐全，
       *    progress/favorites 也有带 cover 的一条）。Owner 的反馈就是这个：
       *    本地播放详情页的封面和「来源」要保留。
       *
       *    现在改成：本地页**已经有**封面就一个字节都不动；确实没有封面时，
       *    才把记录里的 cover 补上，并且**照抄**其余字段（不新造一个空壳）。
       *    [MediaDetail] 没有 copyWith，所以只能显式转写。
       */
      final c = hit.cover;
      final cur = _detail;
      if (c != null && c.isNotEmpty && cur != null && (cur.cover ?? '').isEmpty) {
        _detail = MediaDetail(
          id: cur.id,
          title: cur.title,
          cover: c,
          description: cur.description,
          year: cur.year,
          area: cur.area,
          kind: cur.kind,
          actors: cur.actors,
          directors: cur.directors,
          badges: cur.badges,
          meta: cur.meta,
          episodes: cur.episodes,
          sources: cur.sources,
        );
      }
    });
  }

  /// ★★★ task-17 ②：按**标题**把本地文件认回"它是从哪个站的哪一条下载来的"
  ///
  /// # 为什么能这么认（这是**应用自己的数据**，不是猜）
  ///
  /// progress 与 favorites 两张表里存的就是"从某个站看过/收藏过这部片"
  /// 这件事的原始记录，字段是 (provider, native_id, title, cover, updated_at)。
  /// 标题对得上 ⇒ 拿到的是一个**可核对的键** provider:native_id。
  ///
  /// # ★★★ task-17：策略从「不唯一就放弃」改成「排序选一个」
  /// ```text
  /// 上一轮（task-12）：命中多条 ⇒ 放弃 ⇒ 显示「本地」
  /// 这一轮（task-17）：命中多条 ⇒ **排序选第一条** ⇒ 显示真站点名
  /// ```
  /// ⚠️ 这不是"上一轮做错了"，是**需求变了**：
  ///   Owner 原话（task-17）：「点击进去的播放也要显示出来原来源，**而不是 local**」。
  ///   上一轮的"宁可显示本地也不猜"在"要显示出来"这个要求下就成了功能缺失。
  ///
  /// # 排序规则（四级，逐级比较 —— 每一级都要能解释）
  /// ```text
  /// ① 有 cover 的优先    —— 封面是 Owner 这一轮点名要的两样之一（另一是来源）
  /// ② 有 native_id 的优先 —— 没有 id 的记录连"是哪一条"都说不清（理论分支，仍显式处理）
  /// ③ 记录更近的优先     —— progress.updatedAt / favorite.updatedAt 更大者更近；
  ///                        "最近看过的那条"最可能就是用户心里那一条
  /// ④ provider 名字典序  —— ★ 兜底，**只为确定性**：
  ///                        否则同一份数据两次运行可能选到不同的源（不可复现的界面）
  /// ```
  ///
  /// # ★ 匹配判据本身**没有变**：归一化后逐字相等（见 [_normalizeTitle]）
  ///
  /// 只读核实的证据（2026-10-09，真 SQL 查 dsh-media.db 的 progress 表）：
  /// ```text
  /// cycani:3862        无职转生 第三季 ～到了异世界就拿出真本事～  cover=有 updated_at=1791548661356
  /// hongniuzy2:150722  无职转生 第三季 ～到了异世界就拿出真本事～  cover=有 updated_at=1790593398542
  /// ffzy:98495         无职转生Ⅲ～到了异世界就拿出真本事         ← ★ 不命中（Ⅲ ≠ 第三季）
  /// ```
  /// ⇒ 前两条**逐字相同** ⇒ 都是候选 ⇒ 按③（更近）选 **cycani:3862**。
  /// ⇒ 第三条**不该**命中 —— 这正说明"逐字相等"这个判据是有鉴别力的，
  ///    换成模糊相似反而会把 ffzy 也拉进来（那是**另一部**剧的记录）。
  ///
  /// # 两个数据源都要查（与 [resolveFavFollowState] 同一条纪律）
  /// ```text
  /// progress  看过（含在线看了一半的）  ← 最可能命中：用户多半是先在线看过才下载的
  /// favorites 收藏 / 追更过的          ← 补上"收藏了但还没看"的情况
  /// ```
  ///
  /// ⚠️ 自身的 local 行**必须排除**：它的标题就是同一个目录名，
  ///    不排除的话本机看过一次就会把自己算成"命中"，而那是**循环证据**（等于自证）。
  ///
  /// ★ 不联网：只用这两张表已有的字段。
  ///   见 [_loadLocalOrigin] 里那段"为什么不调 getDetail"的说明。
  Future<LocalOriginHit?> _resolveLocalOrigin() async {
    final want = _normalizeTitle(widget.localTitle ?? widget.id);
    if (want.isEmpty) {
      AppLog.write(
          'LOCAL', '来源匹配放弃：标题为空（${widget.provider}:${widget.id}）');
      return null;
    }

    final List<Progress> progress;
    final List<Favorite> favorites;
    try {
      // ★ CR-12：测试口子在**这里**接管（见 [debugLocalOriginRecords] 的说明）。
      //   为 null 时下面两句一字未改 ⇒ 生产路径与改前完全一致。
      final injected = debugLocalOriginRecords;
      if (injected != null) {
        final rec = injected();
        progress = rec.progress;
        favorites = rec.favorites;
      } else {
        final r = await Future.wait([
          SourinApi.listAllProgress(),
          SourinApi.listFavorites(),
        ]);
        progress = (r[0] as List).cast<Progress>();
        favorites = (r[1] as List).cast<Favorite>();
      }
    } catch (e) {
      AppLog.write('LOCAL', '来源匹配放弃：读应用自己的记录失败 $e');
      return null;
    }

    /*
     * 合并去重：键用 provider:nativeId（与全项目统一的主键格式一致）。
     * ⚠️ 同一个 key 在两个源都出现时**取更近的那个时间**（见下面的 merge 分支）——
     *    否则"在收藏里更新时间更近、在 progress 里更早"会按哪个算就成了偶然。
     */
    final byKey = <String, LocalOriginHit>{};
    void consider({
      required String provider,
      required String nativeId,
      required String title,
      String? cover,
      required int at,
    }) {
      if (provider.isEmpty || nativeId.isEmpty) return;
      // ★ 排除循环证据：local 是本机自己的命名空间（见上面那条警告）
      if (provider == kLocalProvider) return;
      if (_normalizeTitle(title) != want) return;
      final key = '$provider:$nativeId';
      final prev = byKey[key];
      if (prev == null) {
        byKey[key] = LocalOriginHit(
          provider: provider,
          id: nativeId,
          title: title,
          cover: cover,
          at: at,
        );
        return;
      }
      // 已有 ⇒ 合并：封面取非空的那个、时间取更近的那个
      byKey[key] = LocalOriginHit(
        provider: prev.provider,
        id: prev.id,
        title: prev.title,
        cover: (prev.cover?.isNotEmpty ?? false) ? prev.cover : cover,
        at: at > prev.at ? at : prev.at,
      );
    }

    for (final p in progress) {
      consider(
        provider: p.provider,
        nativeId: p.nativeId,
        title: p.title,
        cover: p.cover,
        at: p.updatedAt,
      );
    }
    for (final f in favorites) {
      consider(
        provider: f.provider,
        nativeId: f.nativeId,
        title: f.title,
        cover: f.cover,
        at: f.updatedAt,
      );
    }

    if (byKey.isEmpty) {
      AppLog.write('LOCAL', '来源匹配：未命中（标题「$want」）⇒ 来源显示「本地」');
      return null;
    }

    final ranked = rankLocalOriginHits(byKey.values.toList());
    final chosen = ranked.first;

    if (ranked.length == 1) {
      AppLog.write(
        'LOCAL',
        '来源匹配：唯一命中 ${chosen.provider}:${chosen.id}（标题「$want」）⇒ 采用',
      );
    } else {
      /*
       * ★ 多条 ⇒ **排序选第一条**（task-17 策略）并写清**为什么是它**：
       *    日志要能回答"另外几条输在哪一级"，否则这个启发式仍然不可调试。
       */
      final why = <String>[];
      for (final h in ranked.skip(1)) {
        why.add('${h.provider}:${h.id}（${_explainLoser(chosen, h)}）');
      }
      AppLog.write(
        'LOCAL',
        '来源匹配：命中 ${ranked.length} 条 ⇒ **排序选第一条** ${chosen.provider}:${chosen.id}（cover=${chosen.cover != null ? "有" : "无"} 时间=${chosen.at}）'
            '；其余：${why.join('、')}',
      );
    }
    return chosen;
  }

  /// 解释"落选者输在哪一级" —— 让排序可复核（日志用）
  static String _explainLoser(LocalOriginHit win, LocalOriginHit lose) {
    if ((win.cover?.isNotEmpty ?? false) != (lose.cover?.isNotEmpty ?? false)) {
      return '输在封面（winner ${win.cover != null ? "有" : "无"} / loser ${lose.cover != null ? "有" : "无"}）';
    }
    if (win.at != lose.at) {
      return '输在时间（winner ${win.at} > loser ${lose.at}）';
    }
    return '输在站点名字典序（${win.provider} < ${lose.provider}）';
  }

  /// 取当前站点的显示名（task-32）
  ///
  /// ⚠️ 失败/拿不到时**保留 null** —— 那时不渲染这个 chip，
  ///    而不是渲染一个空的或写着 id 的假 chip
  ///    （`providerDisplayName` 内部已保证"拿不到就退回 id"，
  ///     所以这里只要能拿到就一定是有内容的字符串）。
  Future<void> _loadProviderName() async {
    final n = await providerDisplayName(widget.provider);
    if (!mounted) return;
    setState(() => _providerName = n);
  }

  Future<void> _init() async {
    try {
      final d = await SourinApi.getDetail(widget.provider, widget.id);
      if (!mounted) return;
      setState(() {
        _detail = d;
      });
      /*
       * ★ task-58：通知外层"详情到了"
       *
       * 合并页里播放器**先于**详情起播（它一进页就开流）⇒ 那一刻没有标题。
       * 外层拿到 `MediaDetail` 后把标题转给播放器顶栏。
       * ⚠️ 放在 `setState` **之后**：让外层的回调看到的状态与这里一致。
       * ⚠️ 不 await（外层若做异步工作不该阻塞详情渲染）。
       */
      widget.onLoaded?.call(d);

      /*
       * 默认选中第一个源，并加载其剧集
       *
       * ⚠️ 这里**不能**用 `sources.length > 1` 作为「是否拉取剧集」的条件：
       *    原版注释记录过实测 —— cycani 的《指名！》只有一个源（cychub），
       *    但下面挂着 24 集。只在多源时才拉，会导致单源多集的内容
       *    **一集都看不到**，只能播第一集。
       *    正确判据是「是否声明了源」—— 有源就按该源拉一次。
       *
       * 源的选择顺序：**上次记住的偏好** > 第一个源。
       */
      final srcs = _sourceNodes;
      final remembered = UiPrefs.sourcePref(widget.provider, widget.id);
      /*
       * ★ 偏好要能在**嵌套层**里命中
       *
       * 用户上次可能选的是第二层的线路。若只在顶层找，
       * 记住的偏好会失效、静默跳回第一个源 —— 而原版
       * `SourcePicker.vue:49-52` 的 `containsActive` 正是为
       * "选中项可能在子树里"写的。
       *
       * ⚠️ 用 `PlaySource.flattened`（模型自带的展平），
       *    不再借道 `DetailSourceNode`。
       */
      PlaySource? preferred;
      for (final s in srcs) {
        final hit = s.flattened.where((x) => x.code == remembered).firstOrNull;
        if (hit != null) {
          preferred = hit;
          break;
        }
      }
      preferred ??= srcs.isNotEmpty ? srcs.first : null;

      if (preferred != null) {
        final preferredCode = preferred.code;
        setState(() {
          _activeSource = preferredCode;
          // 先用 detail 里已带的剧集占位，再按源拉一次权威列表
          _episodes = d.episodes;
        });
        await _loadEpisodes(preferredCode);
      } else {
        setState(() => _episodes = d.episodes);
      }

      /*
       * 收藏 / 追更状态
       *
       * ★★★ **必须查两个列表** —— 只查收藏列表会让"只追更未收藏"的条目
       *     被误判成"未追更"（用户报的真 bug）。
       *
       * 完整根因、原版对照（原版 MyShelf 修了、DetailView 漏了）、
       * 以及"为什么不能加互斥"都写在 [resolveFavFollowState] 的文档里。
       *
       * ⚠️ 两个查询**并行**（`Future.wait`）—— 串行会让详情页多等一个 IPC。
       *    与 `follow_page.dart:324-325` 同一口径。
       */
      final lists = await Future.wait([
        SourinApi.listFavorites(), // 收藏：WHERE favorited=1
        SourinApi.listFavorites(followingOnly: true), // 追更：WHERE following=1
      ]);
      final state = resolveFavFollowState(
        favorites: lists[0],
        following: lists[1],
        key: '${widget.provider}:${widget.id}',
      );
      if (mounted) {
        setState(() {
          _isFav = state.favorited;
          _following = state.following;
        });
      }

      final r = await SourinApi.getProgress(widget.provider, widget.id);
      if (mounted) setState(() => _resume = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadEpisodes(String code) async {
    setState(() => _epsLoading = true);
    try {
      /*
       * ★ 按源拉剧集必须走 `get_episodes(provider, id, sourceCode)`
       *
       * 原版这里写的是重新调一次 `detail()` —— 那是**取不到指定源的剧集**的
       * （detail 返回的是默认源的剧集）。正确的命令是 get_episodes。
       */
      final eps = await SourinApi.getEpisodes(
        widget.provider,
        widget.id,
        code,
      );
      if (mounted) {
        setState(() {
          _episodes = eps;
          _pruneEpisodeKeys();
        });
        // ★ 触发路径 ①：剧集加载完 ⇒ 滚到当前集
        _scheduleEpisodeScroll();
      }
    } catch (e) {
      debugPrint('[DETAIL] 加载剧集失败: $e');
    } finally {
      if (mounted) setState(() => _epsLoading = false);
    }
  }

  Future<void> _pickSource(PlaySource s) async {
    if (_activeSource == s.code) return;
    setState(() => _activeSource = s.code);
    // 记住偏好，下次进这个作品自动选中
    UiPrefs.setSourcePref(widget.provider, widget.id, s.code);
    await _loadEpisodes(s.code);
    /*
     * ★ toast 文案用 `label`（= `title || code`）
     *
     * 原版 `DetailView.vue:253`：
     * ```js
     * flash(`已切换到「${s.title || s.code}」`);
     * ```
     * ⚠️ 修好 `PlaySource.title` 之前这里会显示成「已切换到「」」——
     *    空壳提示（因为旧字段 `name` 读的键后端从不下发）。
     */
    _flash('已切换到「${s.label}」');
  }

  /// ★★★ 收藏 / 取消收藏
  ///
  /// # Owner 报的问题（2026-09-19）
  ///
  /// > 我取消收藏 提示成功，返回首页，还是在收藏列表中，
  /// > 点进去还是收藏状态，根本没取消
  /// > 我再点取消，反复几次，页面就异常显示了
  ///
  /// # 上一版错在哪（两个错，都要修）
  ///
  /// **错误 1：调错了命令**
  /// 用 `toggle()` 来「取消收藏」，但后端 `toggle_favorite`
  /// **没有删除分支** —— 它只有"新建"与"复活"。所以"取消"反而把它**复活**了。
  ///
  /// **错误 2：本地状态靠猜**
  /// ```js
  /// isFav = !isFav;   // ← 自己翻转，不看后端返回什么
  /// ```
  /// 一旦后端没按预期变，前端就与后端**越差越远** ——
  /// 用户点 5 次，界面翻了 5 次，数据一次没动。
  ///
  /// # 现在的做法
  ///
  /// ```text
  /// ① 用 `setFavorite(on: 目标状态)` —— 显式告诉后端要什么
  /// ② 状态**从后端返回值读**，不自己翻转
  /// ③ 失败时把状态**回滚**并提示
  /// ```
  ///
  /// # ★★★ 取消收藏时**不要**顺手关掉追更（2026-09-21 Owner 报）
  ///
  /// > 在追更和收藏都打开的情况下，无法取消收藏
  /// > 必须要取消追更，才能取消收藏，这两个是不需要联动的
  ///
  /// 而且它还会**掩盖**真正的 bug：
  /// 乐观地把 `following` 置 false 后，后端返回的 `deleted` 恰好
  /// 与 `!favorited` 一致，于是本地看起来"取消成功了"，
  /// 直到刷新页面才暴露出后端其实 `deleted=0`。
  ///
  /// 后端 `unfavorite` 的语义是明确的：
  /// ```text
  /// 取消收藏 → favorited=0，following **原样保留**
  /// ```
  /// 前端不该自行加一层联动。现在这里**什么都不做** ——
  /// 让后端返回的真实状态说了算。
  Future<void> _toggleFav() async {
    final want = !_isFav;
    final prevFav = _isFav;
    final prevFollowing = _following;

    // 乐观更新：先改界面，让点击**立刻有反馈**
    setState(() => _isFav = want);

    try {
      final r = await SourinApi.setFavorite(
        widget.provider,
        widget.id,
        on: want,
        title: _detail?.title ?? widget.id,
        cover: _detail?.cover,
        kind: _detail?.kind,
        /*
         * ★★★ **不传 following** —— 收藏就是收藏，不隐含追更
         *
         * Owner 报的语义混淆：
         * > 我发现我现在点击收藏就会触发追更
         * > 这是两个完全不同的功能啊，收藏是仅仅收藏
         *
         * 传 null 表示"不改追更状态"：
         * ```text
         * 新建收藏   → 后端默认 following: false（纯收藏）
         * 已收藏再点 → 保留用户自己设的追更状态
         * 取消收藏   → 后端 tombstone 分支本来就会置 false
         * ```
         */
      );

      if (!mounted) return;
      /*
       * ★ 用**后端返回的真实状态**覆盖乐观值
       *
       * ★★★ 判据必须是 `favorited`，**不能是 `deleted`**
       *
       * 在「收藏与追更解耦」**之前**，`deleted` 确实兼任"是否收藏"；
       * 解耦后它的语义变成了 **"两个状态都没了"**：
       * ```text
       * deleted=1  ⇔  !favorited && !following
       * ```
       * 后端 `unfavorite` 按这个不变量写：
       * ```sql
       * SET favorited=0, deleted = CASE WHEN following=0 THEN 1 ELSE 0 END
       * ```
       * 于是**追更还开着时 `deleted` 仍是 0**：
       * ```text
       * 取消收藏 → favorited=0, following=1, deleted=0
       *          → 前端算出 isFav = !0 = true  ★ 按钮又变回"已收藏"
       * ```
       * 用户看到的就是"取消不掉"，只能先把追更关掉。
       */
      setState(() {
        _isFav = r.favorited;
        _following = r.following;
      });
      _flash(_isFav ? '已收藏' : '已取消收藏');
    } catch (e) {
      // ★ 失败要回滚，不能让界面显示一个不存在的状态
      if (mounted) {
        setState(() {
          _isFav = prevFav;
          _following = prevFollowing;
        });
      }
      _flash('操作失败：$e');
    }
  }

  /// ★★★ 追更（**不需要先收藏**）
  ///
  /// Owner 的第二次纠正（2026-09-20）：
  /// > 追更并不代表就要收藏，这是独立的状态
  ///
  /// 所以「请先收藏」这种拦截是**错的**。点追更就只是开追更 ——
  /// 不会偷偷收藏，也不需要先收藏。
  ///
  /// # 必须用 `setFollowing`，**不能用 `setFavorite(on: true)`**
  ///
  /// 这是一个真 bug（2026-09-19 审计发现）：
  /// `set(on: true)` 里有**复活语义**（后端 `if fav.deleted { fav.deleted = false }`）——
  /// 于是追更按钮变成了**取消收藏的后悔药**：
  /// ```text
  /// 用户取消了收藏        → 收藏列表里没有了
  /// 用户又点了一下「追更」 → ★ 那个内容又回到收藏列表
  /// ```
  /// 实测复现：`{deleted:1, following:1}` → 点追更 → `{deleted:0, following:0}`
  ///
  /// `setFollowing` 的语义是"只改追更、绝不碰 deleted"。
  Future<void> _toggleFollow() async {
    final want = !_following;
    final prev = _following;
    setState(() => _following = want); // 乐观更新

    try {
      final r = await SourinApi.setFollowing(
        widget.provider,
        widget.id,
        following: want,
        // 传元信息，让"只追更"新建行时有标题可显示
        title: _detail?.title ?? widget.id,
        cover: _detail?.cover,
        kind: _detail?.kind,
      );

      if (!mounted) return;
      if (r != null) {
        setState(() {
          _following = r.following;
          /*
           * ⚠️ 同时同步收藏状态 —— 后端可能因为"只追更不收藏"
           *    而返回 `favorited: false`。不同步的话，
           *    用户会看到"我明明点的是追更，收藏却亮了"。
           */
          _isFav = r.favorited;
        });
        _flash(_following ? '已开启追更' : '已关闭追更');
      } else {
        /*
         * 返回 null = 没有可改的记录（关一个本来就不存在的追更）。
         * 那是幂等的空操作，同步成真实状态即可。
         */
        setState(() => _following = prev);
        _flash('操作未生效');
      }
    } catch (e) {
      if (mounted) setState(() => _following = prev);
      _flash('操作失败：$e');
    }
  }

  void _flash(String msg) {
    if (!mounted) return;
    setState(() => _toast = msg);
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted && _toast == msg) setState(() => _toast = null);
    });
  }

  /// 按 id 找一集（找不到返回 null）
  ///
  /// ⚠️ 不用 `firstWhereOrNull`：那要引 `package:collection`，
  ///    而这个类里已经有 5 处 `firstOrNull` 了 —— 再多一个依赖不值。
  Episode? _episodeById(String? id) {
    if (id == null) return null;
    for (final e in _episodes) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 播放（可指定剧集）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-08（业主报的 bug）：`ep == null` 时必须用**当前高亮的那一集**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// 现象（业主原话）：
  ///   「我从播放历史进入,也有播放记录 上次看到原声版65分钟,
  ///     但是进来后自动播放普通话版」
  ///
  /// 链条：
  ///   ① 这里原来在 ep == null 时把 episodeId / episodeTitle / episodeIndex
  ///      全传 **null**（点「播放 / 继续观看」按钮走的就是这条路）
  ///   ② 播放器 player_page.dart:894 `late int _epIndex = widget.episodeIndex ?? 0`
  ///      ⇒ null 落到 **0** = 剧集列表的第一集
  ///   ③ 而「普通话 / 原声版」这类配音版本在数据里就是**两个剧集**
  ///      ⇒ 高亮在「原声版」（_activeEpisodeId 算对了），播的却是「普通话」
  ///
  /// 更糟的是 resolveStream：`player_page.dart:2730` 的判据是
  ///   `widget.sourceCode != null || widget.episodeId != null`
  /// ⇒ episodeId 为 null 时**连 PlayRequest 都不构造**，插件按「没指定集」
  ///   返回默认集（通常就是第一集）⇒ 音轨/配音版本也跟着错。
  /// ```
  ///
  /// ⇒ 修法：`ep` 为 null 时回退到 [_activeEpisodeId] 反查出的 Episode
  ///   （优先级：播放器真在播的 → 用户刚点的 → 上次观看记录 → 第一集）。
  void _play([Episode? ep]) {
    final d = _detail;
    if (d == null) return;

    final target = ep ?? _episodeById(_activeEpisodeId);
    final idx =
        target != null ? _episodes.indexWhere((e) => e.id == target.id) : -1;

    /*
     * ★ 记住用户手动点的这一集 —— 选集区据此高亮。
     *
     * ⚠️ 放在跳转**之前**：万一跳转抛错，至少高亮与用户的点击一致。
     *    而 `ep` 为 null 时（走「播放/继续观看」按钮）**不要**覆盖 ——
     *    那种情况本来就该由 `_resume` 决定高亮哪一集。
     */
    if (ep != null) setState(() => _pickedEpisodeId = ep.id);

    /*
     * ★ 触发路径 ②：用户点了某一集 ⇒ 把它滚进可视区
     *
     * ⚠️ 放在 `onPlay` **之前**：`onPlay` 会跳到播放器（合并页里是切到
     *    播放态），那时本页可能已被遮挡 —— 滚动要在**还看得见**时发起。
     */
    if (ep != null) _scheduleEpisodeScroll();

    widget.onPlay?.call(
      PlayRequestData(
        provider: widget.provider,
        id: widget.id,
        title: d.title,
        cover: d.cover,
        episodeId: target?.id,
        episodeTitle: target?.title,
        sourceCode: _activeSource.isEmpty ? null : _activeSource,
        episodes: _episodes,
        episodeIndex: idx >= 0 ? idx : null,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 2026-10-08（Owner 第 4 条）整片下载
  // ═══════════════════════════════════════════════════════════════════

  /// 下载**当前这一集**（整片）
  ///
  /// 「当前」的判据与 [_play] 完全一致：
  /// `_activeEpisodeId`（播放器在播的 → 用户刚点的 → 上次观看 → 第一集）。
  /// ★ 用同一个 getter 而不是另写一套 —— 否则会出现
  ///   「播的是第 5 集、下载的是第 1 集」这种最难查的错位。
  void _downloadCurrent() {
    final ep = _episodeById(_activeEpisodeId);
    if (ep == null) {
      _flash('这一集还没有可下载的剧集信息');
      return;
    }
    _enqueueOne(ep);
  }

  /// 下载**所有集**（整片，串行队列）
  ///
  /// ⚠️ 二次确认**必须**有：一次点下去可能是 24 集 × 几百 MB，
  ///    而它在后台跑、用户看不到成本（流量 + 磁盘）。
  Future<void> _downloadAll() async {
    final n = _episodes.length;
    if (n == 0) {
      _flash('还没有剧集列表');
      return;
    }
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载全部集'),
        content: Text(
          '将下载全部 $n 集到「视频 / 源影 / ${_detail?.title ?? ''}」，'
          '一次只下一集（把带宽留给播放），可以随时取消。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('下载 $n 集'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var added = 0;
    for (final ep in _episodes) {
      if (_enqueueOne(ep, quiet: true)) added++;
    }
    _flash(added == 0 ? '这些剧集都已经在下载队列里了' : '已加入 $added 集到下载队列');
  }

  /// 入队一集（返回是否真的加进去了）
  bool _enqueueOne(Episode ep, {bool quiet = false}) {
    final d = _detail;
    if (d == null) return false;
    final idx = _episodes.indexWhere((e) => e.id == ep.id);
    final task = DownloadTask(
      id: '${widget.provider}:${widget.id}:${ep.id}',
      title: d.title,
      episodeTitle: ep.title,
      provider: widget.provider,
      mediaId: widget.id,
      episodeId: ep.id,
      sourceCode: _activeSource.isEmpty ? null : _activeSource,
      fileName: DownloadDir.episodeFileName(
        title: d.title,
        episodeTitle: ep.title,
        index: idx < 0 ? 0 : idx,
        multiEpisode: _episodes.length > 1,
      ),
      // ★★★ task-11 ④：把封面带上 —— 下载完成后写进剧集目录的旁文件，
      //    「已缓存」页据此显示封面（详见 download_queue 的 _writeSidecarFor）。
      cover: d.cover,
      /*
       * ★★★ Owner 第 1009 批 13：把作品元数据**一起缓存下来**
       * ```text
       * 本地播放页要"跟在线播放页一模一样"（简介/年份/地区/类型/角标），
       * 而这些只有详情接口能给，离线时永远拿不到
       * ⇒ 唯一能离线显示的时机就是**入队这一刻**（那时详情就在手里）。
       * ⚠️ 全部可空：插件没给就留空，本地页降级显示，不崩也不编造。
       */
      description: d.description,
      year: d.year,
      area: d.area,
      kind: d.kind,
      badges: d.badges,
    );
    final added = DownloadQueue.enqueue(task);
    if (!quiet) {
      _flash(added
          ? '已加入下载队列（${_episodes.length > 1 ? '共 ${_episodes.length} 集，' : ''}后台串行下载）'
          : '这一集已经在下载队列里了');
    }
    return added;
  }

  /// ★★★ 跨源换源（借鉴 阅读 / 洛雪 / 异次元）
  ///
  /// # Owner 的要求（原话）
  ///
  /// > 还是不能切源 同个电视剧,不能切相同的源,你就借鉴一下
  /// > github有个叫阅读的app 还有 洛雪 还有 异次元 漫画软件,
  /// > 这些都可以并且支持对同一个视频切换源看的
  ///
  /// # 流程
  ///
  /// ```text
  /// 点「换源」→ 弹层按**标题**搜全部源 → 按相似度排序
  ///   → 用户点一个 → 跳到那个源的详情页
  /// ```
  ///
  /// ⚠️ 用**重新打开详情页**而不是原地换 provider ——
  ///    因为新源的 id、剧集、线路全都不一样，整页重新加载最干净。
  ///    原版也是这么做的（`router.push` 到新 provider 的详情路由）。
  ///
  /// ⚠️ 顺带把进度带过去（`ep` / `pos`）——
  ///    这正是三个参考 App 的「保留进度」。
  Future<void> _openSwitchSource() async {
    final d = _detail;
    if (d == null) return;

    /*
     * ★ 传**当前真实进度**而不是初始值
     *
     * 用户可能在这个页面停留了一会儿，`_resume` 是进页面时读的。
     * 换源要续播的是"他刚才看到哪儿"。
     */
    final pos = _resume?.position ?? 0;

    /*
     * ★★★ 必须用 [_currentEpisodeIndex]，**不能**用 [_activeEpisodeId] 反推
     *
     * 原版 `DetailView.vue:129-134` 的判据是**只看进度**：
     * ```js
     * const currentEpisodeIndex = computed(() => {
     *   if (!resume.value) return 0;                       // ← 没进度就是 0
     *   const i = episodes.value.findIndex(e => e.id === resume.value.episode_id);
     *   return i >= 0 ? i + 1 : 0;
     * });
     * ```
     * 而 `_activeEpisodeId` 在没有进度时会**兜底成第一集**
     * （见 `_selectedEpisodeId` 的"② 否则第一集"），于是：
     * ```text
     * 全新作品、没有任何观看记录
     *   原版   episodeIndex = 0   → 换源后不试图定位到某一集
     *   我们   episodeIndex = 1   → ★ 换源后被当成"看到第 1 集"
     * ```
     * `0` 在换源语义里是**哨兵值**（"没有剧集概念 / 没看过"），
     * 见原版 `SourceSwitchDialog.vue:50` 的注释
     * 「没有剧集概念时传 0」—— 拿 1 顶替会让它误判。
     */
    final epIdx = _currentEpisodeIndex;

    /*
     * ★ task-58：可判读的日志（验收判据⑤"同页换源"依赖它）
     *
     * 合并页里"换源"**不再** `pushReplacement` 一个详情页，而是
     * 走 `onOpenDetail` ⇒ `MediaPage._onDetailSwitchSource` ⇒
     * `MediaSession.applySession`（同一个播放器换流）。
     * 而这条链路**没有** `[NAV]` 日志（不 push 路由）⇒
     * 若不在这里留一行，判据⑤就**无法从日志判定**
     * （只能靠"导航日志没有增加"这种**否定证据**，那不够）。
     */
    debugPrint('[DETAIL] 打开换源弹层：当前=${widget.provider}:${widget.id} '
        '站名=${_activeSourceName ?? "(未知)"} epIdx=$epIdx pos=${pos}s');

    final pick = await showSourceSwitchDialog(
      context,
      title: d.title,
      currentProvider: widget.provider,
      currentProviderName: _activeSourceName,
      episodeIndex: epIdx,
      position: pos,
    );
    if (pick == null || !mounted) {
      debugPrint('[DETAIL] 换源弹层：用户取消（pick=null）或页面已卸载');
      return;
    }

    debugPrint('[DETAIL] 换源弹层选中 ⇒ ${pick.provider}:${pick.id} '
        '⇒ 交给外层（合并页里 = 页内换源，不 push 路由）');

    /*
     * ★ 跳到新源 —— 两种用法在这一行的**语义不同**（同一个回调）：
     * ```text
     * 独立详情页（embedded=false）⇒ shell 的 `_openDetail` ⇒ push 新详情页
     * 合并页（embedded=true）     ⇒ `MediaPage._onDetailSwitchSource`
     *                              ⇒ 页内换源（同一个播放器，不 push）
     * ```
     * 回调本身不用改 —— 由**调用方**决定语义（这是它作为回调的价值）。
     */
    widget.onOpenDetail?.call(pick.provider, pick.id);
  }

  /// 当前播放源的显示名（换源弹层里标「当前」用）
  String? get _activeSourceName {
    if (_sourceNodes.isEmpty) return null;
    for (final s in _sourceNodes) {
      final hit = s.flattened.where((x) => x.code == _activeSource).firstOrNull;
      // ⚠️ 用 label（title || code）而不是 name —— 真名是 title，见文件头
      if (hit != null) return hit.label;
    }
    return _activeSource;
  }

  /// 续播 chip 的**标题那一半**（唯一可被省略号截断的部分）
  ///
  /// ★★★ 桌面端第 4 条把它从 `_fmtResume` 里拆出来，理由是**排版**：
  ///   原来是一个整串 `'标题 · 剩 N 分钟'`，一旦标题太长被截断，
  ///   **被截掉的恰恰是「剩 N 分钟」**（它在串尾）—— 而那才是这条
  ///   提示里唯一会变、且用户真要看的信息，标题反而是背景。
  ///   ⇒ 拆成两段：标题进 `Flexible` 收省略号，时间独立成一段**不参与压缩**。
  ///
  /// ⚠️ 文案与判据沿用原版 `DetailView.vue:542-546` 的 `fmtResume`，
  ///   不改语义（`episode_title || "单集"`）。
  String _resumeTitle(Progress p) => p.episodeTitle ?? '单集';

  /// 续播 chip 的**剩余时间那一半**（短、固定、**永不**被截断）
  String _resumeRemaining(Progress p) {
    final left = (p.duration - p.position).clamp(0, 1 << 30);
    return '剩 ${left ~/ 60} 分钟';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ★ task-58：合并页里**不画 Scaffold/SafeArea**
     *
     * 因为外层 `MediaPage` 已经提供了页面骨架，再套一层 Scaffold 会：
     * ```text
     * ① 多一层 Material（背景色盖住视频区的黑底）
     * ② SafeArea 会把"下半屏"当成整屏来算内边距 ⇒ 底部留白错位
     * ```
     * ⇒ 用一个共享的 `content` 变量，两种用法只在**外壳**上不同。
     */
    final content = Stack(
      children: [
        if (_loading)
          const Center(child: AppLoading())
        else if (_error != null)
          _ErrorView(
            message: _error!,
            /*
             * ★ 独立页面的错误视图有"返回"；合并页里那个返回**语义不同**
             *   （合并页的返回要回首页，且顶部已有返回）⇒ 嵌
             *   入时不画它（`onBack: null` 让 `_ErrorView` 自己决定）。
             */
            onBack: widget.embedded ? null : () => Navigator.pop(context),
          )
        else if (_detail != null) _buildBody(context, _detail!),

        // ── Toast ──
        if (_toast != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: Sp.x10,
            child: Center(child: _Toast(text: _toast!)),
          ),
      ],
    );

    /*
     * ═══════════════════════════════════════════════════════════════════
     * ★★★ task-60 ①：嵌入态**必须自己画主题底色**
     * ═══════════════════════════════════════════════════════════════════
     *
     * # 缺陷（Owner 原话 + Lead 实测）
     *
     * Owner：
     * > 进来之后只有黑色，**文字也反色的看不清**，体验太差了
     *
     * Lead 实测（`.probe/ROOTCAUSE-merge-black.md`）：
     * ```text
     * 详情区标题文字最亮像素 = #1E2028   (= LightTokens.textPrimary)
     * 该文字背后的背景       = #000000
     * ⇒ WCAG 对比度 = 1.29 : 1     ← 几乎完全不可见
     * ```
     *
     * # 根因（**两条**，缺一不可）
     *
     * ```text
     * (a) media_page.dart 窗口态曾硬编码 Colors.black   ← T1 负责修
     * (b) 这里 `return content;` 返回的是**裸 Stack，没有背景**
     *     ⇒ 底色**完全依赖父级**                        ← ★ 本任务负责
     * ```
     *
     * # 为什么两边都要修（这是本条的关键理由）
     *
     * ```text
     * 只修 (a)：父级不再是黑的了 ⇒ 今天看着是对的
     *           但本页仍然"没有自己的底色"
     *           ⇒ ★ 下次谁再改父级（换主题、加渐变、改布局），本页又跟着坏
     * 两边都修：(b) 让本页**自带**主题底色 ⇒ 与父级解耦
     *           ⇒ 父级怎么改都不会让文字落到对比度不足的底上
     * ```
     * ⇒ 这叫"把不变量放在**拥有它的那一层**"：详情区的可读性是**本页**的属性，
     *   不该由父级代为保证。
     *
     * # 为什么是 `colors.surface` 而不是别的颜色
     *
     * 与下面非 embedded 分支的 `Scaffold(backgroundColor: colors.surface)`
     * **同源** —— 两种用法（独立页 / 嵌入页）必须长得一样，
     * 否则同一份内容在两种入口下底色不同。★ 不许另造颜色常量。
     */
    if (widget.embedded) {
      return ColoredBox(color: colors.surface, child: content);
    }

    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(child: content),
    );
  }

  /// 头部「海报 + 元信息」区 —— **按实际可用宽度**分档
  ///
  /// ═══════════════════════════════════════════════════════════════════
  /// ★★★ 为什么不能用 `MediaQuery.of(context).size.width`（task-60 的坑）
  /// ═══════════════════════════════════════════════════════════════════
  ///
  /// 原判据是 `MediaQuery.of(context).size.width < 760`。
  /// 而 T1 把本页放进右栏时用的是 **`SizedBox(width: detailW)`** ——
  /// ★ `SizedBox` **不会**重新界定 `MediaQuery`。
  ///
  /// ⇒ 实测（`test/t59_embed_theme_test.dart` 第①组，用 384px 侧栏 + 1280 窗口）：
  /// ```text
  /// MediaQuery.width = 1280.0      ← 仍是**窗口**宽度，不是 384
  /// ⇒ isNarrow = (1280 < 760) = **false**
  /// ```
  /// ⇒ ★★ 所以侧栏里走的**不是**窄屏 Column，而是**宽屏 Row**：
  /// ```text
  /// _Cover(width: 212) + SizedBox(24) + Expanded(_Info)
  /// 侧栏 340px − 左右 contentPadding(24×2) = 可用 292px
  /// 292 − 212 − 24 = **56px** 留给 _Info
  /// ```
  /// **56px 宽的信息栏** —— 标题、徽章、三个按钮全挤在里面 ⇒
  /// ★ 这就是 Owner 说的「**很丑**」的真正形态
  ///（任务描述里假设的"侧栏里恒为窄屏 Column"**不成立**，实测已证伪）。
  ///
  /// # 修法：用 `LayoutBuilder` 拿**真实约束**
  ///
  /// ```text
  /// LayoutBuilder.constraints.maxWidth = 父级真正给本区的宽度
  /// ```
  /// 这才是"我有多少地方可画"的权威答案，与窗口多大无关。
  ///
  /// # 分档（阈值都按**可用宽度**，不是窗口宽度）
  ///
  /// ```text
  /// >= 620  宽档：封面 212 + 信息并排          ← ★ 与改动前**逐字相同**
  /// 420..620 中档：封面 138 + 信息并排（封面缩小，把宽度让给信息）
  /// < 420   紧凑档：封面 112 在上、信息在下（信息拿到**整行**宽度）
  /// ```
  ///
  /// ★ **宽视口行为不变**的证明：窗口 1280 ⇒ 可用 1280−48 = 1232 ≥ 620 ⇒ 宽档；
  ///   窗口 760（原阈值边界）⇒ 可用 712 ≥ 620 ⇒ 仍是宽档
  ///   ⇒ 与改动前的 `isNarrow=false` **一致**（冻结契约）。
  ///
  /// ★ 侧栏 340–440 ⇒ 可用 292–392 < 420 ⇒ **紧凑档**
  ///   ⇒ 信息拿到整行 292–392px（原来是 56px）—— 这是"不丑"的关键。
  /// 头部「海报 + 元信息」区 —— **按实际可用宽度**分档
  ///
  /// ═══════════════════════════════════════════════════════════════════
  /// ★★★ 为什么不能用 `MediaQuery.of(context).size.width`（task-60 的坑）
  /// ═══════════════════════════════════════════════════════════════════
  ///
  /// 原判据是 `MediaQuery.of(context).size.width < 760`。
  /// 而 T1 把本页放进右栏时用的是 **`SizedBox(width: detailW)`** ——
  /// ★ `SizedBox` **不会**重新界定 `MediaQuery`。
  ///
  /// ⇒ 实测（`test/t59_embed_theme_test.dart` 第①组，384px 侧栏 + 1280 窗口）：
  /// ```text
  /// MediaQuery.width = 1280.0      ← 仍是**窗口**宽度，不是 384
  /// ⇒ isNarrow = (1280 < 760) = **false**
  /// ```
  /// ⇒ ★★ 所以侧栏里走的**不是**窄屏 Column，而是**宽屏 Row**：
  /// ```text
  /// _Cover(width: 212) + SizedBox(24) + Expanded(_Info)
  /// 侧栏 340px − 左右 contentPadding(24×2) = 可用 292px
  /// 292 − 212 − 24 = **56px** 留给 _Info
  /// ```
  /// **56px 宽的信息栏** —— 标题、徽章、三个按钮全挤在里面 ⇒
  /// ★ 这就是 Owner 说的「**很丑**」的真正形态
  ///（任务描述里假设的"侧栏里恒为窄屏 Column"**不成立**，实测已证伪）。
  ///
  /// # 修法：用 `LayoutBuilder` 拿**真实约束**
  ///
  /// ```text
  /// LayoutBuilder.constraints.maxWidth = 父级真正给本区的宽度
  /// ```
  /// 这才是"我有多少地方可画"的权威答案，与窗口多大无关。
  ///
  /// # 分档（阈值按**可用宽度**，不是窗口宽度）
  ///
  /// ```text
  /// >= 620    宽档：封面 212 + 信息并排          ← ★ 与改动前**逐字相同**
  /// 420..620  中档：封面 138 + 信息并排（封面缩小，把宽度让给信息）
  /// 300..420  ★ 窄档：封面 96 + 信息并排（第二轮新增，见下）
  /// < 300     紧凑档：封面 112 在上、信息在下（真手机竖屏）
  /// ```
  ///
  /// ★ **宽视口行为不变**的证明：
  /// ```text
  /// 窗口 1280 ⇒ 可用 1280−48 = 1232 ≥ 620 ⇒ 宽档（封面 212 + 并排）
  /// 窗口  760 ⇒ 可用  712      ≥ 620 ⇒ 宽档（★ 原阈值边界，行为一致）
  /// ```
  /// ⇒ 冻结契约「>=760 行为不变」满足（原 `isNarrow=false` 走的正是这个分支）。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26 第二轮：窄档是**新增**的（Owner 报"封面右边空白太多"）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # Owner 原话
  ///
  /// > 右侧封面空白区域太多，重新设计一下……
  /// > 其他的倒没啥大问题了 主要就是优化一下右侧布局的合理性
  ///
  /// # 逐像素取证（Lead 量的 Owner 截图 1313x834）
  ///
  /// ```text
  /// 面板区域   x[904,1312]  宽 **409**
  /// 封面       x[928,1039]  宽 **112**
  /// 封面右边空  1312−1039 = **273 px**   ← ★ "空白区域太多"
  /// ```
  /// 面板可用宽 = `409 − 24×2 = 361`，而**旧阈值 420** ⇒ 走紧凑档
  /// ⇒ 封面在上、信息在下 ⇒ 信息**不会**填到封面右边 ⇒ **273px 永久空着**。
  ///
  /// # 为什么把阈值从 420 降到 300 是**对的**（不是"为了让测试过"）
  ///
  /// ```text
  /// 361px 可用宽 并排：封面 96 + 间距 16 + 信息 **249px**
  ///   ⇒ 249px 对 _Info（标题 2 行 + 徽章行 + 三个按钮）是**够用**的
  ///   ⇒ 而 273px 的空白是**白丢**的 —— 没有任何信息填进去
  /// ```
  /// ★ 那 96px 的封面会不会太小？—— 它是 2:3 海报 ⇒ 96×144。
  ///   而**信息区的价值远高于海报**（标题/进度/收藏/追更/换源都在那），
  ///   所以窄档下"牺牲海报宽度换信息宽度"是正确的取舍。
  ///
  /// # 为什么**仍然保留**紧凑档（而不是一路并排到底）
  ///
  /// ```text
  /// 真手机竖屏（如 360dp 宽）⇒ 可用 360−48 = **312px**
  ///   并排：封面 96 + 16 + 信息 200 —— 仍然能用
  /// 更窄（如分屏 280dp）⇒ 可用 232px
  ///   并排：封面 96 + 16 + 信息 **120px** ⇒ 标题被压成一条缝 ⇒ 反而更糟
  /// ```
  /// ⇒ 阈值定在 **300**：`< 300` 时"上下堆叠"确实比"挤成缝"好。
  ///   （这个数不是拍的：96+16+188 = 300，188px 是标题不换行到离谱的下限。）
  ///
  /// ★ 侧栏 409 ⇒ 可用 361 ≥ 300 ⇒ **窄档并排** ⇒ 封面右边不再有 273px 空洞 ✓
  Widget _buildHeader(
    BuildContext context,
    MediaDetail d,
    int sourceCount,
  ) {
    /// `_Info` 的实参（分档里要复用，避免重复 12 行）
    ///
    /// ★ 2026-09-27：拆成 [infoHead] / [infoRest] 两个**同参**的构造器 ——
    ///   窄档要把"标题+徽章"跟封面并排、其余通栏（见下面 `w < 620` 的长注释）。
    ///   ⚠️ 两个构造器传的是**同一组实参**（只有一个 `_Info` 定义），
    ///      所以不存在"两半用了不同数据"的可能。
    _Info info({_InfoPart part = _InfoPart.full}) => _Info(
          part: part,
          detail: d,
          // ★ task-12 ⑤：本地模式下"集数"换成**已下载集数**（Owner：除了集数的展示）
          episodeCount: widget.isLocalFile ? 0 : _episodes.length,
          localCount: widget.isLocalFile ? widget.localEpisodeCount : 0,
          sourceCount: sourceCount,
          // ★ task-12 ⑤：本地模式的"来源"是 _localOrigin（站点名 / 「本地」）；
          //   在线模式仍是 _providerName —— 逐字不变。
          providerName: widget.isLocalFile ? _localOrigin : _providerName,
          localMode: widget.isLocalFile,
          showActions: _showLocalActions,
          // ★★★ OPS-9：这一集磁盘上有没有可播文件 ⇒ 只决定那枚「换源」画不画
          hasLocalFile: _hasLocalPlayable,
          isFav: _isFav,
          following: _following,
          resume: _resume,
          resumeTitle: _resume == null ? '' : _resumeTitle(_resume!),
          resumeRemaining: _resume == null ? '' : _resumeRemaining(_resume!),
          onToggleFav: _toggleFav,
          onToggleFollow: _toggleFollow,
          onSwitchSource: _openSwitchSource,
          onDownloadCurrent: _downloadCurrent,
          onDownloadAll: _downloadAll,
        );

    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;

        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-09-27 第二轮：窄档改成「封面 + 标题并排，其余**通栏**」
         * ══════════════════════════════════════════════════════════════
         *
         * # Owner 原话（附截图）
         * ```text
         * > 还是有留白，可以好好优化一下吗？看着不协调
         * ```
         *
         * # 上一轮修好了"封面右边 273px"，为什么还是"不协调"
         *
         * 因为那是**另一处**留白。逐带实测（面板 391px，Owner 截图）：
         * ```text
         * 带          y 范围     左起   右止   占面板宽
         * 封面+标题    40..145    902   1283    97%
         * 徽章        145..190    926   1245    81%
         * 简介        195..270   1038   1252    54%   ← ★ 左边界跳到 1038
         * 按钮        275..355   1038   1219    46%   ← ★ 只占 46%
         * 续播        360..405   1038   1252    54%
         * 选集标题     415..445    927    964     9%
         * 选集网格     450..610    926   1234    79%
         * ★ 空白      610..800    ——    ——      0%   ← ★★ 195px 死区
         * ```
         * ⇒ **三个**独立问题：
         * ```text
         * A 底部 195px 死区（内容到 y=605 就结束，面板高到 800）
         * B ★ **两条左基准线**：封面/徽章/选集在 926，
         *    简介/按钮/续播在 1038（= 封面 96 + 间距 16 之后）
         *    ⇒ 这就是"不协调"的**直接来源**：下半部分整体右移了
         * C 宽度利用率低：按钮只占 46%、简介/续播 54%
         * ```
         *
         * # 机制（为什么必然长成这样）
         * ```text
         * 原实现：`Row([封面, 间距, Expanded(_Info)])`
         *   ⇒ `_Info` 的**全部**内容（标题/徽章/简介/按钮/续播）都在封面右边
         * 而「选集」在 `_buildBody` 里、是 `_buildHeader` **之外**的块
         *   ⇒ 它按面板自己的内边距排版（926）
         * ⇒ ★ 两个块**不在同一个排版上下文** ⇒ 基准线必然不一致
         * ```
         *
         * # 修法：把"跟着封面一起并排的"缩小到**标题 + 徽章**
         * ```text
         * 窄档（300..420）：
         *   ┌──────────────────────────────┐
         *   │ [封面 96]  标题 / 徽章         │  ← 并排（封面右侧**不留白**）
         *   ├──────────────────────────────┤
         *   │ 简介（通栏）                   │
         *   │ [继续观看][收藏][追更][换源]    │  ← ★ 通栏 ⇒ 基准线与选集一致
         *   │ 上次看到 …                     │
         *   │ 选集 / [第01集][第02集]…        │
         *   └──────────────────────────────┘
         * ```
         * ⇒ 一次解决 A/B/C：
         * ```text
         * A 简介/按钮变宽 ⇒ 换行变少 ⇒ 内容变矮…… 但按钮行**不再折成两行**
         *   ⇒ 净效果：内容更紧凑、且"信息"部分与选集**同宽**
         * B ★ 左基准线唯一（除封面那一行）
         * C 按钮 46% → ~95%、简介 54% → ~95%
         * ```
         *
         * ⚠️ **冻结契约**：`w >= 620`（独立详情页 / 宽视口）**一字未动** ——
         *    仍走下面那条 `Row([封面, 间距, Expanded(_Info)])`，
         *    且 `_Info` 的内部结构**没变**（见 `_Info` 的文档）。
         */
        if (w < kHeaderCompactMax) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(detail: d, width: 112),
              const SizedBox(height: Sp.x4),
              info(),
            ],
          );
        }
        /*
         * ── 窄档（kHeaderCompactMax..620）：封面 + 标题/徽章并排，其余通栏 ──
         *
         * ★ 判据来源：Owner 的侧栏是 409px 面板 ⇒ 可用 361 ⇒ 落在这一档。
         *   而 361px 下"封面 + 全部信息"并排会把信息挤到 ~230px
         *   ⇒ 按钮折行、简介折行，且与下方的选集**基准线不一致**（见上）。
         */
        if (w < 620) {
          final coverW = w >= 420 ? 138.0 : kCoverNarrow;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Cover(detail: d, width: coverW),
                  SizedBox(width: w >= 420 ? Sp.x4 : Sp.x4),
                  // ★ 只有"标题 + 徽章"跟着封面并排
                  Expanded(child: info(part: _InfoPart.head)),
                ],
              ),
              const SizedBox(height: Sp.x4),
              // ★ 其余**通栏** —— 与「选集」同一条左基准线
              info(part: _InfoPart.rest),
            ],
          );
        }

        // ── 宽档（>= 620）：**与改动前逐字相同** ──
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(detail: d, width: 212.0),
            const SizedBox(width: Sp.x6),
            Expanded(child: info()),
          ],
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, MediaDetail d) {
    /// 头部「N 个播放源」角标用的数量
    ///
    /// ⚠️ 必须与 `_hasMultiSource`（决定是否渲染线路区）用**同一个数** ——
    ///    否则会出现"角标说 2 个源，但下面没有线路区"的自相矛盾。
    ///
    /// ⚠️ 用**顶层**数量（不是展平后的总数），与原版
    ///    `DetailView.vue:592` 的 `sources.length` 一致。
    final sourceCount = _sourceNodes.length;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-27 第三轮：选集视口**吃掉剩余高度**（消掉底部死区）
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（附截图）
     * > 还是有留白，可以好好优化一下吗？看着不协调
     *
     * # 真机实测（pid 33212，新构建）
     * ```text
     * 内容到 y=618 就结束了，面板高到 y=799
     * ⇒ ★ 底部死区 **181px**
     * ```
     * 根因：`kEpsViewportH = 148` 是**定值**，而面板高 800
     * ⇒ 内容总高只有 ~618 ⇒ 剩下 181px 永远是空的。
     *
     * # 修法：`max(kEpsViewportH, 可用高 − 已用高)`
     * ```text
     * ① 仍然**不随集数增长**（Owner 那句"剧集高度固定一下"的本意就是
     *    别让 24 集撑成 8 行把页面顶下去）—— 它是"固定成**剩余空间**"，
     *    而不是"固定成 148"
     * ② ★ 已用高是**实测**的（`_topKey` 的 RenderBox），不是估算 ——
     *    估算会随主题/字号/有无续播条而漂移（本仓铁律：
     *    判据不能建立在猜的数字上）
     * ③ 下限仍是 `kEpsViewportH` ⇒ 极矮窗口下不会缩成看不见
     * ```
     */
    return LayoutBuilder(
      builder: (ctx, c) {
        /*
         * 实测"选集之上"的总高（含「选集」标题与它前面所有区块）。
         *
         * ⚠️ `_topH` 由 post-frame 回调写入 ⇒ **首帧为 null**
         *    ⇒ 首帧退回 `kEpsViewportH`（= 改动前的行为），
         *      第二帧起才按剩余空间撑开。**不会闪烁**，只是首帧矮一点。
         */
        /*
         * ⚠️ 必须减掉选集**之后**的那两段间距，否则总高会超出可用高
         *    ⇒ `ListView` 底部多出一截可滚空白（"修了死区又造出滚动条"）：
         * ```text
         * Sp.x6  = 24   选集视口与下一个区块之间
         * Sp.x16 = 64   ListView 自身的底部内边距
         * ```
         */
        _lastAvailH = c.maxHeight.isFinite ? c.maxHeight : null;
        final epsH = _epsHFor(_topH ?? 0);

        /*
         * ★ 每帧后**实测**一次「选集之上」的高度（见 `_measureTop` 的长注释）。
         *
         * ⚠️ 必须 `addPostFrameCallback` —— 本帧的布局还没算完，
         *    这时读 `RenderBox.size` 拿到的是**上一帧**的值。
         */
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _measureTop();
        });

        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ task-64：**头部固定**，只有选集区内部可滚
         * ══════════════════════════════════════════════════════════════
         *
         * # Owner 原话（逐字）
         * ```text
         * > 右侧整体固定，不能上下滚动，只有选集部分内部可以滚动
         * ```
         *
         * # 改前是什么
         * ```dart
         * return ListView(                      // ★ 整个右栏一起滚
         *   padding: EdgeInsets.only(bottom: Sp.x16),
         *   children: [
         *     KeyedSubtree(key: _topKey, child: Column(..._bodyTop)),  // 头部
         *     ..._bodyEpisodes(epsH),                                  // 选集
         *   ],
         * );
         * ```
         * ⇒ 头部（封面/标题/简介/按钮/续播条/播放源）会随页面**滚出视野**。
         *
         * # 改后：`Column`（**没有任何外层可滚体**）
         * ```text
         * 头部          ⇒ 自然高度，**不可滚** ⇒ 始终可见
         * 选集区        ⇒ 固定高度 + 自己的 `_epsCtrl` 内部滚
         * ```
         * ★ 关键收益：**外层没有 Scrollable 了** ⇒
         *   `_scrollEpisodesIntoView` 结构上**不可能**滚走整页
         *   （本仓 task-3 同族事故：`Scrollable.ensureVisible` 会向上遍历
         *     所有 Scrollable ⇒ 把整页滚走）。
         *   ⇒ 这比"靠断言禁止用那个 API"更强：**它没有可滚的东西了**。
         *
         * # ★★ 为什么选集那一段要包 `Flexible`（溢出安全网，必须）
         * ```text
         * `Column` 与 `ListView` 的**根本区别**：ListView 装不下就滚，
         * Column 装不下就 **RenderFlex overflow**（只在布局时炸，
         * `flutter analyze` **抓不到**）。
         *
         * 而 `epsH` 的推导链有一个**已知的首帧窗口**：
         *   `_topH` 由 post-frame 回调写入 ⇒ **首帧为 null**
         *   ⇒ 首帧 `_epsHFor(0)` 会算出 ≈ `availH − 88`（远大于真实剩余）
         *   ⇒ 在 ListView 里无害（滚一下就好），在 Column 里**必然溢出**。
         *
         * ⇒ 用 `Flexible`（默认 `FlexFit.loose`）：
         *   ```text
         *   剩余空间 ≥ epsH ⇒ 子级按 epsH 布局   （契约：固定高度 + 内部滚）
         *   剩余空间 < epsH ⇒ 框架**夹到**剩余空间（不溢出）
         *   ```
         *   ★ 这个上界是**框架自己算的**，不是我们估的 ——
         *     比任何"估算剩余高度"的写法都可靠（本仓铁律：
         *     判据不能建立在猜的数字上）。
         * ```
         *
         * # ★ 重新推导"可用高"（task-64 明确要求写进注释）
         * ```text
         * 改前（ListView）：可用高 = LayoutBuilder 的 maxHeight，
         *   尾距 = Sp.x6（选集与下一区块的间距）+ Sp.x16（ListView 底部内边距）
         * 改后（Column）  ：可用高的**来源没变**（仍是 maxHeight），
         *   但尾距的含义变了：`Sp.x16` 在 Column 里**不再是一段真实的内边距**
         *   （没有 ListView 了），它现在只是**保守余量**。
         *   ⇒ 于是 `epsH` 会比"真实剩余"小一点（≈ `Sp.x16 − 选集标题高`，
         *     实测约 24px）—— 这是**有意的保守**：
         *     宁可留 24px 余量，也不要为了抠掉它而引入溢出风险。
         *   ★ 与改动前的 **181px 底部死区**相比仍是数量级改善。
         * ```
         *
         * ⚠️ `episodeViewportHeight` 这个**纯函数一个字都没改** ——
         *    它被 `t61_panel_scroll_test.dart` 的 B2 组用具体数值钉住
         *    （800/390 ⇒ 322）。改它等于改一个已验收的契约。
         */
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ task-64 收尾：极矮窗口下**选集必须仍然够得着**
         * ══════════════════════════════════════════════════════════════
         *
         * # 实测（`.probe/probe_tests/t64_header_measure_test.dart`）
         * ```text
         * surface=1280×800  ⇒ 头部自然高 ≈ 366.0px
         * surface= 640×800  ⇒ 头部自然高 ≈ 397.0px   ← 窄档更高（封面变窄换行）
         * surface= 400×300  ⇒ 头部自然高 ≈ 334.0px
         * surface= 400×200  ⇒ 头部自然高 ≈ 334.0px
         * ```
         * ★ 关键：**头部自然高是内容决定的（334~397px），与窗口高度无关**。
         *
         * # 于是 400×200 时会发生两件坏事（都实测到了）
         * ```text
         * ① RenderFlex overflowed by 194 pixels   （总需求 > 可用高）
         * ② ★ 更严重：`find.text('第 1 集')` **找到 0 个** ——
         *    头部把 200px 全吃掉，**选集被整个推出可视区**
         *    ⇒ 用户在矮窗口里**完全看不到剧集**，而这正是这个页面的主要功能
         * ```
         * ★ ②才是真缺陷（overflow 只是它的症状）。
         *
         * # 为什么**不能**让头部变成可滚体
         * ```text
         * Owner 原话：「右侧**整体固定**，不能上下滚动，只有选集部分内部可以滚动」
         * ⇒ 把头部做成可滚 = 直接把需求做反（t61 有 4 条断言堵这条）
         * ```
         *
         * # ★★★ 结论：**"给头部一个高度预算"这个修法没有落地**（如实记录）
         * ```text
         * 我一度打算做「头部可用高 = maxHeight − epsH，放不下就收紧到预算、
         * 超出部分用 ClipRect 裁掉」—— ★ 但**代码里没有它**。
         *
         * 原因：查到了真根因 —— `shell.dart` 的 `minimumSize` 被某次实验
         * 改成了 200×200（原版 Tauri 是 900×600，那句 `AG-EXPERIMENT-TEMP
         * (revert)` 就是证据）⇒ 用户**根本拖不到** 400×200 这种尺寸
         * ⇒ 那两条"极矮窗口不溢出"的断言是在追一个**因为 bug 才存在**的场景。
         *
         * ⇒ 已把 `minimumSize` 还原成 **900×600** ⇒ 极矮尺寸生产上不可达
         *   ⇒ 不需要额外的预算/裁剪机制（那会为一条不可达路径增加常驻复杂度，
         *     而且它自己的预算数字也要靠实测，多一个会漂的判据）。
         * ```
         *
         * ⚠️ **如果将来有人再调低 `minimumSize`**，这里会重新变成可达路径 ——
         *    那时必须回来重新评估（`t64_panel_fixed_test.dart` 的
         *    「生产最小盒」用例会先变红，这就是它的作用）。
         *
         * ⚠️ 真正兜住"首帧窗口"的是下面那个 `Flexible`（`_topH == null` 时
         *    `epsH ≈ availH − 88` ⇒ 必然超出剩余空间）——
         *    它靠**框架自己算的上界**夹住，不需要知道头部有多高。
         */
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyedSubtree(
              key: _topKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: _bodyTop(context, d, sourceCount),
              ),
            ),
            ..._bodyEpisodes(epsH),
          ],
        );
      },
    );
  }

  /// `_buildBody` 里**选集之上**的全部内容（抽出来是为了能被测量）
  List<Widget> _bodyTop(BuildContext context, MediaDetail d, int sourceCount) {
    return [
        /*
         * ── 返回 ──
         *
         * ★ task-58：**合并页里不画这个按钮** —— 返回的语义变了：
         * ```text
         * 独立详情页  返回 ⇒ 回上一页（首页/搜索/追更）
         * 合并页      返回 ⇒ 回首页（★ 不是回详情页 —— 详情页已经不存在了）
         * ```
         * 合并页的返回由 `MediaPage` 顶层统一处理（含标题栏/手势），
         * 这里再画一个会让用户看到**两个返回入口**、而且语义不一致。
         */
        if (!widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x2, Sp.x4, Sp.x2, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.chevron_left),
                tooltip: '返回',
              ),
            ),
          ),

        /*
         * ── 头部：海报 + 元信息 ──
         *
         * ★ task-60 ②：分档判据从「窗口宽度」改成「**本区可用宽度**」
         *
         * 修之前这里写的是：
         * ```dart
         * final isNarrow = MediaQuery.of(context).size.width < 760;
         * ...
         * child: isNarrow ? Column(封面138在上) : Row(封面212 + Expanded)
         * ```
         * ⚠️ 而 T1 用 `SizedBox(width: detailW)` 装本页 —— `SizedBox`
         *    **不会**重新界定 `MediaQuery` ⇒ 侧栏里读到的仍是**窗口**宽度
         *    ⇒ `isNarrow = false` ⇒ 走 Row(封面 212 + 信息)
         *    ⇒ 340px 侧栏里信息只剩 **56px** ★ 这就是 Owner 说的「很丑」。
         *
         * ⇒ 改用 `_buildHeader`（内部 `LayoutBuilder`）—— 见它的文档。
         *
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-09-27 第三轮：补上**顶部间距**（Owner 指出）
         * ══════════════════════════════════════════════════════════════
         *
         * Owner 原话（附截图）：
         * > 封面距离顶部应该有点间距
         *
         * 逐像素实测（截图 1280×800）：
         * ```text
         * y=0..38    标题栏（黑）
         * y=39       过渡
         * y=40       ★ 封面/标题**从这里就开始** —— 与标题栏**零间距**
         * ```
         * 根因：这里只给了 `horizontal`，**没有** top ⇒ 头部紧贴上一个元素。
         * 而合并页里"上一个元素"就是标题栏 ⇒ 观感上被"切掉"了。
         *
         * ⚠️ 独立详情页（非 embedded）里上面是「返回」按钮（自己带 `Sp.x4`），
         *    所以那时**本来就有**间距 —— 本修复只影响 embedded（合并页）。
         *    ⇒ 用条件内边距，**不动**独立详情页的既有观感（冻结契约）。
         */
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppMetrics.contentPadding,
            // ★ embedded（合并页）：标题栏下要留呼吸空间
            widget.embedded ? Sp.x4 : 0,
            AppMetrics.contentPadding,
            0,
          ),
          child: _buildHeader(context, d, sourceCount),
        ),

          const SizedBox(height: Sp.x8),

          // ── 一级：播放源（单选项时隐藏）──
          //
          // ⚠️ 这里用 [DetailSourcePicker] 而不是手写的横向 ListView
          //
          // # 为什么必须换掉（两个缺口叠在一起）
          //
          // 原版 `DetailView.vue:666-673` 用的是 `SourcePicker` 组件，
          // 而那个组件的核心能力是**递归**（`SourcePicker.vue:74-80`
          // 自己渲染自己），用于「线路里还有线路」的源。
          //
          // 我们原来的实现是**单层** `ListView`，两个问题：
          // ```text
          // ① 没有嵌套概念 → 嵌套线路永远看不到（PlaySource 连 nested 字段都没有）
          // ② 标题读的是 name（后端发 title）→ 永远显示成 code（cychub / cdn）
          // ```
          // 现在换成 DetailSourcePicker：既递归渲染嵌套层，又读真标题与集数。
          // ★ task-12 ⑤：本地模式**不画「播放源」** ——
          //   本地文件不属于任何站点，"站内换线路"这件事在它身上没有意义
          //   （Owner 把"换源"归在"那些操作按钮不显示"里）。
          if (!widget.isLocalFile && _hasMultiSource) ...[
            const _BlockTitle(text: '播放源'),
            DetailSourcePicker(
              sources: _sourceNodes,
              active: _activeSource,
              onPick: _pickSource,
            ),
            const SizedBox(height: Sp.x6),
          ],
    ];
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ★★★ task-17 ③：本地播放页的**单集删除 + 批量删除**
  // ══════════════════════════════════════════════════════════════════════
  //
  // Owner 原话（逐字）：
  // > 本地播放页面,进去之后 可以选择批量删除,也可以单集删除,这里操作要优化
  //
  // # 为什么删除逻辑必须**先查有没有现成的**（lead 硬约束）
  // ```text
  // 本仓已经有两条删除路径，直接复用它们的**语义**，不新写第二套：
  //   · DownloadQueue.remove(id)        —— 单任务：先停 → 删盘上产物 → 从队列移除
  //   · DownloadQueue.deleteTaskFiles(t) —— 按 fileName 删 .mp4/.ts/.flv/.part 等候选
  //   · DownloadQueue.removeWork(title)  —— 整剧：删整个目录
  // ```
  //
  // # ★ 但**不能**直接调它们（这是有意的，不是偷懒）
  // ```text
  // 本页手里是 [LocalEpisodeRef]（一个**绝对路径** + 文件名），而那两个 API 的入参是
  // `DownloadTask` / `title` —— 而本地播放的**前提**恰恰是"旁文件不存在"，
  // 且用户可能是在**重启之后**从「已缓存」进来的 ⇒ 队列里**根本没有**这条任务
  // ⇒ 拿不到 DownloadTask ⇒ 那两条 API 在这里是**不可用**的。
  // ```
  // ⇒ 所以这里按 `deleteTaskFiles` 的**同一条路径规则**（同名 + 各种后缀/半截）删，
  //   并在删完后让外层**重新扫盘**（真刷新）。
  //
  // ⚠️ 队列里若**确实**还有这条任务（正在下载），先按 id 调 remove() 走正规路径 ——
  //    这样"正在下的那一集"不会留下半截 .part 或让队列状态与磁盘不一致。

  /// 选择模式（批量删除）—— Owner：「可以选择批量删除」
  bool _localSelectMode = false;

  /// 选择模式里被勾中的集（用**绝对路径**当身份，与 [_localRowKeys] 同一套键）
  final Set<String> _localChecked = <String>{};

  /// 单集删除（带二次确认）
  ///
  /// ⚠️ 确认正文写清**代价**（哪个文件、多大）—— 与 cache_page._confirmDelete 同一条纪律：
  ///    真删、不可逆，用户点之前必须看到自己要失去什么。
  Future<void> _confirmDeleteLocalEpisode(LocalEpisodeRef ref) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一集？'),
        content: Text(
          '${ref.episodeTitle}\n'
          '文件会从磁盘上真正删除，此操作不可恢复。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _deleteLocalPaths(<LocalEpisodeRef>[ref]);
  }

  /// 批量删除（带二次确认，正文写清**几集 / 多少 MB**）
  Future<void> _confirmDeleteLocalSelected() async {
    final picked = widget.localEpisodes
        .where((e) => _localChecked.contains(e.absolutePath))
        .toList();
    if (picked.isEmpty) return;

    /*
     * ★ 真读数：字节数来自**扫盘时量好的**读数（CachedEpisode.bytes），
     *   不是在弹窗前再去 stat 一遍。
     *
     * # 为什么不在弹窗前 stat（探针实测的教训）
     * ```text
     * 探针点"删除"后弹窗**永远不出现** —— 因为 `File.exists()` 是**真实异步 IO**，
     * 而 flutter_test 的假时钟不驱动真实 IO ⇒ 那个 await 永不完成 ⇒
     * `showAppDialog` 根本走不到。
     * ⇒ 真机上虽然会完成，但那段 IO 是**白等**的（数字扫盘时就已经有了）。
     * ```
     */
    var bytes = 0;
    for (final e in picked) {
      bytes += e.bytes;
    }

    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除选中的集？'),
        content: Text(
          '将删除 ${picked.length} 集 / 共 ${humanBytes(bytes)}。\n'
          '文件会从磁盘上真正删除，此操作不可恢复。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _deleteLocalPaths(picked);
  }

  /// 真删（单集与批量共用这一条路径 —— 两处各写一遍迟早不一致）
  ///
  /// ★ 删盘上文件时**只认文件名**，绝对路径由 `CachedDelete` 现拼 —— 那是
  ///   唯一带**路径穿越防护**的实现（lead 明令）。
  ///   改前这里直接拿 `ref.absolutePath` 去删，而那个绝对路径来自磁盘扫描
  ///   与本地命名空间，理论上可被构造出目录外的目标。
  Future<void> _deleteLocalPaths(List<LocalEpisodeRef> refs) async {
    final dir = _localWorkDir();
    if (dir == null) {
      _sayLocal('找不到这部作品的文件夹，已取消删除');
      return;
    }
    var deleted = 0;
    for (final ref in refs) {
      final name = ref.fileName;
      // ① 队列里还有这条任务 ⇒ 走正规删除路径（含"先停再删"）
      final task =
          DownloadQueue.tasks.value.where((t) => t.fileName == name).toList();
      for (final t in task) {
        await DownloadQueue.remove(t.id);
      }
      // ② 盘上产物（无论队列里有没有，都要确保文件真的没了）
      if (await CachedDelete.deleteEpisodeFile(dir, name)) deleted++;
    }
    if (!mounted) return;
    setState(() {
      _localChecked.clear();
      _localSelectMode = false;
    });
    /*
     * ③ 真刷新 —— 回调给外层（media_page）重新扫盘。
     * ⚠️ 不在这里自己扫：扫盘是外层的职责（本页**不自己扫盘**，见 localEpisodes 的注释）。
     */
    widget.onLocalEpisodesChanged?.call();
    AppLog.write('LOCAL', '本地删除：${refs.length} 集，实际删掉 $deleted 个文件');
    _sayLocal(deleted > 0
        ? '已删除 $deleted 个文件'
        : '没有删除任何文件（文件可能已经不在了）');
  }

  /// 本地会话所在的**作品目录**（拿不到 ⇒ 不许删）
  ///
  /// ★ 从任一集的文件名往上退一层 —— 这样就不必把整个 CachedWork 传进来
  ///   （本页拿的是 LocalEpisodeRef，只有绝对路径）。
  String? _localWorkDir() {
    if (widget.localEpisodes.isEmpty) return null;
    final p = Directory(widget.localEpisodes.first.absolutePath).parent.path;
    return p.isEmpty ? null : p;
  }

  /// 一句话反馈（与 cache_page._say 同款）
  void _sayLocal(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  /// ★★★ task-12 ⑤ + task-17 ③：本地模式的「已下载」那一段
  ///
  /// # 为什么它**不是**在线页那个选集网格
  /// ```text
  /// 在线选集：一个按钮 = 一集（点了切流）—— 数据源是"源声明的剧集列表"
  /// 本地这段：一行 = 一个**文件**（点了切文件）—— 数据源是"磁盘上真正下好的文件"
  /// ```
  /// ⇒ 两件事：**形态不同**（一行 vs 网格）、**语义不同**（我下过的 vs 源有多少集）。
  ///   所以标题写「已下载」，与在线页的「选集」**明显区分**（lead 明确要求）。
  ///
  /// # ★★★ task-17 ③：这一段现在多了**删除**能力
  /// ```text
  /// 普通态：每行右侧一枚垃圾桶（悬停变红）+ 标题行右侧「管理」入口
  /// 选择态：每行左侧一个勾选框 + 标题行变成「已选 N 集 · [全选] [删除] [取消]」
  /// ```
  /// ⚠️ 删除入口**默认隐藏、悬停才显形**（与 cache_page 的 _HoverDeleteButton 同款观感）：
  ///    否则每一行右边都挂一个垃圾桶，列表会显得很吵（Owner 说"这里操作要优化"）。
  ///
  /// ⚠️ 高度用 [kLocalEpsViewportH] + **内部**滚动：与在线选集视口同一条纪律
  ///    （外层 Column 里没有可滚体，见 t61 的断言）。
  List<Widget> _localEpisodesSection() {
    final eps = widget.localEpisodes;
    return [
      // ── 标题行：普通态是「已下载」，选择态变成一整条操作栏 ──
      if (_localSelectMode && eps.isNotEmpty)
        _localSelectBar(eps)
      else
        Row(
          children: [
            const _BlockTitle(text: '已下载'),
            const Spacer(),
            if (eps.isNotEmpty)
              TextButton(
                onPressed: () => setState(() {
                  _localSelectMode = true;
                  _localChecked.clear();
                }),
                child: const Text('管理'),
              ),
          ],
        ),
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppMetrics.contentPadding,
        ),
        child: eps.isEmpty
            ? _LocalEmptyHint(file: widget.localFile ?? '')
            : SizedBox(
                key: _epsViewportKey,
                height: kLocalEpsViewportH,
                child: Scrollbar(
                  controller: _epsCtrl,
                  child: SingleChildScrollView(
                    clipBehavior: Clip.antiAlias,
                    controller: _epsCtrl,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in eps)
                          _LocalEpisodeRow(
                            key: _localRowKeyFor(e.absolutePath),
                            ref: e,
                            active: _activeLocalPath == e.absolutePath,
                            /*
                             * ★ task-17 ③：选择态下点击 = **勾选/取消**，不是播放。
                             *   这是选择模式的通行语义（点行即选），
                             *   否则用户得精准点到那个小方块上。
                             */
                            onTap: _localSelectMode
                                ? () => setState(() {
                                      if (!_localChecked
                                          .remove(e.absolutePath)) {
                                        _localChecked.add(e.absolutePath);
                                      }
                                    })
                                : (widget.onPlayLocalEpisode == null
                                    ? null
                                    : () => widget.onPlayLocalEpisode!(e)),
                            checked: _localSelectMode
                                ? _localChecked.contains(e.absolutePath)
                                : null,
                            onDelete: _localSelectMode
                                ? null
                                : () => unawaited(
                                      _confirmDeleteLocalEpisode(e),
                                    ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
      const SizedBox(height: Sp.x6),
    ];
  }

  /// 选择态的操作栏（「已选 N 集 · [全选] [删除] [取消]」）
  Widget _localSelectBar(List<LocalEpisodeRef> eps) {
    final n = _localChecked.length;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppMetrics.contentPadding,
      ),
      child: Row(
        children: [
          Text(
            '已选 $n 集',
            style: TextStyle(
              fontSize: FontSizes.base,
              fontWeight: FontWeights.semibold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              // ★ 全选/全不选：已经全选了就变成"全不选"（一个按钮两个方向）
              if (_localChecked.length == eps.length) {
                _localChecked.clear();
              } else {
                _localChecked
                  ..clear()
                  ..addAll(eps.map((e) => e.absolutePath));
              }
            }),
            child: Text(_localChecked.length == eps.length ? '全不选' : '全选'),
          ),
          TextButton(
            // ★ 一集都没勾 ⇒ 禁用（不给"点了没反应"的按钮）
            onPressed: n == 0
                ? null
                : () => unawaited(_confirmDeleteLocalSelected()),
            child: const Text('删除'),
          ),
          TextButton(
            onPressed: () => setState(() {
              _localSelectMode = false;
              _localChecked.clear();
            }),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// ★ task-12 ⑤：本地模式下「正在播的那一集」（判据 = **文件名**）
  ///
  /// 在线模式用 widget.currentEpisodeId（播放器报的剧集 id），而本地会话的
  /// episodeId 恰好就是**文件名**（见 cache_page.buildLocalPlayRequest 的调用点：
  /// episodeId: req.episode.fileName）⇒ 这里用文件名比对即可。
  ///
  /// ⚠️ 不用绝对路径比对是因为播放器报的是 id 而不是路径（MediaSession.onEpisodeChanged 的契约）。
  String? get _activeLocalPath {
    final id = widget.currentEpisodeId;
    if (id == null) return null;
    for (final e in widget.localEpisodes) {
      if (e.fileName == id) return e.absolutePath;
    }
    return null;
  }

  /// `_buildBody` 里**选集那一段**（含标题）—— 高度由调用方按剩余空间给
  List<Widget> _bodyEpisodes(double epsH) {
    /*
     * ★★★ task-12 ⑤（Owner 裁决 (B)）：本地模式**走另一条**。
     *
     * ```text
     * 在线：选集   = "这个源一共更新到第几集"（含没下载、没看过的）
     * 本地：已下载 = "我在这台机器上下好了哪几集"  ← 用户从这个页面进来的目的就是它
     * ```
     * ⚠️ 用"**整段换掉**"而不是在原来的 if 上加条件：
     *    本地模式里 _episodes 恒为空（不问核心要剧集）⇒ 原来那两条分支
     *    （选集网格 / 什么都没有）**都不适用**，加条件会得到一片空白。
     * ⚠️ 标题写「已下载」而不是「选集」—— lead 明确要求与在线页**明显区分**。
     */
    if (widget.isLocalFile) return _localEpisodesSection();
    return [
          // ── 二级：剧集 ──
          if (_episodes.isNotEmpty || _epsLoading) ...[
            const _BlockTitle(text: '选集'),
            if (_epsLoading)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AppMetrics.contentPadding,
                ),
                child: _EpsSkeleton(),
              )
            else
              /*
               * ★★★ task-64：包一层 `Flexible` —— **溢出安全网**（必须）
               *
               * # 为什么 ListView 不需要它、Column 必须要有
               * ```text
               * ListView 装不下 ⇒ 滚（无害）
               * Column   装不下 ⇒ **RenderFlex overflow**（只在布局时炸，
               *                   `flutter analyze` 抓不到）
               * ```
               *
               * # 什么时候会装不下（这不是"理论上"）
               * ```text
               * `epsH = max(kEpsViewportH, availH − _topH − 尾距)`
               * ★ 而 `_topH` 由 post-frame 回调写入 ⇒ **首帧为 null**
               *   ⇒ 首帧按 `_topH = 0` 算 ⇒ epsH ≈ availH − 88
               *   ⇒ 头部再一占 ⇒ 首帧**必然**超出可用高。
               * 在 ListView 里这只是"首帧矮一点"（滚一下就好），
               * 在 Column 里就是一条溢出条纹 + 控制台异常。
               * ```
               *
               * # 为什么 `Flexible` 就够（而且比"估算剩余"更可靠）
               * ```text
               * `Flexible`（默认 `FlexFit.loose`）给子级一个**上界**：
               *   剩余 ≥ epsH ⇒ 按 epsH 布局   （契约：固定高度 + 内部滚）✓
               *   剩余 < epsH ⇒ 框架夹到剩余   （不溢出）✓
               * ★ 这个上界是**框架自己算的**，不是我们估的数字 ——
               *   任何"自己算剩余"的写法都会在主题/字号/有无续播条变化时漂移
               *   （本仓铁律：判据不能建立在猜的数字上）。
               * ```
               *
               * ⚠️ `FlexFit.loose` 而不是 `tight`：
               *     `tight` 会**强制**子级吃掉全部剩余（把 epsH 撑到剩余），
               *     那就破坏了"固定高度"这个已验收契约
               *     （`t61_panel_scroll_test.dart` B 组：`height: epsH`）。
               */
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppMetrics.contentPadding,
                  ),
                /*
                 * ══════════════════════════════════════════════════════════
                 * ★★★ 2026-09-26 第二轮：选集改成**固定高度的独立可滚区**
                 * ══════════════════════════════════════════════════════════
                 *
                 * # Owner 原话
                 *
                 * > 下面剧集高度固定一下
                 *
                 * # 改前的问题
                 *
                 * `Wrap` 里 27 个 `_EpisodeButton` 会**无限往下长** ——
                 * 24 集就是 8 行 ≈ **300px**，集数越多页面越高
                 * ⇒ 下面的「播放源」等区块被一路推下去，用户要滚很久。
                 *
                 * # ⚠️ 2026-09-27 第三轮：高度从**定值**改成**剩余空间**
                 *
                 * 定值 148 在 800px 高的面板里会留下 **181px 底部死区**
                 * （真机实测：内容到 y=618 就结束）—— Owner 第二次投诉的
                 * 「还是有留白」就是它。
                 * ⇒ 现在由 `_buildBody` 算 `epsH = max(148, 可用高 − 已用高)`
                 *   ★ 仍然**不随集数增长**（Owner 的本意），
                 *     但会**吃掉面板的剩余高度** ⇒ 底部不再空着。
                 *
                 * # ⚠️ 这里**不能**用 `Scrollable.ensureVisible`
                 *
                 * 它会向上遍历**所有** `Scrollable` ⇒ 连外层 `ListView` 一起滚
                 * （本仓 task-3 同族事故）⇒ 这里只动 `_epsCtrl`。
                 * 滚动逻辑见 `_scrollEpisodesIntoView`。
                 */
                child: SizedBox(
                  key: _epsViewportKey,
                  height: epsH,
                  child: Scrollbar(
                    controller: _epsCtrl,
                    child: SingleChildScrollView(
                      clipBehavior: Clip.antiAlias,
                      controller: _epsCtrl,
                      child: Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          for (final ep in _episodes)
                            KeyedSubtree(
                              /*
                               * ★ 每一集要有**稳定的 key** ——
                               *   `_scrollEpisodesIntoView` 靠它拿到按钮的
                               *   RenderBox 来算该滚多少。
                               */
                              key: _epKeyFor(ep.id),
                              child: _EpisodeButton(
                                title: ep.title,
                                /*
                                 * ★ 两个状态**语义不同，都要有**（Owner 要求）：
                                 * ```text
                                 * active  当前**选中**的那一集（默认上次观看的，否则第一集）
                                 * played  曾经**看过**的那一集（区分"看过但没选中"）
                                 * ```
                                 * ⚠️ 不能只留 active：用户想看到"哪几集看过"这个信息。
                                 *    也不能只留 played：没观看记录时整片灰着，像没选中。
                                 */
                                active: _activeEpisodeId == ep.id,
                                played: _resume?.episodeId == ep.id,
                                onTap: () => _play(ep),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ),
            const SizedBox(height: Sp.x6),
          ] else ...[
            /*
             * ══════════════════════════════════════════════════════════════
             * ★★★ 2026-09-27：无剧集分支的「播放」按钮**也删掉了**
             * ══════════════════════════════════════════════════════════════
             *
             * 与 `_Info` 里那个按钮**同一个理由**（Owner：「已经正在播放了」），
             * 但这里更严重 —— 它不只是空操作，还可能**打断正在播的流**：
             *
             * ```text
             * `_play()` 不带 ep ⇒ req.episodeId = null
             *
             * 电影（无剧集）：cur.episodeId 也是 null ⇒ 同会话 ⇒ **空操作**
             * 剧集 + 有续播记录：req.episodeId=null ≠ cur='51463'
             *                  ⇒ ★ **判为"换会话"** ⇒ 重新解析流
             *                  ⇒ 黑屏 + 从头开始（丢进度）
             * ```
             * ⚠️ 也就是说：**点它要么没用，要么更糟** —— 而用户此刻
             *    明明正在看。
             *
             * # 原版为什么有这个按钮
             * ```text
             * 原版 `DetailView.vue:709` 的无剧集分支里只有它：
             * <button class="btn btn--primary" @click="play()">播放</button>
             * ★ 因为原版是**独立详情页** —— 上面没有播放器，
             *   这是**唯一**的起播入口，必须有。
             * 而 task-58 把详情页并进了播放页（左视频 + 右信息）
             *   ⇒ 起播由**播放器自己**负责（真机日志：
             *     `[PLAYER] ★ 检测到上次进度 77s，将续播`）
             *   ⇒ 这个入口失去意义。
             * ```
             *
             * # 删掉之后，用户还能怎么起播 / 恢复
             * ```text
             * ① 播放器自己的控制条（播放/暂停、进度条、上一集/下一集）
             * ② ★ 播放器错误浮层里的「重试」（`onRetry: _load`）——
             *    那才是"流真的没起来"时的正确入口，
             *    而它**不会**丢进度（`_load` 里保位置，见 L2052-2061）
             * ③ 「换源」按钮（在 `_Info` 的操作行里，无论有没有剧集都在）
             * ```
             */
          ],
    ];
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════════════════

/// 从 `meta` 里兜底取几个能当徽章用的值
///
/// # 为什么需要（而不是纯粹照抄原版）
///
/// 原版只渲染 `detail.badges`。但**不是所有源都填 badges** ——
/// 声明式 provider（`providers/declarative.rs:598`）的 `badges` 恒为
/// `vec![]`，它把信息全放进了 `meta`：
/// ```rust
/// pub meta: serde_json::Map<String, serde_json::Value>,
/// // 「年份/地区/评分/演员等，由 Provider 自行填充」(model.rs:215)
/// ```
/// 那种源在原版上头部就是**光秃秃的**（一个角标都没有）。
///
/// ⚠️ 只在 `badges` **为空**时才走这条兜底（见 `_Info.build` 的 if），
///    有后端 badges 时**一个字都不加** —— 保证与原版一致。
///
/// ⚠️ 严格限制在三个**后端 meta 里确实会有**的键
///   （`providers/cycani.rs:845-861` 写的是 `year` / `area` / `score`），
///    且必须在 JSON 里非空。**不做**"什么键都拿来显示"的通用枚举 ——
///    那会把 `tags` 数组、内部 id 之类的脏数据糊到用户脸上。
List<String> _metaFallbackBadges(Map<String, dynamic> meta) {
  String? pick(String key) {
    final v = meta[key];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  return [
    if (pick('year') != null) pick('year')!,
    if (pick('area') != null) pick('area')!,
    if (pick('score') != null) '${pick('score')} 分',
  ];
}

class _Cover extends StatelessWidget {
  const _Cover({required this.detail, required this.width});

  /// 这个封面是**本地文件**还是**网络 URL**
  ///
  /// ⚠️ **不能**只看 `Uri.tryParse(...).hasScheme`（CR-11）：
  ///   Windows 盘符路径 `C:\Users\…\_sourin-cover.jpg`
  ///   会被 URI 解析器读成「scheme = `C`」⇒ `hasScheme == true` ⇒ 落进
  ///   `Image.network` 分支；而主力平台 Windows 上
  ///   `Image.network('C:\…')` 必然加载失败 ⇒ 本地封面永远退化成
  ///   首字母占位符（断网时连磁盘上那张图都看不到）。
  ///
  /// ★ 正确判据（**先认磁盘路径，再谈 URI**）：
  ///   ① `http://` / `https://` 开头 ⇒ 网络；
  ///   ② 盘符 `C:\…` / `C:/…` ⇒ 本地；
  ///   ③ UNC `\\server\share\…`（两个反斜杠开头）⇒ 本地；
  ///   ④ POSIX 绝对路径 `/…` ⇒ 本地；
  ///   ⑤ 其余才交给 `Uri.tryParse`：有 scheme（`file://`、`data:` 等）⇒ 非本地；
  ///      无 scheme（`cover.jpg` 这类相对名）⇒ 本地。
  static bool _isLocalCover(String? cover) {
    if (cover == null || cover.isEmpty) return false;
    if (cover.startsWith('http://') || cover.startsWith('https://')) return false;
    // ★ CR-11：盘符（正则只认前缀，`C:\\` 与 `C:/` 两种写法都算）
    if (_driveLetter.hasMatch(cover)) return true;
    // UNC：两个反斜杠开头
    if (cover.startsWith('\\\\')) return true;
    // POSIX 绝对路径
    if (cover.startsWith('/')) return true;
    return Uri.tryParse(cover)?.hasScheme != true;
  }

  /// 盘符前缀，如 `C:\\` / `d:/`（只判前缀，不判整条路径）
  static final RegExp _driveLetter = RegExp(r'^[a-zA-Z]:[\\/]');

  final MediaDetail detail;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: AppMetrics.posterAspect,
        child: ClipRRect(
          borderRadius: Radii.rLg,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 占位底色 —— 前景色 5%（task-37，见
              // `AppColors.posterPlaceholderAlpha` 的说明）
              Container(
                color: colors.onSurface.withValues(
                  alpha: AppColors.posterPlaceholderAlpha,
                ),
              ),
              /*
               * ★ Owner ３：本地页的封面是**磁盘上那张图**（断网也能看见）
               * ```dart
               * Image.network(‘C:\...\_sourin-cover.jpg’)  → 网络协议，离线拿不到。
               * ```
               * ⇒ 本地路径走 `Image.file`。判据是「能被解析成本地路径」，
               *   而不是 provider == local（那只是一个字符串常量）。
               */
              if (_isLocalCover(detail.cover))
                Image.file(
                  File(detail.cover!),
                  fit: BoxFit.cover,
                  cacheWidth: coverDecodeWidth(context, width),
                  errorBuilder: (_, __, ___) => Center(
                    child: Text(
                      detail.title.isEmpty ? '?' : detail.title.characters.first,
                      style: TextStyle(
                        fontSize: FontSizes.display * 0.6,
                        color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                )
              else if (detail.cover != null && detail.cover!.isNotEmpty)
                coverImage(
                  context,
                  url: detail.cover!,
                  // 本组件自己就带 `width` 字段（三个调用点分别传 112 / coverW / 212）
                  layoutWidth: width,
                  fit: BoxFit.cover,
                  // ★ 封面 URL 非空但加载失败时也要画首字 —— 语义与 PosterCard
                  //   （task-63：!_loaded || _failed 都画首字）一致。
                  //   改之前这里返回 SizedBox.shrink() ⇒ 148×222 的空灰框里
                  //   什么都不画（真机像素扫描 inkpx=0），与「压根没有封面」
                  //   那条分支表现不同，同一件事两种 UI。
                  errorBuilder: (_, __, ___) => Center(
                    child: Text(
                      detail.title.isEmpty ? '?' : detail.title.characters.first,
                      style: TextStyle(
                        fontSize: FontSizes.display * 0.6,
                        color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                )
              else
                Center(
                  child: Text(
                    detail.title.isEmpty ? '?' : detail.title.characters.first,
                    style: TextStyle(
                      fontSize: FontSizes.display * 0.6,
                      color: colors.onSurfaceVariant.withValues(alpha: 0.5),
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

/// `_Info` 要渲染哪一部分（2026-09-27 第二轮）
///
/// 窄档要把「标题 + 徽章」跟封面**并排**、其余**通栏**
/// ⇒ 同一个组件按 part 只渲染一半（理由见 `_Info.build` 的长注释）。
enum _InfoPart {
  /// 全部（宽档走这条 —— 与拆分前逐字等价）
  full,

  /// 标题 + 徽章
  head,

  /// 简介 + 操作 + 续播
  rest,
}

class _Info extends StatelessWidget {
  const _Info({
    this.part = _InfoPart.full,
    required this.detail,
    required this.episodeCount,
    this.localCount = 0,
    this.localMode = false,
    this.showActions = true,
    this.hasLocalFile = false,
    required this.sourceCount,
    required this.providerName,
    required this.isFav,
    required this.following,
    required this.resume,
    required this.resumeTitle,
    required this.resumeRemaining,
    required this.onToggleFav,
    required this.onToggleFollow,
    required this.onSwitchSource,
    required this.onDownloadCurrent,
    required this.onDownloadAll,
  });

  final MediaDetail detail;

  /// 只渲染哪一部分（见 [_InfoPart]）
  final _InfoPart part;

  final int episodeCount;

  /// ★ task-12 ⑤：本地模式下的**已下载集数**（0 = 不画那一枚角标）
  ///
  /// ⚠️ 与 [episodeCount] 是**两件不同的事**（见 [DetailPage.localEpisodeCount]）：
  /// 在线「N 集」= 源更新到第几集；本地「已下载 N 集」= 你真正下好了几集。
  final int localCount;

  /// ★ task-12 ⑤：是否本地文件模式
  ///
  /// 只影响两件事：① 画不画那枚「已下载 N 集」角标；② 操作行（收藏/追更/换源/下载）画不画。
  final bool localMode;

  /// ★ Owner ３：操作行画不画（无网时不显示那几枚按钮）
  ///
  /// ★ 在线页恒为 true（那几枚按钮本来就要打网络，——“能不能用”
  ///   在那里由点了发不出来说）；只有本地页才会变 false。
  final bool showActions;

  /// ★★★ OPS-9：**这一集在磁盘上已经有可播文件** ⇒ 不画「换源」
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// > 这个好像是概率性的,**缓存到本地就不要显示换源按钮了**
  /// ```
  /// 换源要干的事是「换一条线路，去**网上**把这一集拉下来播」。
  /// 而这一集磁盘上已经有了（[DetailPage.localEpisodes] 里就躺着它）⇒
  /// 换源**无处可落**：点了也只是把播放源换成一个同样要联网的地址。
  ///
  /// ⚠️ 与 [showActions] 是**两件不同的事**，别合并：
  /// ```text
  /// showActions   = 整条操作行画不画（离线时整行不画）
  /// hasLocalFile  = 只把那**一枚**「换源」摘掉（收藏/追更/下载照旧）
  /// ```
  /// ⇒ 所以**不能**改 [showActions] 来达到这个效果：那会把另外三枚一起藏掉。
  ///
  /// ★ 判据本身**复用仓库既有**的「这一集本地文件在不在」口径
  /// （[DetailPage.currentEpisodeId] + [DetailPage.localEpisodes] 的
  ///  `e.fileName == currentEpisodeId` —— 与 `_DetailPageState._activeLocalPath`
  ///  逐字同源），**不**在 UI 层自己拼磁盘路径。
  final bool hasLocalFile;

  /// 线路总数（顶层 + 嵌套，展平后）—— 用于「N 个播放源」角标
  final int sourceCount;

  /// 当前**站点**的显示名（task-32）；null = 还没取到 → 不渲染该 chip
  ///
  /// 见 `_DetailPageState._providerName` 的说明：
  /// 原版 `SourcePicker.vue:33` 的注释声称"详情页标题区已展示过站名"，
  /// 而实际没有 —— 这里就是补上那一处。
  final String? providerName;

  final bool isFav;
  final bool following;

  /// 上次观看进度 —— ★ 只用于**续播提示**（那颗「上次看到 …」的信息 chip）
  ///
  /// ⚠️ 2026-09-27：它**不再**驱动「继续观看/播放」按钮（那个按钮已删，
  ///    理由见 `_rest` 里操作行的长注释）。保留它是因为"上次看到第几集、
  ///    还剩几分钟"这条**信息**本身对用户有用，而它不是动作。
  final Progress? resume;

  /// 续播 chip 的两半（见 `_DetailPageState._resumeTitle` 的说明）
  ///
  /// ⚠️ 拆成两个字段而**不是**一个整串：标题那半要被省略号压缩，
  ///   时间那半必须原样显示 —— 一个字符串做不到这件事。
  final String resumeTitle;
  final String resumeRemaining;

  final VoidCallback onToggleFav;
  final VoidCallback onToggleFollow;

  /// 打开「换源」弹层
  ///
  /// ★ 按钮必须放在这一行（对齐原版 `DetailView.vue:646-652`）
  ///
  /// 原版把它与「播放 / 收藏 / 追更」并排放在头部操作行，**不随有无剧集变化**。
  /// 我们原先放在选集区下方 / 无剧集分支里 —— 两处都不对，
  /// 而且有剧集时要滚到很下面才看得到。详见下方调用点的注释。
  final VoidCallback onSwitchSource;

  /// ★★★ 2026-10-08（Owner 第 4 条）：下载当前这一集 / 下载全部集
  ///
  /// # 为什么是两个独立回调（而不是一个带参数的）
  /// ```text
  /// 两个动作的**前置条件不同**：
  ///   · 单集：要有「当前集」（播放器在播的那一集 / 高亮的 / 第一集）
  ///   · 全部：要有剧集列表
  /// 无剧集（电影）时第二个是 null ⇒ 按钮里那个菜单项直接不画。
  /// ```
  final VoidCallback onDownloadCurrent;
  final VoidCallback? onDownloadAll;

  @override
  Widget build(BuildContext context) {
    /*
     * ★★★ 2026-09-27 第二轮：本组件可按 [part] 只渲染**一半**
     *
     * ```text
     * full  ⇒ Column([head, rest])  ← ★ 与改动前**逐字等价**（宽档走这条）
     * head  ⇒ 标题 + 徽章            （窄档：跟着封面**并排**）
     * rest  ⇒ 简介 + 操作 + 续播      （窄档：**通栏**，与选集同基准线）
     * ```
     *
     * # 为什么这么拆（Owner 原话 + 逐带实测）
     *
     * > 还是有留白，可以好好优化一下吗？看着不协调
     *
     * ```text
     * 带         左起    占面板宽
     * 封面/徽章   926      81~97%
     * 简介       1038      54%     ← ★ 左边界跳到 1038
     * 按钮       1038      46%     ← ★ 只占 46%
     * 续播       1038      54%
     * 选集       926      79%     ← 又回到 926
     * ★ 底部       ——      0%      ← 195px 死区
     * ```
     * ⇒ **两条左基准线**就是"不协调"的直接来源：
     *   头部全部内容在封面右边（1038），而选集在它外面（926）。
     *
     * # 为什么用一个 `part` 枚举，而不是两个独立的组件
     *
     * ```text
     * ① 数据来源唯一 ⇒ 不可能出现"两半用了不同数据"
     * ② full 分支**天然**保证宽档行为不变（同一组 child、同一顺序）
     * ③ 三个分支共用同一个 `_head`/`_rest` 实现 ⇒ 改一处三处同步
     * ```
     */
    switch (part) {
      case _InfoPart.full:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_head(context), _rest(context)],
        );
      case _InfoPart.head:
        return _head(context);
      case _InfoPart.rest:
        return _rest(context);
    }
  }

  Widget _head(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * 徽章 —— 与原版 `DetailView.vue:587-593` 逐条对应：
     * ```vue
     * <span v-for="b in detail.badges" class="chip chip--brand">{{ b }}</span>
     * <span v-if="episodes.length" class="chip">{{ episodes.length }} 集</span>
     * <span v-if="hasMultiSource" class="chip">{{ sources.length }} 个播放源</span>
     * ```
     *
     * ★ 原版**直接渲染后端的 `badges`**，不在前端重拼 —— 那是产品决定的
     *   文案与顺序（cycani 插件拼的「连载中 / 更新至 12 集 / 9.2 分」，
     *   见 `plugins/cycani.js:499-518`）。
     *
     * ⚠️ 这里**删掉了原来自己拼的「年份 / 地区 / 类型」徽章**：
     *    `MediaDetail.year` / `.area` 在 Rust 的 `MediaDetail`
     *   （`model.rs:204-224`）里**根本不存在** —— 那些信息在后端的
     *    `meta` 里，由插件自行填充。自己拼等于发明一套与原版不同的文案，
     *    而且永远是空的。
     *
     * ★ 保留 `meta` 的兜底：万一某个源只填 `meta` 不填 `badges`
     *   （declarative provider 的 `badges` 恒为空，见
     *   `providers/declarative.rs:598`），就从 meta 里取年份/地区补上。
     *   这是**补充**而不是替换 —— 有 badges 时完全听后端的。
     *
     * ⚠️ 数据源现在是**类型化字段** `detail.badges` / `detail.meta`
     *    （`MediaDetail` 已按 `model.rs:212,217` 补上这两个字段），
     *    不再走"再读一次原始 JSON"的绕行 —— 那份绕行已撤除。
     */
    final badges = <String>[
      ...detail.badges,
      if (detail.badges.isEmpty) ..._metaFallbackBadges(detail.meta),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          detail.title,
          style: TextStyle(
            fontSize: FontSizes.xl,
            fontWeight: FontWeights.semibold,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: Sp.x3),

        // ── 徽章 ──
        if (badges.isNotEmpty ||
            episodeCount > 0 ||
            localCount > 0 ||
            sourceCount > 1 ||
            providerName != null)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in badges) _Chip(text: b, brand: true),
              if (episodeCount > 0) _Chip(text: '$episodeCount 集'),
              if (localCount > 0) _Chip(text: '已下载 $localCount 集', brand: true),
              if (sourceCount > 1) _Chip(text: '$sourceCount 个播放源'),
              /*
               * ★★ 当前站点名（task-32，用户要求）
               *
               * # 为什么放这里（位置有依据，不是随便挑的）
               *
               * 原版 `SourcePicker.vue:28-34` 解释"单源时隐藏该层"时写：
               * ```text
               * * 因为单独一个源没有「选择」的意义，
               * * **详情页标题区已展示过站名**。
               * ```
               * ★ 而实测 `DetailView.vue:585-593` 的 `hero__badges`
               *   **没有站名** —— 那条注释的立论不成立。
               * ⇒ 这里（`hero__badges`，即 `_Info` 的徽章行）**正是**
               *   注释所指的位置。补上它 = 兑现原版的意图。
               *
               * # 为什么用 `_Chip(brand: true)` 而不是新样式
               *
               * 与后端 badges（「更新至 12 集」等）同一套视觉语言 ——
               * 不发明新控件。brand 高亮是因为"你在哪个站"比
               * "共几集"更该被一眼看到。
               */
              if (providerName != null) _Chip(text: providerName!, brand: true),
            ],
          ),
      ],
    );
  }


  /// ★ 其余「简介 + 操作 + 续播」—— 窄档里**通栏**
  ///
  /// ⚠️ 与 [_head] 之间**没有**额外间距 —— 简介自己带 `Sp.x4` 的顶部间距
  ///    （见下），所以两半拼起来与拆分前的 `Column` **逐字等价**。
  Widget _rest(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 简介 ──
        if (detail.description != null && detail.description!.isNotEmpty) ...[
          const SizedBox(height: Sp.x4),
          Text(
            // ★ task-9 ②：兜底解 HTML 实体（老插件文件没重转的路径，
            //   见 [_decodeHtmlEntities] 的长注释）。幂等 —— 已解过的文本再解不变。
            _decodeHtmlEntities(detail.description!),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: FontSizes.sm,
              height: 1.65,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],

        /*
         * ★★★ task-12 ⑤：**本地模式下整条操作行不画**
         *
         * Owner 原话（逐字）：
         * > 其他都要跟在线播放页一致，除了**集数的展示**，还有那些**操作按钮不显示**
         *
         * 那四枚按钮在本地文件上**每一枚都不成立**：
         * ```text
         * 收藏 / 追更  需要 provider:id —— 本地那一对是 (local, 绝对路径)，
         *              写进去只会往收藏表里塞一条永远打不开的假条目
         * 换源         需要站内线路列表 —— 本地文件没有线路
         * 下载         文件已经在盘上了，再下一遍是纯浪费
         * ```
         * ⚠️ 所以这里**不是"藏起来"**，而是它们本就无处可落。
         */
        if (showActions) ...[
        // ── 操作 ──
        const SizedBox(height: Sp.x4),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            /*
             * ══════════════════════════════════════════════════════════════
             * ★★★ 2026-09-27：删掉「继续观看 / 播放」按钮
             * ══════════════════════════════════════════════════════════════
             *
             * Owner 原话（逐字）：
             * > 我觉得 继续观看按钮可以删除了，因为已经正在播放了
             *
             * # 为什么它**确实**是多余的（不是"少个入口而已"）
             *
             * ```text
             * 合并页里播放器**进来就自动起播**（真机日志逐字）：
             *   [PLAYER] ★ 检测到上次进度 77s，将续播
             *
             * 而本按钮走的是 `_resumePlay()` ⇒ `_play(ep)`
             *   ⇒ `onPlay(PlayRequestData(provider, id, episodeId, …))`
             *   ⇒ `MediaPage._onDetailPlay` ⇒ `session.applySession(req)`
             *   ⇒ ★ `isSameSessionAs` 四元组**完全相同**（provider/id/
             *      episodeId/sourceCode 都是当前正在播的那个）
             *   ⇒ 走"同一会话"分支 ⇒ **只更新标题，不重启流**
             * ```
             * ⇒ ★ 点它**什么都不会发生**（连"重新加载"都不会）。
             *   它看起来是个"播放入口"，实际是个**空操作** ——
             *   比"多余"更糟：用户点了没反应会以为程序卡了。
             *
             * # 与原版的差异（**刻意**，不是漏抄）
             *
             * ```text
             * 原版 `DetailView.vue` 是**独立详情页**：它上面没有播放器，
             * 所以「继续观看」是**唯一**的起播入口 —— 必须有。
             *
             * 而 task-58 把详情页并进了播放页（左侧视频 + 右侧信息）
             * ⇒ 起播由**播放器自己**负责 ⇒ 这个入口失去意义。
             * ```
             * ⚠️ 这也解释了为什么原版有 `resume.position > 5 ? '继续观看' : '播放'`
             *    这套文案切换 —— 那是在"独立页"语境下区分"从头看/接着看"。
             *    合并页里两者都由播放器自动决定，按钮无从表达。
             *
             * # 删掉之后用户怎么起播/换集
             * ```text
             * ① 播放器自己的控制条（播放/暂停/上一集/下一集/选集）
             * ② ★ 右侧的「选集」网格 —— 点任意一集**真的**会切流
             *    （那条路径带 episodeId 且与当前不同 ⇒ 走"换会话"分支）
             * ③ 「换源」按钮 —— 换线路
             * ⇒ 三个真实入口都在，删掉的是**唯一那个假的**。
             * ```
             */
            _ToggleButton(
              icon: isFav ? Icons.star : Icons.star_border,
              label: isFav ? '已收藏' : '收藏',
              on: isFav,
              onTap: onToggleFav,
            ),
            /*
             * ★ 追更按钮（与收藏**完全独立**）
             *
             * Owner 的纠正：
             * > 追更并不代表就要收藏，这是独立的状态
             *
             * 所以：**不需要先收藏**，按钮也不禁用。
             */
            _ToggleButton(
              icon: following ? Icons.notifications : Icons.notifications_none,
              label: following ? '追更中' : '追更',
              on: following,
              onTap: onToggleFollow,
            ),

            /*
             * ★★★ 跨源换源入口（与「播放源」是**两个不同层级**的功能）
             *
             * 原版 `DetailView.vue:639-652` 的注释：
             * > 放在这里而不是塞进「播放源」那一栏 ——
             * > 两者是不同层级的功能（站内换线路 vs 跨站换源），
             * > 混在一起会让用户以为"就这么几条线路"。
             *
             * 原版的位置是**头部操作行**（与播放/收藏/追更并排），
             * 我们原先放在选集区下方，有剧集时要滚下去才看得到 —— 已挪回这里。
             */
            /*
             * ★★★ OPS-9：**这一集磁盘上已经有可播文件 ⇒ 这一枚不画**
             *
             * Owner 原话（逐字）：
             * > 这个好像是概率性的,**缓存到本地就不要显示换源按钮了**
             *
             * ⚠️ 只摘**这一枚** —— 收藏 / 追更 / 下载三枚照旧画。
             *    判据见 [_DetailPageState._hasLocalPlayable]；
             *    与"整条行画不画"的 [showActions] 是**两件事**，
             *    别把它并进上面那个 `if (showActions)`（那样三枚会一起消失）。
             */
            if (!hasLocalFile) ...[
              OutlinedButton.icon(
                onPressed: onSwitchSource,
                icon: const Icon(Icons.swap_horiz, size: 16),
                label: const Text('换源'),
              ),
            ],

            /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 2026-10-08（Owner 第 4 条）：下载入口**挪到这里**
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话：
             * > 支持一下下载整个视频,然后按照一组存放,下载视频那个功能
             * > 挪出来,支持下载所有集和单个集
             *
             * # 「挪出来」从哪儿挪到哪儿（逐字对齐）
             * ```text
             * 改前：只有「播放页 → 播放设置（齿轮）→ 下载本集到缓存」，
             *       而且下的是**分片缓存**（clip-cache，会被上限淘汰）。
             * 改后：详情页头部操作行直接有「下载」——
             *       ★ 点开是菜单：单集 / 全部集，落的都是**整片**文件。
             * ```
             *
             * ⚠️ 播放页那个「下载本集到缓存」**保留**（它服务于
             *    「我就想缓存当前这一集、不占正式空间」这个场景，
             *    且有 6 个测试文件盯着它）。两个入口的语义在按钮文案上
             *    已经区分开：那边是「到缓存」，这边是「下载」。
             */
            _DownloadButton(
              episodeCount: episodeCount,
              onDownloadCurrent: onDownloadCurrent,
              onDownloadAll: onDownloadAll,
            ),
          ],
        ),
        ],

        // ── 续播提示 ──
        if (resume != null && resume!.position > 5) ...[
          const SizedBox(height: Sp.x4),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: 7,
            ),
            decoration: BoxDecoration(
              borderRadius: Radii.rFull,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.history,
                  size: 15,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  '上次看到 ',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                /*
                 * ★★★ 桌面端第 4 条：这里**必须**能省略号截断
                 *
                 * Owner 报（截图 1444x845）：
                 * > 然后左侧的上次看到，文字也超出了
                 *
                 * # 根因
                 * `resumeLabel` 原先拼的是**整条视频标题**（B 站投稿
                 * 标题动辄 30+ 字），而这个 `Row` 是 `MainAxisSize.min`、
                 * 两个 `Text` 都没有 `Flexible`/`maxLines`/`overflow`
                 * ⇒ 文本按自身固有宽度铺开，超出面板右边界被**硬裁**
                 *（不是省略号，是切断）。
                 *
                 * # 为什么是「拆成两段」而不是「整串套 Flexible」
                 * 整串套 `Flexible` 也能止住溢出，但截断点在**串尾**
                 * ⇒ 先没的是「剩 N 分钟」—— 那恰恰是这条提示里唯一
                 *   会变、且用户真要读的信息（标题是背景）。
                 * ⇒ 所以标题单独一段收省略号，时间独立一段不参与压缩。
                 *
                 * ⚠️ 前缀 `'上次看到 '` 那半**不要**一起 Flexible ——
                 * 它是固定文案，被压缩时会出现「上…」，信息反而丢了。
                 */
                Flexible(
                  child: Text(
                    resumeTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                ),
                /*
                 * ★ 时间那半：短、固定、**永不**被压缩
                 *
                 * ⚠️ 它与标题之间那个 ` · ` 分隔符**并进这一串**，
                 *   不单独做一个 Text —— 否则标题被省略号吃掉之后
                 *   会剩一个孤零零的 `·` 挂在左边（很显眼）。
                 *   标题为空时它自然不出现（上面 `_resumeTitle`
                 *   兜底成「单集」，所以实际不会为空）。
                 */
                Text(
                  ' · $resumeRemaining',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.brand = false});

  final String text;
  final bool brand;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 4),
      decoration: BoxDecoration(
        color: brand ? colors.primary.withValues(alpha: 0.16) : null,
        borderRadius: Radii.rFull,
        border: Border.all(
          color: brand ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: brand ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 可切换的按钮（收藏 / 追更）
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: on ? colors.primary : colors.onSurfaceVariant,
        backgroundColor: on ? colors.primary.withValues(alpha: 0.16) : null,
        side: BorderSide(
          color: on ? colors.primary : colors.outlineVariant,
        ),
      ),
    );
  }
}

/// ★★★ 2026-10-08（Owner 第 4 条）：下载按钮（单集 / 全部集）
///
/// # 为什么是「一个按钮 + 菜单」而不是「两个按钮」
/// ```text
/// 这一行已经有 收藏 / 追更 / 换源 三枚了，再加两枚会把窄档挤到换行；
/// 而这两个动作**同一个心智模型**（下载），合成一枚更清楚。
/// ```
///
/// ⚠️ 用 `PopupMenuButton` 而不是 `showModalBottomSheet`：
///    这一行在 `ListView` 里，弹层用 Overlay 才不会跟着滚。
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.episodeCount,
    required this.onDownloadCurrent,
    required this.onDownloadAll,
  });

  final int episodeCount;
  final VoidCallback onDownloadCurrent;

  /// null = 没有剧集列表（电影）⇒ 菜单里不画「全部集」那一项
  final VoidCallback? onDownloadAll;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final all = onDownloadAll;
    /*
     * ★ 用 `PopupMenuButton` 而不是 `OutlinedButton` + 自建弹层：
     *   它与这一行的另外两枚在**视觉上**一致（同样是描边 + 图标 + 文字），
     *   而点击语义是「打开菜单」—— 这正是我们要的（两个动作）。
     *
     * ⚠️ `child` 里**不能**放可点的 `OutlinedButton` —— 它会吃掉
     *    点击事件，菜单永远弹不出来（`PopupMenuButton` 靠包一层
     *    GestureDetector 工作，内层按钮会赢手势竞技场）。
     *    所以这里手画一个形状一致的 Container。
     */
    return PopupMenuButton<String>(
      tooltip: '下载',
      position: PopupMenuPosition.under,
      onSelected: (v) {
        if (v == 'one') {
          onDownloadCurrent();
        } else if (v == 'all') {
          all?.call();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem<String>(
          value: 'one',
          child: Text('下载本集'),
        ),
        if (all != null)
          PopupMenuItem<String>(
            value: 'all',
            child: Text('下载全部集（$episodeCount 集）'),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: 9,
        ),
        decoration: BoxDecoration(
          borderRadius: Radii.rSm,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_outlined,
              size: 16,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: Sp.x1),
            Text(
              '下载',
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// ★ task-12 ⑤ + task-17 ③：本地模式的一行「已下载的一集」
///
/// 形态参照 download_panel 的「一集一行」（Owner 上一轮要的形态），
/// 但**不复用**那个私有组件：那是下载队列的行（带暂停/删除/进度），
/// 而这里只需要"哪一集 + 在播哪个"。
///
/// # ★ task-17 ③ 加的两个能力
/// ```text
/// checked  != null  ⇒ 选择态：左侧画勾选框（点行即选，见调用点）
/// onDelete != null  ⇒ 普通态：右侧一枚垃圾桶，**悬停才显形**
/// ```
/// ⚠️ 垃圾桶默认透明、悬停变红（与 cache_page 的 _HoverDeleteButton 同款观感）——
///    常显的话每一行右边都挂一个红图标，列表会很吵。
class _LocalEpisodeRow extends StatelessWidget {
  const _LocalEpisodeRow({
    super.key,
    required this.ref,
    required this.active,
    required this.onTap,
    this.checked,
    this.onDelete,
  });

  final LocalEpisodeRef ref;

  /// 正在播的那一集（高亮）
  final bool active;

  /// null = 外层没给回调 ⇒ 不可点（不画水波纹，也不给手型光标）
  final VoidCallback? onTap;

  /// ★ task-17 ③：null = 非选择态（不画勾选框）；true/false = 选择态下的勾选状态
  final bool? checked;

  /// ★ task-17 ③：null = 不提供单集删除（选择态里就是 null —— 那时删的是"选中的"）
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x1, horizontal: Sp.x2),
      child: Row(
        children: [
          // ── 勾选框（仅选择态）──
          if (checked != null) ...[
            Icon(
              checked!
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: checked! ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: Sp.x2),
          ],
          Icon(
            active ? Icons.play_circle_fill : Icons.movie_outlined,
            size: 18,
            color: active ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ref.episodeTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? colors.primary : colors.onSurface,
                  ),
                ),
                // ★ Owner ３：大小 · 看过多少（那些“在线播放页有的信息”之一）
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      humanBytes(ref.bytes),
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (ref.watched) ...[
                      const SizedBox(width: Sp.x2),
                      // 已看标记：看过（不是当前在播）
                      Icon(Icons.check_circle, size: 13, color: colors.primary),
                      const SizedBox(width: 3),
                      Text(
                        ref.watchRatio >= 0.995 ? '已看完' : '已看 ${(ref.watchRatio * 100).round()}%',
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.primary,
                        ),
                      ),
                    ],
                  ],
                ),
                // 看过一截但没看完 → 一条极薄的底度进度条
                if (ref.watched && ref.watchRatio < 0.995) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: Radii.rSm,
                    child: LinearProgressIndicator(
                      value: ref.watchRatio,
                      minHeight: 3,
                      backgroundColor: colors.surfaceContainerHighest,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // ── 单集删除（仅普通态且外层给了回调）──
          if (onDelete != null) _LocalRowDeleteButton(onTap: onDelete!),
        ],
      ),
    );
    if (onTap == null) return row;
    /*
     * ★★★ 探针抓到的真缺陷（2026-10-09，zz_t12_local_detail_probe_test）：
     * ```text
     * No Material widget found.
     * _InkResponseStateWidget widgets require a Material widget ancestor …
     *   InkWell ← _LocalEpisodeRow ← Column ← …
     * ```
     * # 为什么本页会没有 Material 祖先
     * ```text
     * 合并页里详情区是 embedded ⇒ 本页**不画** Scaffold（task-58 的硬要求），
     * 底色只有一个 ColoredBox ⇒ 树里没有 Material。
     * 生产路径上 MediaPage 自己那层 Scaffold 恰好提供了它 ——
     * 所以真机上不炸；但那是**别人的**祖先，本组件不该依赖它。
     * ```
     * ⇒ 自己铺一层**透明** Material（只让墨水效果有地方画，不引入底色）。
     */
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rSm,
        child: row,
      ),
    );
  }
}

/// ★ task-17 ③：一行的「删除这一集」按钮（悬停才显形）
///
/// # 为什么默认透明而不是"默认灰"
/// ```text
/// Owner 这一轮说"这里操作要优化" —— 而每一行右边常驻一个垃圾桶正是"不优化"：
/// 一个 10 集的列表会有 10 个图标抢注意力，而用户 99% 的时间是在**选着播**。
/// ⇒ 常态透明（占位、不抢视线），鼠标进入该行才浮现。
/// ```
/// ⚠️ 用 MouseRegion 而不是 InkWell 的 hover：InkWell 的悬停高亮是**整行**的，
///    而这里要的是"该行出现一个图标"（cache_page 的 _HoverDeleteButton 同款做法）。
class _LocalRowDeleteButton extends StatefulWidget {
  const _LocalRowDeleteButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_LocalRowDeleteButton> createState() => _LocalRowDeleteButtonState();
}

class _LocalRowDeleteButtonState extends State<_LocalRowDeleteButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: '删除这一集',
        child: IconButton(
          // ★ 与 cache_page 的 28×28 同款：够点，但不抢版面
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          iconSize: 16,
          onPressed: widget.onTap,
          icon: Icon(
            Icons.delete_outline_rounded,
            color: _hover ? colors.error : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

/// ★ task-12 ⑤：本地模式下**一集都没下**时的中性说明
///
/// ⚠️ 刻意**不**复用`_ErrorView'`'：那会画出红叹号 + 「加载失败」，
///    而"没下载"是**正常状态**，不是故障（真机上"加载失败 + 无法路由"那次的教训：
///    把正常状态画成故障，用户会以为程序坏了）。
class _LocalEmptyHint extends StatelessWidget {
  const _LocalEmptyHint({required this.file});

  final String file;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '这台机器上还没有下好这一部',
          style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x1),
        Text(
          file,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 选集按钮
class _EpisodeButton extends StatelessWidget {
  const _EpisodeButton({
    required this.title,
    required this.active,
    required this.played,
    required this.onTap,
  });

  final String title;

  /// 当前**选中**（默认上次观看的，否则第一集）
  final bool active;

  /// 曾经**看过**
  final bool played;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rSm,
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: Sp.x2,
        ),
        decoration: BoxDecoration(
          color: active ? colors.primary.withValues(alpha: 0.16) : null,
          borderRadius: Radii.rSm,
          border: Border.all(
            color: active ? colors.primary : colors.outlineVariant,
            width: active ? 2 : 1,
          ),
        ),
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: FontSizes.sm,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            // 看过的用主色文字标出来（与"选中"的边框区分开）
            color: active
                ? colors.primary
                : (played ? colors.primary : colors.onSurface),
          ),
        ),
      ),
    );
  }
}

class _BlockTitle extends StatelessWidget {
  const _BlockTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppMetrics.contentPadding,
        0,
        AppMetrics.contentPadding,
        Sp.x4,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: FontSizes.lg,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
    );
  }
}

class _EpsSkeleton extends StatelessWidget {
  const _EpsSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: Sp.x2,
      runSpacing: Sp.x2,
      children: [
        for (var i = 0; i < 12; i++)
          Container(
            width: 72,
            height: 36,
            decoration: BoxDecoration(
              color: colors.onSurface.withValues(alpha: 0.05),
              borderRadius: Radii.rSm,
            ),
          ),
      ],
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Sp.x5,
        vertical: Sp.x3,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: Radii.rFull,
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: FontSizes.sm,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});

  final String message;

  /// ★ task-58：`null` = **不画返回按钮**
  ///
  /// 合并页（`embedded: true`）里返回的语义是"回首页"，由 `MediaPage`
  /// 顶层统一处理 ⇒ 这里再画一个会与它重复且语义不一致。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.error),
            const SizedBox(height: Sp.x4),
            Text(
              '加载失败',
              style: TextStyle(
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x2),
            /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 2026-10-08（macOS CI 逼出来的）：错误文本必须**可滚动**
             * ══════════════════════════════════════════════════════════
             *
             * # 症状（macOS CI 实测，不是推理）
             * ```text
             * A RenderFlex overflowed by 580 pixels on the bottom.
             * Column Column:file:///…/lib/ui/detail_page.dart:3279:16
             * creator: Column ← Padding ← Center ← _ErrorView ← Stack ← …
             * constraints: BoxConstraints(0.0<=w<=320.0, 0.0<=h<=736.0)
             * ```
             * t59 有 6 条 ★★★、t97 有 1 条，在 macOS 上全红 ——
             * 而**断言本身是通过的**（`[T60] embedded ColoredBox colors = [… surface]`），
             * 红在同一次 pump 抛的溢出异常上。
             *
             * # 为什么只有 macOS 红（真因不在主题/布局）
             * ```text
             * macOS 上缺 libsourin_core.dylib ⇒ DetailPage 落进本组件，
             * 而 dlopen 失败文本是**平台相关**的：
             *   Windows : `Failed to load dynamic library … (error code: 126)`
             *             ≈ 100 字符 ⇒ 塞得下 ⇒ 不溢出 ⇒ 同组在 Windows 绿
             *   macOS   : `dlopen(…, 0x0001): tried: '…' (no such file),
             *              '/System/Volumes/Preboot/…' (no such file), …`
             *             ≈ 1500 字符，列出一长串搜索路径 ⇒ 必然溢出
             * ```
             * ⇒ 这是**真的产品缺陷**，不是测试环境问题：任何一条足够长的
             *   错误信息（插件报错、HTTP 报错体、路径很长的加载失败）
             *   在窄面板下都会溢出。macOS 只是把它逼出来了。
             *
             * # 修法
             * ```text
             * 包一层 `Flexible` + `SingleChildScrollView`：
             *   · `Flexible` 让它**参与** Column 的高度分配（不撑破父级）；
             *   · `SingleChildScrollView` 让超长文本**可滚动**，
             *     信息一个字都不丢（比截断/省略号诚实）。
             * ★ 没有改成 `TextOverflow.ellipsis` —— 那会**隐藏**用户
             *   排查所需的真实原因（本仓一贯纪律：不吞错误）。
             * ```
             *
             * ⚠️ 不要把它换成 `Expanded`：`Column` 是 `mainAxisSize: min`，
             *    用 `Expanded` 会在无界高度下断言失败。
             */
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Sp.x6),
            // ★ task-58：`onBack == null`（合并页）⇒ 不画（返回由 MediaPage 负责）
            if (onBack != null)
              OutlinedButton(onPressed: onBack, child: const Text('返回')),
          ],
        ),
      ),
    );
  }
}
