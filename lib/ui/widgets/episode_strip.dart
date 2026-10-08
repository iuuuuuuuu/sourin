// ═══════════════════════════════════════════════════════════════════════
//  选集条（EpisodeStrip）+ 完整选集面板（EpisodeSheet）
//  —— **按端三种形态**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么有这个文件（用户可见的交互缺口）
//
// 原版 `src/components/EpisodeStrip.vue` 是 Owner 明确要求 + 实测腾讯
// PC 播放页真实 DOM 之后做的**三端分流**。我们之前的实现是
// `player_page.dart` 里的 `_EpisodeSheet` —— 一个**单一的 320px 右侧
// 实心黑栏**，三端都一个样。
//
// 原版 Owner 原话：
// > app 这个集数也不能无限显示下去，一般是显示一部分，
// > 然后如果集数多，就有个小箭头，点击一下，从下面弹出来选择集数，
// > 一般是一行显示一行集数，然后看到哪集，再进来，
// > 也跟首页的那个一样，是会自动滚动到当前播放集数的，可视区域的
//
// 随后**补正**（关键）：
// > 播放页面 选集这里，在**桌面端 tv app 显示的逻辑应该是不一样的**，
// > 请参考主流的软件的逻辑应用
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★ 为什么"三端不一样"是对的 —— 输入设备决定的
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// | 端   | 主输入        | 空间特性        | 所以适合                    |
// |------|--------------|----------------|----------------------------|
// | 桌面 | 鼠标 + 滚轮   | 宽，高也够      | 二维网格（信息密度高）        |
// | 手机 | 手指滑动      | 窄(412px)，竖向宝贵 | 横向一行（只占一行高）    |
// | TV   | 遥控器方向键   | 宽，但移动成本高 | 横向一行（左右键最顺）        |
// ```
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 腾讯视频 PC 播放页的**实测数据**（原版用 CDP 读的真实 DOM）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// .episode-list              display:flex; flex-direction:row;
//                            flex-wrap:**wrap**          ← 换行网格
// .episode-list-container    overflow-y:**auto**         ← 内部纵向滚动
// .episode-module-container  max-height:**440px**        ← 限高
// ```
// **结论：腾讯在 PC 上是「限高的换行网格 + 内部滚动」，不是横向一行。**
// 剧集多了在**区内纵向滚**，用鼠标滚轮天然顺手。
//
// 这印证了 Owner 的「应该不一样」—— 原版上一版三端都做成横向一行，
// 那是**照搬了手机的逻辑**。
//
// ═══════════════════════════════════════════════════════════════════════
//  最终方案（照抄原版）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// 桌面   → 换行网格，限高约 3 行，超出**内部纵向滚动**（抄腾讯）
//          · 不需要箭头（滚动就能看全）
// TV     → 一行横向滚动
//          · 超过 20 集 → 末尾箭头 → 底部弹出（分卷 + 网格）
// 手机   → 一行横向滚动（与 TV 同一套）
//          · 超过 20 集 → 末尾箭头 → 底部弹出
// ```
//
// ⚠️ **为什么 TV 不也用网格**：
//    遥控器走 500 集要走 500 次（网格还要算上下行）。
//    横向一行 + 弹出面板（带分卷）才是遥控器能承受的。
//
// ⚠️ **为什么桌面不用箭头**：
//    已有内部滚动，再加折叠是**双重隐藏**（用户要先滚再点），
//    反而更绕。腾讯在 PC 上也没有折叠。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★ 完整选集面板（EpisodeSheet）—— 「从下面弹出来」
// ═══════════════════════════════════════════════════════════════════════
//
// Owner：「如果集数多，就有个小箭头，点击一下，**从下面弹出来**选择集数」
//
// 所以它是 bottom sheet（底部抽屉），**不是**居中弹窗 ——
// 「从下面弹出来」是明确的形态要求。三个设计决定（照抄原版
// `EpisodeSheet.vue` 文件头，都有原因）：
//
// ```text
// ① 网格而不是单列
//    单列 500 集要滚很久；网格一屏能看到几十集。
// ② 自动滚到当前集（与选集条同一个要求）
//    进来时当前集可能在第 87 集 —— 必须滚过去高亮它。
// ③ 分卷显示（集数极多时）
//    500 集一次性渲染在低端 TV 盒子上会卡；先按 100 集一组分段。
//    （实测多数剧集 < 100，所以分段通常不出现。）
// ```
//
// ⚠️ **只在手机 / TV 出现**（原版 `PlayerView.vue`：
//    `v-if="episodeSheetOpen && !isDesktop"`）——
//    桌面用的是"限高网格 + 内部滚动"，不需要弹出面板。

import 'dart:math' as math;

import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
// ⚠️ `LogicalKeyboardKey` / `KeyDownEvent` 在 services 里，
//    `material_ui` **不**转出它们（键盘事件是引擎层概念，不属于 UI 层）
import 'package:flutter/services.dart';

import '../../core/device.dart';
import '../../core/models.dart';
import '../tokens.dart';
import 'overlay_motion.dart';

/// 超过多少集才显示「展开」箭头（**只对手机/TV 生效**）
///
/// Owner 定的：**超过 20 集**就出箭头。
///
/// ⚠️ 为什么不是"装不下才出"：那会导致窗口稍窄就冒出箭头、
///    稍宽又消失，非常跳。**固定阈值行为稳定、可预期**。
const int kEpisodeCollapseAfter = 20;

/// 完整面板里每段多少集（超过就分段）—— 照抄原版 `chunkSize: 100`
///
/// ⚠️ 为什么是 100：500 集一次性建 500 个控件在低端 TV 盒子上会卡。
///    100 是"一屏能看完 + 渲染量可控"的折中。
const int kEpisodeChunkSize = 100;

/// 胶囊高度（横向条与箭头共用，保证一行内高度一致）
const double _kChipH = 36;

/// TV 焦点环粗细（与 `source_bar.dart` 的 `_SourcePill` 同一个值）
const double _kFocusRingWidth = 2;

/// 网格/面板里每个格子的目标宽度
///
/// 照抄原版两处 CSS 的 `minmax(84px, 1fr)` —— 横向条里则是内容宽度。
const double _kCellTarget = 84;

/// 网格间距（原版 `gap: 6px`）
const double _kGridGap = 6;

/// 网格里每个格子的高度（比横向条的胶囊高一档 —— 见 `_EpisodeChip` 的说明）
const double _kGridCellH = 40;

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ PC 右侧抽屉（2026-09-25 任务㉑⑪，用户明确要求）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 这个选集,我希望pc操作是点击然后**右侧出现抽屉**进行选集,
// > 如果有上百集,我希望**自动滚动到当前所观看的集的位置**,
// > 并且**支持搜索**。手机和tv你自己想想交互
//
// # 为什么改成"右侧抽屉"（而不是原来的居中弹窗）
//
// ```text
// 居中弹窗  遮住画面中央 —— 用户看剧时最不想被挡的就是中间
// 右侧抽屉  贴右边，画面主体（居中偏左）基本不被挡
//           而且"点 → 从右侧滑出"是 PC 播放器的通行做法
//           （腾讯/B站/YouTube 的播放列表都在右侧）
// ```
// 用户说"右侧出现抽屉"，这是**形态要求**，照做。
//
// # 为什么加搜索
//
// 用户原话要求"支持搜索"。分母很实在：
// ```text
// 500 集的剧 —— 即使有分段（1-100 / 101-200 …）也要点 4 次再滚
// 搜索「237」→ 直接一屏看到那几集
// ```
// 搜索**不改变** chunk 语义：搜到之后显示的是**全部匹配项**
// （跨段），因为用户的意图是"找到那一集"，不是"在当前段里找"。
//
// ⚠️ 搜索框只在**集数足够多**时才有意义 —— 12 集的剧摆个搜索框是噪音。
//    阈值复用 [kEpisodeSearchAfter]。

/// 超过多少集才在面板里显示**搜索框**
///
/// ⚠️ 为什么是 30（而不是像折叠箭头那样 20）：
///    折叠箭头解决的是"**放不下**"（20 集一行确实挤），
///    搜索解决的是"**找不到**"（要翻很久才值得搜）。
///    两者阈值不同是**有意的**，不是抄漏了。
const int kEpisodeSearchAfter = 30;

/// 面板形态
///
/// ```text
/// rightDrawer  PC    —— 贴右侧的抽屉（用户要求）
/// bottomSheet  手机  —— 底部弹出（手指从下往上够得着）
/// grid          TV    —— 不用这个枚举；TV 走 `_StripDrawer` 那套
/// ```
enum EpisodePanelStyle {
  /// PC：右侧抽屉。限宽、全高、内部纵向滚动。
  rightDrawer,

  /// 手机：底部抽屉。透传 `asDialog: false`（圆角只圆上面两角）。
  bottomSheet,
}

/// 桌面网格显示**几行**（超出的部分内部纵向滚动）
///
/// 原版 CSS 写的是 `max-height: 150px`，注释里的结论是「约 3 行」。
/// 这里把「3」提成常量而不是继续写死像素 —— 因为格高会随字号/端缩放变，
/// 写死像素的话「几行」会悄悄漂掉（比如 TV 的 `textScale = 1.25`）。
const int kGridRows = 3;

/// 横向条「已可见就不动」时留给目标的最小边距（原版 `- 12`）
const double kRailScrollMargin = 12;

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 纯几何函数 —— **抽出来是为了能被像素级断言**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这些必须抽成纯函数（项目踩过的坑）
//
// 上一轮我们用「源码里有没有某个字符串」来验收自动滚动 ——
// 结果**代码在、行为错**（`alignment: 0.0` 把已可见的格子硬拽到左边缘），
// 字符串断言全绿而用户看到的还是跳。
//
// 几何算错只有**算一遍数字**才能发现。所以把「列数 / 格宽 / 限高 /
// 滚动目标偏移」这些算式的输入输出暴露出来，测试直接断言数值。
//
// 这些函数**不碰任何 Widget / BuildContext** —— 纯输入输出，可任意单测。

/// 网格限高 = [rows] 行格子 + 行间距
///
/// 原版 `max-height: 150px` 是写死的；这里由「行数 × 格高 + 间距」推导，
/// 保证**限高与实际渲染出来的行高永远一致**（写死的话字号一变就露出半行）。
double gridMaxHeight({
  int rows = kGridRows,
  double cell = _kGridCellH,
  double gap = _kGridGap,
}) {
  if (rows <= 0) return 0;
  return rows * cell + (rows - 1) * gap;
}

/// 网格能放几列 —— 复刻 CSS `repeat(auto-fill, minmax(cell, 1fr))`
///
/// ```text
/// cols = floor((W + gap) / (cell + gap))
/// ```
/// `+ gap` 是因为 N 列之间只有 N-1 个间距，但 `auto-fill` 的算法
/// 把「末尾那个间距」也算进可用宽度里（否则刚好放得下 N 列时会算成 N-1）。
int gridColumns(
  double maxWidth, {
  double cell = _kCellTarget,
  double gap = _kGridGap,
}) {
  if (maxWidth <= 0 || cell <= 0) return 1;
  final n = ((maxWidth + gap) / (cell + gap)).floor();
  return n < 1 ? 1 : n;
}

/// 每格宽度 —— `1fr` 的语义：把扣掉间距后的剩余宽度**均分**
double gridCellWidth(double maxWidth, int cols, {double gap = _kGridGap}) {
  if (cols <= 0) return maxWidth < 0 ? 0 : maxWidth;
  final w = (maxWidth - gap * (cols - 1)) / cols;
  return w < 0 ? 0 : w;
}

/// 折叠后**实际渲染**多少集（原版 `visibleEps`）
///
/// ⚠️ 阈值语义是「**超过** 20 才折叠」—— 正好 20 集**不折叠、不出箭头**。
///    这是 Owner 定的数字，测试要把它钉死。
int visibleEpisodeCount(
  int total, {
  int collapseAfter = kEpisodeCollapseAfter,
}) => total > collapseAfter ? collapseAfter : total;

/// 把滚动偏移夹进合法区间（内容比视口短时上限是 0，不是负数）
double _clampScroll(double target, double maxScroll) {
  if (maxScroll <= 0) return 0;
  return target.clamp(0.0, maxScroll);
}

/// **横向条**（手机 / TV）的滚动目标偏移
///
/// 照抄原版 `scrollToCurrent` 的两个分支：
/// ```js
/// if (center) {
///   target = scrollLeft + (br.left - rr.left) - (rr.width - br.width) / 2;
/// } else {
///   if (br.left >= rr.left && br.right <= rr.right) return;   // ★ 已可见就不动
///   target = scrollLeft + (br.left - rr.left) - 12;
/// }
/// rail.scrollTo({ left: Math.max(0, Math.min(target, max)) });
/// ```
///
/// # ★★★ 为什么不能直接用 `Scrollable.ensureVisible`
///
/// 原版切集时用的是 **nearest 语义**：目标已经看得见就**一个像素都不动**。
///
/// 而 `Scrollable.ensureVisible(alignment: 0.0)` 的语义是
/// 「把目标的**起始边对齐视口起始边**」—— 它**不看**目标是否已可见，
/// 于是：
/// ```text
/// 当前集在视口正中间（完全看得见，用户正看着）
///   → 切到下一集
///   → alignment 0.0 把它**硬拽到最左边**
///   → 整条大幅度平移，用户看到"条自己跳了一下"
/// ```
/// 这正是原版注释里说的「切集时用居中会让整条大幅移动，视觉上很跳」，
/// 只不过 `alignment: 0.0` 只是换了一种跳法 —— **不是** nearest。
///
/// 所以这里自己算偏移 + `animateTo`，语义与原版逐字对应。
///
/// * [itemStart] 目标在**视口坐标系**里的起点（负 = 在视口左侧之外）
/// * [current] 当前滚动偏移
double railScrollTarget({
  required double itemStart,
  required double itemExtent,
  required double viewportExtent,
  required double contentExtent,
  required double current,
  required bool center,
  double margin = kRailScrollMargin,
}) {
  final maxScroll = math.max(0.0, contentExtent - viewportExtent);

  if (center) {
    // 居中：让目标中心落在视口中心
    final target = current + itemStart - (viewportExtent - itemExtent) / 2;
    return _clampScroll(target, maxScroll);
  }

  // nearest：**已完全可见就不动**
  if (itemStart >= 0 && itemStart + itemExtent <= viewportExtent)
    return current;

  return _clampScroll(current + itemStart - margin, maxScroll);
}

/// **网格**（桌面）的滚动目标偏移
///
/// ⚠️ 原版的网格分支与横向条**不是同一套逻辑**，照抄时不能想当然：
/// ```js
/// if (useGrid) {
///   if (br.top >= rr.top && br.bottom <= rr.bottom) return;   // 已可见就不动
///   rail.scrollTo({ top: scrollTop + (br.top - rr.top) - (rr.height - br.height) / 2 });
///   return;                                                    // ← 没有 nearest 分支
/// }
/// ```
/// 也就是说网格**忽略 `center` 参数**：永远是「已可见不动 / 否则居中」。
/// （原版还专门记过这个坑：一开始两种形态都写 `scrollLeft`，
///  在网格里那个值恒为 0，等于**完全没滚动**。）
double gridScrollTarget({
  required double itemStart,
  required double itemExtent,
  required double viewportExtent,
  required double contentExtent,
  required double current,
}) {
  if (itemStart >= 0 && itemStart + itemExtent <= viewportExtent)
    return current;
  final maxScroll = math.max(0.0, contentExtent - viewportExtent);
  final target = current + itemStart - (viewportExtent - itemExtent) / 2;
  return _clampScroll(target, maxScroll);
}

/// 量出来的滚动几何（[itemStart] 在视口坐标系里）
class ScrollGeom {
  const ScrollGeom({
    required this.itemStart,
    required this.itemExtent,
    required this.viewportExtent,
    required this.contentExtent,
    required this.current,
  });

  final double itemStart;
  final double itemExtent;
  final double viewportExtent;
  final double contentExtent;
  final double current;
}

/// 从「目标格子的 GlobalKey」+「滚动控制器」量出滚动所需的几何
///
/// 返回 null 表示**量不到**，调用方应当静默跳过。两种情况：
/// ```text
/// ① 目标没被构建（折叠态下当前集是第 87 集，只渲染了前 20 个）
/// ② 还没挂到滚动容器上（首帧之前）
/// ```
/// 两者都是**预期情况**，不是错误 —— 原版 `if (!btn) return;` 同理。
ScrollGeom? measureScrollGeom({
  required BuildContext? itemContext,
  required ScrollController controller,
  required Axis axis,
}) {
  if (!controller.hasClients) return null;

  final itemBox = itemContext?.findRenderObject();
  if (itemBox is! RenderBox || !itemBox.hasSize || !itemBox.attached)
    return null;

  // ⚠️ `position.context` 是**非空**的 `ScrollContext`（不是可空）——
  //    写 `?.` 会得到 `invalid_null_aware_operator` 警告
  final viewportBox = controller.position.context.storageContext
      .findRenderObject();
  if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;

  // 用 localToGlobal 求「目标相对视口原点」的位移 —— 纯变换，不依赖绘制
  final origin = itemBox.localToGlobal(Offset.zero, ancestor: viewportBox);
  final horizontal = axis == Axis.horizontal;

  final viewportExtent = horizontal
      ? viewportBox.size.width
      : viewportBox.size.height;

  return ScrollGeom(
    itemStart: horizontal ? origin.dx : origin.dy,
    itemExtent: horizontal ? itemBox.size.width : itemBox.size.height,
    viewportExtent: viewportExtent,
    // 内容总长 = 已滚过的 + 视口（`maxScrollExtent` 只在有内容时有意义）
    contentExtent: controller.position.maxScrollExtent + viewportExtent,
    current: controller.position.pixels,
  );
}

/// 选集条 —— 按端三种形态
class EpisodeStrip extends StatelessWidget {
  const EpisodeStrip({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
    this.onExpand,
    this.isDesktopOverride,
  });

  final List<Episode> episodes;

  /// 当前播放集的**下标**（-1 = 未知）
  ///
  /// ⚠️ 用下标而不是 episodeId：我们的 `_epIndex` 就是下标，
  ///    原版用 id 是因为它拿到的 session 里只有 id。
  ///    这里顺着我们既有的数据形状走，语义等价。
  final int currentIndex;

  final void Function(Episode) onPick;

  /// 点「展开」箭头 → 底部弹出完整面板
  ///
  /// ⚠️ **仅手机/TV 会调用**。桌面传 null（桌面不显示箭头）。
  final VoidCallback? onExpand;

  /// 测试用：强制指定是否为桌面形态
  ///
  /// ⚠️ 生产代码**不要传** —— 形态必须由 `Device.isDesktop`
  ///    （能力检测）决定，不能用窗口宽度，否则用户拖窗口会导致
  ///    **形态跳变**（网格 ↔ 横向条），而输入设备不会中途变。
  ///    判据稳定，形态才稳定。
  final bool? isDesktopOverride;

  @override
  Widget build(BuildContext context) {
    final isDesktop = isDesktopOverride ?? Device.isDesktop;

    if (isDesktop) {
      // 桌面：换行网格 + 内部纵向滚动（**无箭头** —— 见文件头说明）
      return _GridRail(
        episodes: episodes,
        currentIndex: currentIndex,
        onPick: onPick,
      );
    }

    // 手机 / TV：横向一行 + 超阈值出箭头
    //
    // ⚠️ 折叠数量走 [visibleEpisodeCount]（纯函数）—— 不在 build 里
    //    重写一遍「> 20」那个判断。否则测试钉住的是纯函数，
    //    而真正生效的是另一份算式，**两边会漂移**。
    final visibleCount = visibleEpisodeCount(episodes.length);
    final collapsed = visibleCount < episodes.length;
    final visible = collapsed ? episodes.sublist(0, visibleCount) : episodes;

    return Row(
      children: [
        Expanded(
          child: _HorizontalRail(
            episodes: visible,
            currentIndex: currentIndex,
            onPick: onPick,
          ),
        ),
        if (collapsed && onExpand != null) ...[
          const SizedBox(width: Sp.x2),
          _MoreButton(count: episodes.length, onTap: onExpand!),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  横向条形态（手机 / TV）
// ═══════════════════════════════════════════════════════════════════════

/// 横向一行（手机 / TV 共用）
class _HorizontalRail extends StatefulWidget {
  const _HorizontalRail({
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
  });

  final List<Episode> episodes;
  final int currentIndex;
  final void Function(Episode) onPick;

  @override
  State<_HorizontalRail> createState() => _HorizontalRailState();
}

class _HorizontalRailState extends State<_HorizontalRail> {
  final _controller = ScrollController();

  /// 每一集的 Key —— 用来算"当前集在哪个位置"
  final _keys = <int, GlobalKey>{};

  /// 每一集的 FocusNode —— **TV 上要主动把焦点放到当前集**
  ///
  /// ⚠️ 为什么不能靠 `autofocus`：面板打开时播放器根 `Focus` 已经
  ///    持有焦点，`autofocus` 只在"所属 FocusScope 里没有任何焦点"时
  ///    才生效 —— 这里永远不成立。必须显式 `requestFocus()`。
  final _nodes = <int, FocusNode>{};

  FocusNode _nodeFor(int i) =>
      _nodes.putIfAbsent(i, () => FocusNode(debugLabel: 'episode-$i'));

  @override
  void initState() {
    super.initState();
    // 等首帧渲染完再滚（否则算出来的坐标是错的 —— 原版用
    // `nextTick + requestAnimationFrame`，这里是同一个道理）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrent();
      _focusCurrent();
    });
  }

  @override
  void didUpdateWidget(_HorizontalRail old) {
    super.didUpdateWidget(old);
    /*
     * ★ 切集时跟随（连播切下一集、点选集都走这里）
     *
     * ⚠️ 用 `center: false`（nearest）—— 切集时用居中会让整条
     *    **大幅移动**，视觉上很跳。原版也是这么区分的：
     *    挂载时居中（第一次要让人看到"我在哪"），
     *    切集时 nearest（已经在附近就不动）。
     */
    if (old.currentIndex != widget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrent(center: false),
      );
    }
  }

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _controller.dispose();
    super.dispose();
  }

  /// 把当前集滚进可视区
  ///
  /// ★ 这里**不用** `Scrollable.ensureVisible` —— 为什么见
  /// [railScrollTarget] 的文档（一句话：它的 `alignment` 没有
  /// 「已可见就不动」这个 nearest 语义，切集时会把整条拽一下）。
  void _scrollToCurrent({bool center = true}) {
    if (!mounted) return;

    // 折叠态下当前集可能没被渲染（比如当前是第 87 集，折叠只显示前 20）
    final ctx = _keys[widget.currentIndex]?.currentContext;
    final geom = measureScrollGeom(
      itemContext: ctx,
      controller: _controller,
      axis: Axis.horizontal,
    );
    if (geom == null) return;

    final target = railScrollTarget(
      itemStart: geom.itemStart,
      itemExtent: geom.itemExtent,
      viewportExtent: geom.viewportExtent,
      contentExtent: geom.contentExtent,
      current: geom.current,
      center: center,
    );

    // 已经到位就不发动画（避免无谓的一帧）
    if ((target - _controller.position.pixels).abs() < 0.5) return;

    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// TV：把焦点放到**当前集**（当前集没渲染时退到第一集）
  ///
  /// ⚠️ 为什么必须做：面板打开时原来持有焦点的「选集」按钮
  ///    已经被移除（控制条一起隐藏了），焦点会掉到播放器根节点。
  ///    那时按方向键虽然也能走，但起点是**整屏矩形**，
  ///    第一个邻居不可预期 —— 用户会觉得"遥控器乱跳"。
  void _focusCurrent() {
    if (!mounted || !Device.needsFocusRing) return;
    final i = widget.currentIndex >= 0 ? widget.currentIndex : 0;
    final n = _nodes[i] ?? _nodes[0];
    if (n != null && n.canRequestFocus) n.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kChipH,
      /*
       * ⚠️ 用 `SingleChildScrollView + Row` 而**不是** `ListView.builder`
       *
       * # 为什么（2026-09-24 实测发现的真 bug）
       *
       * `ListView.builder` 是**懒构建**的：只有"视口 + cacheExtent"
       * 范围内的格子才会真正建出 Element / RenderBox。
       *
       * 而自动滚动靠的是 `GlobalKey.currentContext` —— 目标格子没被
       * 构建时它**是 null**，`_scrollToCurrent` 就静默 return 了：
       * ```text
       * 当前是第 19 集（折叠态最后几个）
       *   → 它在视口外、超出 cacheExtent
       *   → currentContext == null
       *   → 完全不滚动，用户看到的是第 1 集
       * ```
       * 表现就是「Owner 明确要求的自动滚动**没生效**」，
       * 而且不报任何错（原版也强调过 `nextTick` 后才算坐标）。
       *
       * 折叠态最多渲染 [kEpisodeCollapseAfter]（20）个格子，
       * 非折叠态也 ≤20 —— **一次全建出来的代价可以忽略**，
       * 换来的是自动滚动在**所有情况下**都真的生效。
       */
      child: SingleChildScrollView(
        clipBehavior: Clip.antiAlias,
        controller: _controller,
        scrollDirection: Axis.horizontal,
        /*
         * ⚠️ 用 `ClampingScrollPhysics` 而不是默认 ——
         *    TV 上空间导航需要能滚
         *    （`spatial_nav.dart` 的 `_scrollIntoView` 依赖它）。
         */
        physics: const ClampingScrollPhysics(),
        child: Row(
          children: [
            for (var i = 0; i < widget.episodes.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _EpisodeChip(
                key: _keys.putIfAbsent(i, () => GlobalKey()),
                focusNode: _nodeFor(i),
                episode: widget.episodes[i],
                active: i == widget.currentIndex,
                onTap: () => widget.onPick(widget.episodes[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  网格形态（桌面）—— 抄腾讯 PC 播放页的实测结构
// ═══════════════════════════════════════════════════════════════════════

class _GridRail extends StatefulWidget {
  const _GridRail({
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
  });

  final List<Episode> episodes;
  final int currentIndex;
  final void Function(Episode) onPick;

  @override
  State<_GridRail> createState() => _GridRailState();
}

class _GridRailState extends State<_GridRail> {
  final _controller = ScrollController();
  final _keys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void didUpdateWidget(_GridRail old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrent(center: false),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 把当前集滚进可视区
  ///
  /// ⚠️ 网格是**纵向**滚动，且原版这个分支**忽略 `center` 参数** ——
  ///    永远是「已可见不动 / 否则居中」。见 [gridScrollTarget]。
  void _scrollToCurrent({bool center = true}) {
    if (!mounted) return;

    final ctx = _keys[widget.currentIndex]?.currentContext;
    final geom = measureScrollGeom(
      itemContext: ctx,
      controller: _controller,
      axis: Axis.vertical,
    );
    if (geom == null) return;

    final target = gridScrollTarget(
      itemStart: geom.itemStart,
      itemExtent: geom.itemExtent,
      viewportExtent: geom.viewportExtent,
      contentExtent: geom.contentExtent,
      current: geom.current,
    );

    if ((target - _controller.position.pixels).abs() < 0.5) return;

    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      /*
       * ⚠️ **限高 = 3 行**（由 [gridMaxHeight] 从行数推导，不是写死像素）
       *
       * 为什么限高：500 集的剧会有 24 行，不限高会把
       * 「片头片尾 / 线路 / 操作提示」全挤到屏幕外。
       *
       * 为什么是 3 行：再多就把下面的内容推出首屏了。
       * 腾讯用 440px（约 6 行），那是在**播放器内浮层**里，
       * 而我们的选集区在页面流里，必须更克制。
       */
      constraints: BoxConstraints(maxHeight: gridMaxHeight()),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          clipBehavior: Clip.antiAlias,
          controller: _controller,
          child: LayoutBuilder(
            builder: (context, c) {
              /*
               * ★ 复刻 CSS `repeat(auto-fill, minmax(84px, 1fr))`
               *
               * # 为什么必须用 `1fr` 拉伸，不能每格固定 84px
               *
               * 固定 84px 时右侧会留一条**参差不齐的空档**：
               * ```text
               * 容器 800px，84 + 6 一格 → 每行放 8 个（用掉 714px）
               *   → 右边空 86px，比一个格子还宽
               *   → 视觉上像"网格没对齐"，而 CSS 的 1fr 会把
               *     这 86px 均分给 8 个格子（每格 94.75px）
               * ```
               * 这正是原版 `minmax(84px, 1fr)` 里 `1fr` 的作用 ——
               * **84 是下限，不是定值**。
               */
              final cols = gridColumns(c.maxWidth);
              final cellW = gridCellWidth(c.maxWidth, cols);

              return Wrap(
                spacing: _kGridGap,
                runSpacing: _kGridGap,
                children: [
                  for (var i = 0; i < widget.episodes.length; i++)
                    _EpisodeChip(
                      key: _keys.putIfAbsent(i, () => GlobalKey()),
                      episode: widget.episodes[i],
                      active: i == widget.currentIndex,
                      // ★ 1fr 均分后的实际宽度（不是 _kCellTarget 那个下限）
                      fixedWidth: cellW,
                      // ★ 定高 —— 保证「3 行」这个限高是真的（否则露半行）
                      fixedHeight: _kGridCellH,
                      // 网格是方角（原版 `.epstrip--grid .epstrip__btn`
                      // 的 `border-radius: var(--r-sm)`），横向条才是胶囊
                      pill: false,
                      onTap: () => widget.onPick(widget.episodes[i]),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  单集胶囊
// ═══════════════════════════════════════════════════════════════════════

/// 单集的按钮（横向条里是胶囊，网格/面板里是方角格）
class _EpisodeChip extends StatefulWidget {
  const _EpisodeChip({
    super.key,
    required this.episode,
    required this.active,
    required this.onTap,
    this.fixedWidth,
    this.fixedHeight,
    this.focusNode,
    this.pill = true,
  });

  final Episode episode;
  final bool active;
  final VoidCallback onTap;

  /// 网格形态下固定宽度（横向条形态为 null = 按内容宽）
  final double? fixedWidth;

  /// 网格形态下固定高度（横向条形态为 null = 按内容高）
  ///
  /// ⚠️ 网格**必须**定高，否则 [gridMaxHeight] 算出来的「3 行」
  ///    与实际渲染的行高对不上 —— 会露出**半行**（最难看的一种）。
  ///    横向条不定高：那里宽度由内容决定，高度本来就齐。
  final double? fixedHeight;

  /// TV 上由父级持有（要做"主动把焦点放到当前集"）
  final FocusNode? focusNode;

  /// true = 胶囊（横向条）；false = 方角（网格 / 弹出面板）
  final bool pill;

  @override
  State<_EpisodeChip> createState() => _EpisodeChipState();
}

class _EpisodeChipState extends State<_EpisodeChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;
    final radius = widget.pill ? Radii.rFull : Radii.rSm;

    final chip = Material(
      color: widget.active
          ? colors.primary
          : colors.secondary.withValues(alpha: 0.55),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        focusNode: widget.focusNode,
        /*
         * ★ TV 焦点态（2026-09-24）
         *
         * 遥控器上**没有鼠标悬停**，焦点是唯一的位置指示
         * （见 `device.dart` 的 `needsFocusRing`）。
         * 没有它，用户按方向键完全不知道现在停在哪一集。
         */
        onFocusChange: (f) {
          if (mounted && f != _focused) setState(() => _focused = f);
        },
        onTap: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: Sp.x3,
            // 网格/面板的格子更高一点（原版 7px→9px），
            // 因为方角格看起来比胶囊"矮"
            vertical: widget.pill ? 7 : 9,
          ),
          child: Center(
            child: Text(
              widget.episode.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.sm,
                fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                // 选中态是**实心品牌色 + 白字**（与底栏药丸同一个原则：
                // 「选中」的主信号是**底色**，不是文字亮度）
                color: widget.active
                    ? colors.primaryForeground
                    : colors.foreground,
              ),
            ),
          ),
        ),
      ),
    );

    // 宽/高各自可选（网格两个都定；横向条两个都不定）
    Widget sized = chip;
    if (widget.fixedWidth != null || widget.fixedHeight != null) {
      sized = SizedBox(
        width: widget.fixedWidth,
        height: widget.fixedHeight,
        child: chip,
      );
    }

    // 触摸端没有焦点环这回事 —— 不包一层，保持控件树简单
    if (!Device.needsFocusRing) return sized;

    /*
     * ⚠️ 焦点环用 `foregroundDecoration` 画在**内容之上**
     *
     * 不能用 `Container(border:)` —— 那会**改变尺寸**（宽高各 +4），
     * 焦点一移动整行就跳动。`foregroundDecoration` 不参与布局，
     * 只画。原版 CSS 也是这个思路：
     * ```css
     * outline: 2px solid transparent;  /* 用 outline 不用 border ——
     *                                    避免焦点态改布局 */
     * ```
     */
    return AnimatedContainer(
      duration: Motion.fast,
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: _focused ? colors.primary : Colors.transparent,
          width: _kFocusRingWidth,
        ),
      ),
      child: sized,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  「展开全部」箭头
// ═══════════════════════════════════════════════════════════════════════

/// 「展开全部」箭头（**仅手机/TV**，集数超阈值时出现）
///
/// 照抄原版 `.epstrip__more`：数字 + 向下箭头，
/// 底色比普通按钮**更亮一层**（`--surface-2` vs `--surface-1`），
/// 暗示"这里还有更多"。
class _MoreButton extends StatefulWidget {
  const _MoreButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  State<_MoreButton> createState() => _MoreButtonState();
}

class _MoreButtonState extends State<_MoreButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;

    final body = Material(
      color: colors.secondary.withValues(alpha: 0.55),
      borderRadius: Radii.rFull,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onFocusChange: (f) {
          if (mounted && f != _focused) setState(() => _focused = f);
        },
        onTap: widget.onTap,
        child: SizedBox(
          height: _kChipH,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${widget.count}',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.foreground,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: colors.foreground,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final ringed = Device.needsFocusRing
        ? AnimatedContainer(
            duration: Motion.fast,
            foregroundDecoration: BoxDecoration(
              borderRadius: Radii.rFull,
              border: Border.all(
                color: _focused ? colors.primary : Colors.transparent,
                width: _kFocusRingWidth,
              ),
            ),
            child: body,
          )
        : body;

    return Tooltip(message: '展开全部 ${widget.count} 集', child: ringed);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  完整选集面板 —— 「选集」按钮点开后的东西
// ═══════════════════════════════════════════════════════════════════════

/// 让选集面板**关闭时也有动画**（task-28 ①-A）
///
/// ══════════════════════════════════════════════════════════════════════
/// 用户原话
/// ══════════════════════════════════════════════════════════════════════
///
/// > 选集弹窗**关闭的时候没有动画效果**
///
/// # 为什么原来"打开有动画、关闭没有"（根因）
///
/// 面板的**进入**动画在 `EpisodeSheet` 内部（`TweenAnimationBuilder`
/// 从 24 → 0 滑入）—— 它在**首次挂载**时跑一次。
///
/// 而**关闭**是调用方这样写的（`player_page.dart`）：
/// ```dart
/// if (_episodeSheetOpen)
///   Positioned.fill(child: EpisodePanel(...))
/// ```
/// `_episodeSheetOpen = false` 的那一刻，**整个子树被直接移除** ——
/// 没有任何机会跑动画，于是表现为"啪一下消失"。
///
/// ★ 这是 `if (flag) Widget(...)` 这种写法的通病：
///   它只有"在"和"不在"两态，**没有"正在离开"这一态**。
///
/// # 这个宿主补的就是"正在离开"那一态
///
/// ```text
/// visible = true   → 挂载子组件（子组件自己的滑入动画照旧跑）
/// visible = false  → ★ 子组件**继续留在树上**，宿主驱动滑出 + 淡出
///                    动画跑完才真正卸载
/// ```
///
/// # ★ 为什么宿主**不**接管"进入"动画（否则会双重动画）
///
/// 子组件内部已经有 `TweenAnimationBuilder`（24 → 0）。
/// 如果宿主在进入时也做一次位移动画，用户会看到**两段叠加的滑动**
///（位移被算了两遍），比没有动画更糟。
///
/// 所以分工是：
/// ```text
/// 进入 → 子组件自己的 TweenAnimationBuilder（既有实现，一个字没改）
/// 退出 → ★ 宿主（本次新增）
/// ```
/// 宿主在 `visible` 变 true 时直接把控制器置 **1.0（= 恒等变换）**，
/// 不产生任何位移/透明度变化，把进入动画完全让给子组件。
///
/// # ★ 退出动画期间**必须不吃点击**
///
/// 面板正在消失时，用户点的应该是**下面的东西**（播放器）。
/// 如果这层还挡着，用户会觉得"点了没反应"，然后连点好几次。
/// ⇒ 退出期间套 `IgnorePointer`。
///
/// ⚠️ 这与"动画期间不能阻断交互"是同一条要求的两面：
///    进入时**要**能交互（面板已经在了），退出时**不能**。
class SheetTransition extends StatefulWidget {
  const SheetTransition({
    super.key,
    required this.visible,
    required this.child,
    this.slideFrom = const Offset(24, 0),
    this.duration = Motion.base,
    this.curve = Motion.easeOut,
  });

  /// true = 显示；false = **播放退出动画**然后卸载
  final bool visible;

  final Widget child;

  /// 退出时**往哪个方向滑走**（相对位移，单位逻辑像素）
  ///
  /// ```text
  /// Offset(24, 0)   右侧抽屉（PC）→ 往右滑出
  /// Offset(0, 24)   底部抽屉（手机）→ 往下滑出
  /// ```
  /// ★ 必须与面板的**进入方向**一致 —— 否则"从右边进来、往下面出去"
  ///   会让用户觉得东西被甩飞了。
  final Offset slideFrom;

  final Duration duration;
  final Curve curve;

  @override
  State<SheetTransition> createState() => _SheetTransitionState();
}

class _SheetTransitionState extends State<SheetTransition>
    with SingleTickerProviderStateMixin {
  /// 退出动画的进度：1.0 = 完全在位，0.0 = 完全滑走
  ///
  /// ⚠️ 初值取 `visible ? 1.0 : 0.0` —— 若一上来就 `visible: false`，
  ///    不能先闪一帧动画再消失。
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.visible ? 1.0 : 0.0,
  );

  /// 子组件是否还留在树上
  ///
  /// 与 `widget.visible` 的区别：退出动画期间
  /// `visible == false` 但 `_mounted == true`（这正是"正在离开"那一态）。
  late bool _mounted = widget.visible;

  @override
  void didUpdateWidget(covariant SheetTransition old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;

    if (widget.visible) {
      /*
       * 进入：宿主**不做动画**（见类文档"为什么宿主不接管进入动画"）。
       *
       * ⚠️ 直接赋 `value = 1.0`（而不是 `forward()`）——
       *    `forward()` 会从当前值跑到 1.0，那正是"双重动画"的来源。
       */
      _c.value = 1.0;
      setState(() => _mounted = true);
    } else {
      // 退出：宿主接管 —— 反向跑到 0，跑完才卸载
      _c.reverse().whenComplete(() {
        // ⚠️ 必须判 `mounted`：动画期间 widget 可能已被销毁
        //    （例如用户连按两次 Esc 直接退了播放页）
        if (mounted) setState(() => _mounted = false);
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 完全不在（既不可见、也不在播退出动画）
    if (!_mounted) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // clamp 是防御：`reverse()` 期间数值理论上在 [0,1]，
        // 但曲线可能产生极轻微越界（某些 Curve 实现会），
        // 而 `Opacity` 对越界值会**断言失败**。
        final t = widget.curve.transform(_c.value).clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            // t = 1 → 位移 0（在位）；t = 0 → 位移 = slideFrom（完全滑走）
            offset: Offset(
              widget.slideFrom.dx * (1 - t),
              widget.slideFrom.dy * (1 - t),
            ),
            child: child,
          ),
        );
      },
      child: IgnorePointer(
        // ★ 退出期间不吃点击（见类文档"退出动画期间必须不吃点击"）
        ignoring: !widget.visible,
        child: widget.child,
      ),
    );
  }
}

/// 「选集」按钮点开的面板 —— **按端分流**（三端两种层数）
///
/// ```text
/// 桌面      直接 = 居中二维网格弹窗（一屏看几十集，内部滚动）
/// 手机 / TV ① 选集条（显示前 20 集 + 箭头）
///           ② 点箭头 → 从底部弹出完整网格（分卷）
/// ```
///
/// # ⚠️ 为什么桌面**不是**"什么都不弹"
///
/// 原版 `PlayerView.vue` 是这么写的：
/// ```html
/// <EpisodeSheet v-if="episodeSheetOpen && !isDesktop" />
/// ```
/// 因为原版桌面的选集区**就在页面流里**（`EpisodeStrip` 的限高网格），
/// 滚动就能看全，再弹一个是双重隐藏。
///
/// 但我们的播放页是**沉浸式**的：`EpisodeStrip` 没有放在页面流里，
/// 「选集」按钮是**唯一**的选集入口（见 `player_page.dart` 里
/// `_BottomBar` 的 `onEpisodes`）。如果桌面点了不弹东西，
/// 那就等于**桌面上没有选集功能** —— 这违反硬指标①。
///
/// 所以这里保留一个桌面形态，但形态照原版的设计表走：
/// **二维网格**（鼠标 + 滚轮），而不是手机那种横向一行。
///
/// # ⚠️ 手机/TV 与原版的**一处交互差异**（必须单列说明）
///
/// ```text
/// 原版   选集条**常驻**在视频下方（页面流里）→ 点箭头 → 弹出完整面板
/// 我们   点「选集」→ 出「选集条 + 箭头」→ 点箭头 → 弹出完整面板
/// ```
/// **差异 = 手机/TV 上多一次点击。**
///
/// 原因是硬性的：我们的播放页是**沉浸式**的（画面铺满整屏、
/// 控制条自动隐藏），**没有页面流**可以常驻那条选集条。
/// 在沉浸式布局里常驻一条选集条 = 永久遮挡画面。
///
/// 但**形态与因果链完全一致** —— 用户看到的仍然是
/// 「一行集数 + 一个箭头 → 点箭头从下面弹出完整面板」，
/// 与原版 Owner 描述的操作序列逐字对应。
///
/// 桌面**不受影响**（桌面本来就没有这一层）。
class EpisodePanel extends StatefulWidget {
  const EpisodePanel({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
    required this.onClose,
    this.chunkSize = kEpisodeChunkSize,
    this.isDesktopOverride,
  });

  final List<Episode> episodes;
  final int currentIndex;
  final void Function(Episode) onPick;
  final VoidCallback onClose;
  final int chunkSize;

  /// 测试用：强制形态（生产不传 —— 见 `EpisodeStrip.isDesktopOverride`）
  final bool? isDesktopOverride;

  @override
  State<EpisodePanel> createState() => _EpisodePanelState();
}

class _EpisodePanelState extends State<EpisodePanel> {
  /// 手机 / TV：是否已点箭头、进到「完整面板」那一层
  ///
  /// ```text
  /// false → 选集条（显示一部分 + 箭头）    ← Owner：「一般是显示一部分」
  /// true  → 完整网格面板（分卷）           ← Owner：「点击一下，从下面弹出来」
  /// ```
  /// 桌面**永远**是 false（桌面根本不显示箭头，见文件头说明）。
  bool _expanded = false;

  EpisodeSheet _sheet({
    required bool asDialog,
    EpisodePanelStyle style = EpisodePanelStyle.bottomSheet,
  }) => EpisodeSheet(
    episodes: widget.episodes,
    currentIndex: widget.currentIndex,
    onPick: widget.onPick,
    onClose: widget.onClose,
    chunkSize: widget.chunkSize,
    asDialog: asDialog,
    style: style,
  );

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktopOverride ?? Device.isDesktop;

    // ── 桌面：右侧抽屉 + 搜索（**没有箭头、没有第二层**）──
    //
    // ⚠️ 桌面不做「显示一部分 + 箭头」是有原因的，不是漏了：
    //    桌面网格本身就能内部滚动，再套一层折叠 = **双重隐藏**
    //    （用户要先滚再点箭头），反而更绕。
    //    腾讯 PC 播放页也没有折叠 —— 见文件头的实测 DOM 数据。
    //
    // ★ 2026-09-25 任务㉑⑪：形态从"居中弹窗"改成**右侧抽屉**（用户要求）。
    if (isDesktop) {
      return _sheet(asDialog: true, style: EpisodePanelStyle.rightDrawer);
    }

    // ── 手机 / TV：两层 ──
    if (_expanded) {
      return _EscLayer(
        onBack: () => setState(() => _expanded = false),
        child: _sheet(asDialog: false, style: EpisodePanelStyle.bottomSheet),
      );
    }

    return _StripDrawer(
      episodes: widget.episodes,
      currentIndex: widget.currentIndex,
      onPick: widget.onPick,
      onClose: widget.onClose,
      onExpand: () => setState(() => _expanded = true),
      // ★ 形态判定要**传下去**（测试用 override 时才不会串形态）
      isDesktopOverride: widget.isDesktopOverride,
    );
  }
}

/// 拦住「返回键」并把它降成**上一层**（而不是直接关掉整个面板）
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 为什么需要这个（这是「与原版保持一致」的一步，不是额外功能）
/// ══════════════════════════════════════════════════════════════════════
///
/// 原版的层级与返回行为：
/// ```text
/// 选集条（**常驻在页面流里**） → 点箭头 → EpisodeSheet（弹出层）
/// 弹出层里按 Esc → 只关弹出层 → 用户**看到选集条还在**
/// ```
/// 因为原版的条是常驻的，关掉 sheet 之后用户自然回到"有条的那一屏"。
///
/// 我们的条是**第一层弹层**（沉浸式布局没有页面流可常驻，见
/// `EpisodePanel` 的差异说明）。如果 Esc 直接关掉整个面板，用户就
/// **直接回到播放器**了 —— 相当于"一次退两层"，比原版突兀。
///
/// 所以这里让 Esc 退**一层**：完整面板 → 选集条。
/// 再按一次 Esc（这一层已不在）才由播放页关掉整个面板 —— 与原版
/// 「Esc 关掉最上面那层」的语义逐层对应。
///
/// # 为什么用 `Focus` 包一层（而不是给每个格子加 onKeyEvent）
///
/// Flutter 的按键派发是**从叶子往根走**（`FocusManager` 遍历
/// `primaryFocus.ancestors`）。所以把这个 `Focus` 放在面板**外面**
/// 就一定能收到 —— 不管当前焦点在哪个格子上。
///
/// ⚠️ `canRequestFocus: false` + `skipTraversal: true`：
///    它只**转发**按键，绝不参与焦点移动（否则空间导航会多出一个
///    看不见的候选，用户按方向键会"停在一个没东西的地方"）。
class _EscLayer extends StatelessWidget {
  const _EscLayer({required this.onBack, required this.child});

  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
          onBack();
          // handled = 别让播放页把整个面板也一起关了（那就是退两层）
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  「显示一部分」那一层 —— 选集条 + 箭头
// ═══════════════════════════════════════════════════════════════════════

/// 手机 / TV 的**第一层**面板：只有一条选集条 + （集数多时的）箭头
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 这一层是什么、为什么必须单独存在
/// ══════════════════════════════════════════════════════════════════════
///
/// Owner 原话：
/// > 这个集数也不能无限显示下去，一般是**显示一部分**，然后如果集数多，
/// > 就有个**小箭头**，点击一下，从下面弹出来选择集数
///
/// 原版里 `EpisodeStrip` 是**常驻在页面流里**的（视频下方），
/// 箭头是它自带的一部分；点箭头才挂载 `EpisodeSheet`。
///
/// 但我们的播放页是**沉浸式**的（没有页面流，画面铺满整屏），
/// 所以「常驻的选集条」没有地方放 —— 改成：**点「选集」先出这一层**。
///
/// ```text
/// 原版   视频下方常驻选集条 → 点箭头 → EpisodeSheet
/// 我们   点「选集」 → 这一层（= 选集条）→ 点箭头 → EpisodeSheet
/// ```
///
/// ⚠️ **形态与触发关系与原版逐字一致**（同样是「条 + 箭头 → 从下面弹出」），
///    只有「条是不是常驻」这一点受沉浸式布局所限而不同。
///    代价：手机/TV 上比原版**多一次点击**（原版那次点击是"看向下方"）。
///    详见 EpisodePanel 的交互差异说明。
///
/// # 为什么集数 ≤ 20 时这一层就是全部
///
/// 不折叠就不出箭头，用户直接把这一行点完就行 —— 不需要第二层。
/// 这与原版 `collapsed = episodes.length > collapseAfter` 完全一致。
class _StripDrawer extends StatelessWidget {
  const _StripDrawer({
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
    required this.onClose,
    required this.onExpand,
    this.isDesktopOverride,
  });

  final List<Episode> episodes;
  final int currentIndex;
  final void Function(Episode) onPick;
  final VoidCallback onClose;
  final VoidCallback onExpand;

  /// ⚠️ 必须**透传**给里面的 `EpisodeStrip` —— 否则测试用
  ///    `isDesktopOverride: false` 打开手机形态面板时，
  ///    里面那条会按**真实设备**（桌面）画成网格，
  ///    于是「手机面板」里出现一个桌面网格（我第一版就是这样，
  ///    被 ⑨ 组那条端到端断言当场抓住）。
  final bool? isDesktopOverride;

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;
    final screen = MediaQuery.of(context).size;

    // 当前集标题（原版 `flow__meta`：「N 集 · 正在播 第X集」）
    final cur = currentIndex >= 0 && currentIndex < episodes.length
        ? episodes[currentIndex].title
        : null;

    final card = Container(
      width: math.min(920, screen.width),
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: colors.card,
        // 底部抽屉：只有上方两角圆（它贴着屏幕底边）—— 与 EpisodeSheet 同款
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.lg),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '选集',
                style: TextStyle(
                  fontSize: FontSizes.lg,
                  fontWeight: FontWeight.w600,
                  color: colors.foreground,
                ),
              ),
              const SizedBox(width: Sp.x2),
              // 这一行是「显示一部分」的**说明**：用户得知道一共多少集
              Flexible(
                child: Text(
                  '${episodes.length} 集${cur == null ? '' : ' · 正在播 $cur'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.mutedForeground,
                  ),
                ),
              ),
              const Spacer(),
              _SheetIconButton(
                icon: Icons.close,
                tooltip: '关闭',
                onTap: onClose,
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          EpisodeStrip(
            episodes: episodes,
            currentIndex: currentIndex,
            onPick: onPick,
            // ★ 箭头 → 第二层（完整面板）。形态判据由 EpisodeStrip 自己出，
            //   这里**不重复**判断"是不是桌面" —— 重复就会漂移。
            onExpand: onExpand,
            isDesktopOverride: isDesktopOverride,
          ),
        ],
      ),
    );

    /*
     * ★ task-99：这一层原来也是「遮罩硬切 + 卡片硬闪」（只有位移），
     *   与 EpisodeSheet 同一个毛病 —— 现在两处共用同一套入场动效。
     *
     * ⚠️ 颜色/覆盖范围/对齐一字不改：动画结束后 Opacity 恒为 1.0、
     *   Transform 的 offset 恒为 (0,0) ⇒ 几何与改前逐像素一致。
     */
    return OverlayScrim(
      color: Colors.black.withValues(alpha: 0.5),
      child: GestureDetector(
        // 点背景关闭（与 EpisodeSheet 一致）
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Align(
          // ★ 底边对齐 —— 「从下面弹出来」是 Owner 的形态要求
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            // 吞掉面板内部的点击，别穿透到背景把自己关掉
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            // ★ 底部抽屉 ⇒ 从下方上浮 24px（与 EpisodeSheet 的底部形态一致）
            child: OverlayCardMotion(child: card),
          ),
        ),
      ),
    );
  }
}

/// 完整选集面板 —— 手机/TV 从底部弹出，桌面是居中网格弹窗
///
/// 调用方把它放进 `Stack` 的 `Positioned.fill` 即可；
/// 本控件自己**不**用 `Positioned`（这样单测里能直接 pump）。
///
/// # 两种外壳，**同一套内容**
///
/// 分卷 / 网格 / 自动滚到当前集 / TV 焦点 —— 这些逻辑两种外壳完全一样，
/// 所以只有**外层装饰**分叉（`asDialog`），内容区一份代码。
///
/// # 关闭方式
///
/// ```text
/// 点背景 / 点右上角 X  → onClose
/// 遥控器「返回」(Esc)  → 由**播放页**的 _onKey 处理（它在本控件的
///                        焦点祖先链上，按键会冒泡上去）
/// ```
class EpisodeSheet extends StatefulWidget {
  const EpisodeSheet({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
    required this.onClose,
    this.chunkSize = kEpisodeChunkSize,
    this.asDialog = false,
    this.style = EpisodePanelStyle.bottomSheet,
  });

  /// true = 居中弹窗；false = 底部抽屉（手机 / TV）
  ///
  /// ⚠️ 保留这个字段是为了**不破坏既有调用点**（多个测试在用）。
  ///    新的形态判定应以 [style] 为准 —— 它更明确（见该枚举的说明）。
  final bool asDialog;

  /// 面板形态（★ 2026-09-25 任务㉑⑪ 新增）
  ///
  /// ```text
  /// rightDrawer  PC    → 贴右侧、限宽、全高
  /// bottomSheet  手机  → 贴底部、限高 72vh
  /// ```
  final EpisodePanelStyle style;

  final List<Episode> episodes;
  final int currentIndex;
  final void Function(Episode) onPick;
  final VoidCallback onClose;

  /// 每段多少集（超过就分段）
  final int chunkSize;

  @override
  State<EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<EpisodeSheet> {
  final _controller = ScrollController();
  final _keys = <int, GlobalKey>{};
  final _nodes = <int, FocusNode>{};

  /// 搜索关键词（空 = 不搜索）
  ///
  /// ★ 任务㉑⑪ 用户要求「支持搜索」。
  ///
  /// # 搜索与"分卷"的关系（这个决定很重要）
  ///
  /// ```text
  /// 不搜索时：只显示**当前卷**（1-100 / 101-200 …）
  /// 搜索时  ：显示**全部匹配项**（跨卷）
  /// ```
  /// 为什么搜索要跨卷：用户输入「237」的意图是"**找到那一集**"，
  /// 不是在"当前这 100 集里找"。如果只在当前卷里搜，
  /// 用户输 237 却什么都看不到（因为当前卷是 1-100），
  /// 会以为搜索坏了 —— 那是最糟的交互。
  ///
  /// ⚠️ 搜索结果同样走**非懒构建**的 `Wrap`（与分卷同一个理由，
  ///    见网格那段的长注释）：自动滚动要靠 `GlobalKey.currentContext`，
  ///    懒构建下当前集可能还没建出来，滚动会静默失效。
  String _query = '';
  final _queryCtrl = TextEditingController();

  /// 当前在第几段（0 基）
  int _chunk = 0;

  bool get _needsChunks => widget.episodes.length > widget.chunkSize;

  /// 集数够多**且设备支持输入**才显示搜索框
  ///
  /// ```text
  /// 集数 ≤ 30        → 不显示（12 集的剧摆个搜索框是噪音）
  /// TV（遥控器）    → 不显示  ← ★ 本次补的门控
  /// 手机 / PC     → 显示
  /// ```
  ///
  /// # ★ 为什么 TV 必须排除（实测发现的真缺口）
  ///
  /// 改之前这里**只看集数** —— 而手机和 TV 走的是**同一个**
  /// `EpisodeSheet(style: bottomSheet)`（见 `build` 里的分流），
  /// 所以“只给手机加、不给 TV 加”在原来的写法下**做不到**：
  /// ```text
  /// 120 集的 TV 会看到一个搜索框 ← 而遥控器打不了字
  /// ```
  /// 而且它比“少一个控件”**更糟**：`TextField` 会把方向键
  /// 吃成“移动光标”，TV 用户一旦把焦点落到它上，
  /// 遥控器就**选不了集**了 —— 比没有搜索框更难用。
  ///
  /// ★ 这也是本文件早就写下的设计承诺
  ///   （见 `test/episode_drawer_test.dart` 的三端说明：
  ///    “所以 TV 不加搜索框（遥控器输入文字体验极差）”）。
  ///   但那份承诺**一直没被代码兑现** —— 这里补上。
  ///
  /// ⚠️ 用 `Device.needsFocusRing`（= `isTv`）而不是 `!Device.isDesktop`：
  ///    后者会把**手机**也当成“不需要搜索”，而手机打字很方便。
  ///    这个判据在本文件已经用了 6 处（焦点环/回车键等），
  ///    沿用它不会引入第二套“什么算 TV”的判据。
  bool get _needsSearch =>
      widget.episodes.length > kEpisodeSearchAfter && !Device.needsFocusRing;

  int get _chunkCount =>
      (widget.episodes.length + widget.chunkSize - 1) ~/ widget.chunkSize;

  FocusNode _nodeFor(int i) =>
      _nodes.putIfAbsent(i, () => FocusNode(debugLabel: 'epsheet-$i'));

  @override
  void initState() {
    super.initState();
    /*
     * ★ 打开时**先定位到当前集所在的段**，再滚动
     *
     * ⚠️ 顺序不能反（原版注释：必须在 onMounted 之前算好）——
     *    否则会先渲染第 1 段（1-100），再跳段，用户看到闪一下。
     */
    if (_needsChunks && widget.currentIndex >= 0) {
      _chunk = widget.currentIndex ~/ widget.chunkSize;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrent();
      _focusCurrent();
    });
  }

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _queryCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 当前要显示的集下标
  ///
  /// ★ 2026-09-25 任务㉑⑪：加了搜索分支。
  ///
  /// ```text
  /// 有搜索词 → **跨卷**返回全部匹配项（用户意图是"找到那一集"）
  /// 无搜索词 → 只返回当前卷（1-100 / 101-200 …）
  /// ```
  /// ⚠️ 搜索结果**不排序、保持原顺序** ——
  ///    剧集顺序本身就是信息（第 3 集在第 5 集前面）。
  ///    按相关度重排会让"第 12 集"跑到"第 1 集"旁边，反而看不懂。
  List<int> get _shown {
    if (_query.isNotEmpty) {
      return [
        for (var i = 0; i < widget.episodes.length; i++)
          if (_matches(i)) i,
      ];
    }
    if (!_needsChunks) {
      return [for (var i = 0; i < widget.episodes.length; i++) i];
    }
    final start = _chunk * widget.chunkSize;
    final end = math.min(start + widget.chunkSize, widget.episodes.length);
    return [for (var i = start; i < end; i++) i];
  }

  /// 第 [i] 集是否匹配当前搜索词
  ///
  /// # 匹配范围（**三个都查**，因为用户想输入的可能是任意一个）
  ///
  /// ```text
  /// ① 集号          「12」→ 第 12 集        ← 最常用
  /// ② 标题          「预告」→ 标题含"预告"   ← 有意义的集名
  /// ③ 原始序号+1    兜底（`index` 字段可能是 0 基）
  /// ```
  /// ⚠️ 大小写不敏感 + 去首尾空格：用户不会精确输入。
  bool _matches(int i) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final ep = widget.episodes[i];
    // ① 集号（用户看到的编号就是 i+1，与 `_EpisodeChip` 的显示一致）
    if ('${i + 1}'.contains(q)) return true;
    // ② 标题
    if (ep.title.toLowerCase().contains(q)) return true;
    return false;
  }

  /// 把当前集滚进可视区（与选集条同一个要求）
  ///
  /// 面板里是**纵向**滚动（网格），与横向条的 `scrollLeft` 不同 ——
  /// 原版专门记过这个坑：
  /// > 一开始我两种形态都写 `scrollLeft` —— 在网格里那个值恒为 0，
  /// > 等于**完全没滚动**。
  ///
  /// ⚠️ 这里走 [gridScrollTarget]（不是 `Scrollable.ensureVisible`），
  ///    因为原版面板的 `scrollToCurrent` 也有一句
  ///    `if (br.top >= sr.top && br.bottom <= sr.bottom) return;`
  ///    —— **已可见就不动**。`ensureVisible(alignment: 0.5)` 没有这个语义，
  ///    会把已经看得见的当前集硬拽到视口正中。
  void _scrollToCurrent() {
    if (!mounted) return;

    final ctx = _keys[widget.currentIndex]?.currentContext;
    final geom = measureScrollGeom(
      itemContext: ctx,
      controller: _controller,
      axis: Axis.vertical,
    );
    if (geom == null) return;

    final target = gridScrollTarget(
      itemStart: geom.itemStart,
      itemExtent: geom.itemExtent,
      viewportExtent: geom.viewportExtent,
      contentExtent: geom.contentExtent,
      current: geom.current,
    );

    if ((target - _controller.position.pixels).abs() < 0.5) return;

    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// TV：把焦点放到当前集（没有当前集时放第一集）
  void _focusCurrent() {
    if (!mounted || !Device.needsFocusRing) return;
    final shown = _shown;
    if (shown.isEmpty) return;
    final target = shown.contains(widget.currentIndex)
        ? widget.currentIndex
        : shown.first;
    final n = _nodes[target];
    if (n != null && n.canRequestFocus) n.requestFocus();
  }

  /// 切段 —— 照抄原版：切完**滚到顶部**
  ///
  /// （原版 `switchChunk` 就是 `scrollTo({ top: 0 })`，
  ///  不是滚到当前集 —— 用户切段的目的就是"去看别的集"。）
  void _switchChunk(int i) {
    setState(() => _chunk = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.animateTo(0, duration: Motion.base, curve: Motion.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;
    final screen = MediaQuery.of(context).size;
    final shown = _shown;

    final isDrawer = widget.style == EpisodePanelStyle.rightDrawer;

    final box = Container(
      /*
       * ★ 宽度按形态分（2026-09-25 任务㉑⑪）
       *
       * ```text
       * 右侧抽屉（PC）  min(380, 100%)   ← 贴右边，不挡画面主体
       * 底部抽屉（手机）min(920, 100%)   ← 原版值；底部横条可以宽
       * ```
       * ⚠️ 抽屉不能太宽：太宽就等于回到"居中弹窗挡画面"了。
       *    380 是"一屏 4 列集号胶囊"的宽度（4×84 + 间距 + padding），
       *    再窄会挤成 3 列、再宽就开始挡主体。
       */
      width: isDrawer
          ? math.min(380, screen.width)
          : math.min(920, screen.width),
      /*
       * ★ 高度按形态分
       *
       * ```text
       * 右侧抽屉（PC）  **全高** —— 贴满上下，像一个真正的侧栏
       * 底部抽屉（手机）max-height: min(72vh, 640px)（原版值）
       * ```
       * ⚠️ 手机用比例而不是固定值：小屏要避开底部手势条，
       *    所以按 72% 收缩，大屏才用 640 封顶。
       * ⚠️ 抽屉用全高：右侧抽屉如果只有半高，上面会露出一块播放画面，
       *    视觉上很碎（侧栏应该是"从顶到底的一整条"）。
       */
      height: isDrawer ? screen.height : null,
      constraints: isDrawer
          ? null
          : BoxConstraints(maxHeight: math.min(screen.height * 0.72, 640)),
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: colors.card,
        /*
         * 圆角按外壳分：
         * ```text
         * 底部抽屉（手机/TV） 只有上方两角圆 —— 它贴着屏幕底边
         * 右侧抽屉（PC）     只有**左侧**两角圆 —— 它贴着屏幕右边
         * ```
         * 原版 `.epsheet__box { border-radius: var(--r-lg) var(--r-lg) 0 0 }`
         */
        borderRadius: isDrawer
            ? const BorderRadius.horizontal(left: Radius.circular(Radii.lg))
            : (widget.asDialog
                  ? BorderRadius.circular(Radii.lg)
                  : const BorderRadius.vertical(
                      top: Radius.circular(Radii.lg),
                    )),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 头：标题 + 总数 + 关闭 ──
          Row(
            children: [
              Text(
                '选集',
                style: TextStyle(
                  fontSize: FontSizes.lg,
                  fontWeight: FontWeight.w600,
                  color: colors.foreground,
                ),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                '${widget.episodes.length} 集',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.mutedForeground,
                ),
              ),
              const Spacer(),
              _SheetIconButton(
                icon: Icons.close,
                tooltip: '关闭',
                onTap: widget.onClose,
              ),
            ],
          ),

          // ── 搜索框（只在集数够多时出现）──
          //
          // ★ 任务㉑⑪ 用户要求「支持搜索」。
          //
          // ⚠️ 阈值 `kEpisodeSearchAfter`(30) 与折叠箭头(20) **不同**，
          //    是有意的：箭头解决"放不下"，搜索解决"找不到"。
          if (_needsSearch) ...[
            const SizedBox(height: Sp.x3),
            _EpisodeSearchField(
              controller: _queryCtrl,
              onChanged: (v) => setState(() {
                _query = v;
                // 搜索时把滚动位置归零 —— 否则结果换了但视口还停在旧位置，
                // 看起来像"搜索没生效"（结果其实在上面）
                if (_controller.hasClients) _controller.jumpTo(0);
              }),
              hint: '搜索集数或标题',
              onClear: () {
                _queryCtrl.clear();
                setState(() => _query = '');
              },
            ),
            // 搜索结果计数（让用户知道"搜到了几集"）
            if (_query.isNotEmpty) ...[
              const SizedBox(height: Sp.x2),
              Text(
                '匹配 ${shown.length} 集'
                '${shown.isEmpty ? "（换个关键词试试）" : ""}',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: shown.isEmpty ? colors.error : colors.mutedForeground,
                ),
              ),
            ],
          ],

          // ── 分段（只在集数极多时出现）──
          //
          // ⚠️ 搜索时**隐藏分卷** —— 搜索结果已经是跨卷的，
          //    再摆一排分卷按钮会让人误以为"分卷还能进一步过滤"。
          if (_needsChunks && _query.isEmpty) ...[
            const SizedBox(height: Sp.x2),
            /*
             * ★★★ 必须**换行**，不能用横向 `ListView`
             *
             * 原版 `.epsheet__chunks` 的实测 CSS 是：
             * ```css
             * .epsheet__chunks {
             *   display: flex; gap: 5px;
             *   flex-wrap: **wrap**;      ← ★ 换行
             *   border-bottom: 1px solid var(--divider);
             * }
             * ```
             * 我上一版写的是横向 `ListView` —— 500 集有 5 个分段按钮
             * （`1-100` … `401-500`），窄屏上第 5 个被**截在屏幕外**，
             * 用户**点不到最后一卷**（而且横向 ListView 没有可见滚动条，
             * 完全看不出来"右边还有"）。这是端到端断言当场抓到的。
             *
             * 换成 `Wrap` 后：一行放不下就换行，**每一卷都看得见、点得到**。
             * 500 集也才 5 个按钮，换行最多两行，代价可忽略。
             *
             * ⚠️ 这里同时解释了为什么面板里用 `Wrap` 而**不**用懒构建 ——
             *    与集数网格同一个理由（`GlobalKey.currentContext`
             *    在懒构建下会拿不到，自动滚动静默失效）。
             */
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (var i = 0; i < _chunkCount; i++)
                  _ChunkPill(
                    label:
                        '${i * widget.chunkSize + 1}-'
                        '${math.min((i + 1) * widget.chunkSize, widget.episodes.length)}',
                    active: i == _chunk,
                    onTap: () => _switchChunk(i),
                  ),
              ],
            ),
          ],

          const SizedBox(height: Sp.x3),

          // ── 集数网格 ──
          Flexible(
            child: LayoutBuilder(
              builder: (context, c) {
                /*
                 * 复刻原版 CSS `grid-template-columns:
                 * repeat(auto-fill, minmax(84px, 1fr))`：
                 * 先算"能放几列"，再把剩余宽度均分给每一列。
                 *
                 * ⚠️ 走 [gridColumns] / [gridCellWidth] 这两个**纯函数** ——
                 *    与桌面网格共用同一份算式。写两遍的话两边会漂移，
                 *    而测试只能钉住其中一份（另一份错了测不出来）。
                 *
                 * ⚠️ 为什么不用 `GridView`：`GridView` 是**懒构建**的，
                 *    而自动滚动要靠 `GlobalKey.currentContext` ——
                 *    当前集在第 87 集时它还没被构建，滚动就静默失效
                 *    （与横向条同一个坑，见那边的说明）。
                 *    单段最多 100 个格子，全建出来完全可接受。
                 */
                final cols = gridColumns(c.maxWidth);
                final itemW = gridCellWidth(c.maxWidth, cols);

                return SingleChildScrollView(
                  clipBehavior: Clip.antiAlias,
                  controller: _controller,
                  child: Wrap(
                    spacing: _kGridGap,
                    runSpacing: _kGridGap,
                    children: [
                      for (final i in shown)
                        SizedBox(
                          width: itemW,
                          child: _EpisodeChip(
                            key: _keys.putIfAbsent(i, () => GlobalKey()),
                            focusNode: _nodeFor(i),
                            episode: widget.episodes[i],
                            active: i == widget.currentIndex,
                            // 面板里是方角格（原版 `.epsheet__btn`
                            // 的 `border-radius: var(--r-sm)`）
                            pill: false,
                            onTap: () => widget.onPick(widget.episodes[i]),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    /*
     * ★ task-99：原来这里的遮罩是**硬切**的 —— 它（`ColoredBox`）在
     *   `TweenAnimationBuilder` **之外**，所以卡片在淡入/平移时，
     *   黑幕是「啪」一下出现的。现在遮罩也走同一个补间。
     */
    return OverlayScrim(
      // 原版 `background: rgb(0 0 0 / 0.5)`
      color: Colors.black.withValues(alpha: 0.5),
      child: GestureDetector(
        // 点背景关闭（原版 `@click.self="emit('close')"`）
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Align(
          /*
           * ★ 三种外壳的对齐（2026-09-25 任务㉑⑪）
           *
           * ```text
           * 右侧抽屉（PC）   centerRight   ← 贴右边滑出
           * 底部抽屉（手机） bottomCenter  ← 从下面弹出
           * 居中弹窗        center        ← 旧的桌面形态（保留兼容）
           * ```
           * ⚠️ 原版注释说"桌面用居中而不是底部：鼠标从屏幕底部往中间找
           *    弹窗比去最下面少一半移动距离" —— 那个理由对**居中弹窗**
           *    成立，但用户明确要求 PC 用**右侧抽屉**，所以现在 PC 走
           *    centerRight。右侧抽屉的移动距离同样短（鼠标常在右侧），
           *    而且不挡画面主体。
           */
          alignment: isDrawer
              ? Alignment.centerRight
              : (widget.asDialog ? Alignment.center : Alignment.bottomCenter),
          child: GestureDetector(
            // 吞掉面板内部的点击，别穿透到背景把自己关掉
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            /*
             * 原版 `@keyframes sheetUp`：从下方滑入 24px。
             * 这是**观感**，交互（点哪关、点哪选）完全不变。
             *
             * ★ 右侧抽屉改成**从右滑入** —— 方向要跟外壳一致，
             *   否则"右侧的抽屉从下面钻出来"会很怪。
             */
            /*
             * ★ task-99：改用共享的 `OverlayCardMotion`。
             *
             * 改前这里**只有位移、没有透明度**（卡片是「硬闪 + 平移」），
             * 而且桌面 `asDialog` 那一支的 begin 是 **0** ⇒
             * **完全没有入场动画**。现在三支统一：淡入 + 24px 位移。
             *
             * ⚠️ 位移方向必须与**实际几何**一致（`SheetTransition` 的契约）：
             *    右侧抽屉 → 从右滑入；底部/居中 → 从下方升起。
             *    桌面走的是 isDrawer 分支 ⇒ 仍是横向，与改前一致。
             */
            child: OverlayCardMotion(
              slideFrom: isDrawer ? const Offset(24, 0) : const Offset(0, 24),
              child: box,
            ),
          ),
        ),
      ),
    );
  }
}

/// 选集面板里的**搜索框**（任务㉑⑪ 用户要求）
///
/// # 为什么自己写一个而不是用 `TextField` 裸装
///
/// ```text
/// ① 要带"清除"按钮      —— 输了字发现搜错，得能一键清空
///     （手机上尤其重要：清空要按 6 次退格）
/// ② 要统一外观          —— 与面板的 card 底色/圆角语言一致
/// ③ 要返回 `onChanged`  —— 上层据此过滤（不在这里持有数据）
/// ```
/// ⚠️ 它是**纯展示 + 回调**，不持有过滤逻辑 ——
///    过滤在 `_EpisodeSheetState._shown` 里做（单一数据源）。
///
/// ⚠️ `onClear` 由上层传：本组件不直接操作 controller，
///    否则"清空"和"用户手动删空"会走两条不同的代码路径，
///    容易出现"清空了但没重新过滤"这种 bug。
class _EpisodeSearchField extends StatelessWidget {
  const _EpisodeSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.hint,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(fontSize: FontSizes.sm, color: colors.foreground),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: FontSizes.sm,
          color: colors.mutedForeground,
        ),
        prefixIcon: Icon(Icons.search, size: 16, color: colors.mutedForeground),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 15),
                tooltip: '清除',
                onPressed: onClear,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Sp.x2,
          vertical: Sp.x2,
        ),
        filled: true,
        fillColor: colors.background,
        border: OutlineInputBorder(
          borderRadius: Radii.rMd,
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.rMd,
          borderSide: BorderSide(color: colors.border),
        ),
      ),
    );
  }
}

/// 分段按钮（`1-100` / `101-200` …）
class _ChunkPill extends StatefulWidget {
  const _ChunkPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_ChunkPill> createState() => _ChunkPillState();
}

class _ChunkPillState extends State<_ChunkPill> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;

    final body = Material(
      color: widget.active
          ? colors.primary
          : colors.secondary.withValues(alpha: 0.55),
      borderRadius: Radii.rFull,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onFocusChange: (f) {
          if (mounted && f != _focused) setState(() => _focused = f);
        },
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 5),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: widget.active
                  ? colors.primaryForeground
                  : colors.foreground,
            ),
          ),
        ),
      ),
    );

    if (!Device.needsFocusRing) return body;
    return AnimatedContainer(
      duration: Motion.fast,
      foregroundDecoration: BoxDecoration(
        borderRadius: Radii.rFull,
        border: Border.all(
          color: _focused ? colors.primary : Colors.transparent,
          width: _kFocusRingWidth,
        ),
      ),
      child: body,
    );
  }
}

/// 面板头部的图标按钮（关闭）
class _SheetIconButton extends StatefulWidget {
  const _SheetIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_SheetIconButton> createState() => _SheetIconButtonState();
}

class _SheetIconButtonState extends State<_SheetIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = FTheme.of(context).colors;

    final body = Material(
      color: Colors.transparent,
      borderRadius: Radii.rSm,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onFocusChange: (f) {
          if (mounted && f != _focused) setState(() => _focused = f);
        },
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(widget.icon, size: 18, color: colors.mutedForeground),
        ),
      ),
    );

    final ringed = Device.needsFocusRing
        ? AnimatedContainer(
            duration: Motion.fast,
            foregroundDecoration: BoxDecoration(
              borderRadius: Radii.rSm,
              border: Border.all(
                color: _focused ? colors.primary : Colors.transparent,
                width: _kFocusRingWidth,
              ),
            ),
            child: body,
          )
        : body;

    return Tooltip(message: widget.tooltip, child: ringed);
  }
}
