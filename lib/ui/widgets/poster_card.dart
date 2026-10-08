// ═══════════════════════════════════════════════════════════════════════
//  海报卡片 —— 底座级通用组件（对齐原版 PosterCard.vue）
// ═══════════════════════════════════════════════════════════════════════
//
// 只吃领域模型字段，**不认识任何平台**。接入新视频站无需改动。
//
// # ★★ 图片加载策略（避免「白图闪烁」）
//
// 原版三个状态：
// ```text
// 已缓存    → 直接显示，不做淡入（图已在缓存里，再淡入是多余噪声）
// 首次加载  → 先显示占位底色，加载完淡入
// 加载失败  → 显示首字占位，不留破图
// ```
//
// # ★ 关于原版的 `referrerpolicy="no-referrer"`
//
// 原版注释（真实 bug，2026-09-20 实测）：
// > 不带 Referer → HTTP 200 ✅
// > 带 http://localhost:1420/ → HTTP 403 ★
// > 带 http://tauri.localhost/ → HTTP 403 ★
//
// 那是 **WebView2 特有的问题** —— 浏览器会自动带上"当前页面地址"作为
// Referer，B站 CDN 拒绝 `tauri.localhost` 这类来源。
//
// **Flutter 没有这个问题**：`Image.network` 由 Dart 的 HTTP 客户端直接
// 发起请求，默认**不带 Referer**（没有"页面地址"这个概念）。
// 所以这里不需要对应的处理 —— 行为天然与"加了 no-referrer"一致。
//
// ⚠️ 但**防盗链的源**（需要特定 Referer 才给图）仍然会失败 ——
//    那种由核心层的封面代理解决（`proxy_covers`），
//    核心会把封面换成 `http://127.0.0.1:<port>/s/...` 并附上正确请求头。

import 'package:material_ui/material_ui.dart';

import '../../core/device.dart';
import '../tokens.dart';
import 'cover_image.dart';
import 'motion_prefs.dart';
import 'press_feedback.dart';

/// 海报卡片
///
/// ```dart
/// PosterCard(
///   title: item.title,
///   cover: item.cover,
///   subtitle: item.subtitle,
///   badge: item.badges?.firstOrNull,
///   onTap: () => openDetail(item),
/// )
/// ```
class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.cover,
    this.subtitle,
    this.badge,
    this.unread = 0,
    this.onTap,
    this.width,
    this.focused = false,
    this.titleLines = 1,
  }) : assert(titleLines >= 1, 'titleLines 至少 1 行');

  final String title;
  final String? cover;

  /// 副标题（如「更新至 12 集」）
  final String? subtitle;

  /// 右上角角标（如「1080P」「直播中」）
  final String? badge;

  /// 左上角未读数（追更场景）
  final int unread;

  final VoidCallback? onTap;

  /// 覆盖默认宽度（默认 [AppMetrics.posterWidth]）
  ///
  /// ⚠️ 只有**明确需要不同尺寸**时才传（如搜索结果用更小的卡）。
  ///    随手改会让每行卡片数与原版不一致。
  final double? width;

  /// TV 遥控聚焦态（画聚焦环）
  final bool focused;

  /// 标题最多显示几行（默认 1 —— 与历史行为**逐位相同**）
  ///
  /// ★ 原版 `base.css:844-854` 的 `.poster-meta__title` 是 `-webkit-line-clamp: 2`
  ///   —— **固定两行**，源码注释逐字：
  ///   `/* 固定两行：标题长短不一时卡片仍对齐（大厂列表的通用做法） */`
  ///   即：哪怕标题只有一行，也占两行的高度 ⇒ 一排卡片的底边永远齐。
  ///
  /// ⚠️ 传 2 时**必须同时**把承载高度一起放大，否则标题被裁、或在轨道里
  ///    溢出（`RenderFlex overflowed`）：
  ///   - 横向轨道 ⇒ `SizedBox(height: AppMetrics.railHeight(titleLines: 2))`
  ///   - 网格      ⇒ `childAspectRatio` 的 `+ 44` 换成
  ///     `AppMetrics.posterMetaHeight(titleLines: 2)`（= 65.6）
  ///   ★ 两处必须是**同一个**常量来源，否则会出现"卡片算 1 行、容器按 2 行"。
  final int titleLines;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  /// 图片是否已加载成功
  bool _loaded = false;

  /// 是否加载失败（失败后不再重试，显示首字占位）
  bool _failed = false;

  /// 鼠标是否**悬停**在本卡片上（task-50 候选 C1）
  ///
  /// ⚠️ 与 `PressFeedback` 的 `_down` 是**两个独立维度**：
  ///   · `_down`  = 指针**按下**（触摸/鼠标都算）⇒ 缩小
  ///   · `_hover` = 指针**停留**在卡片上（只有鼠标/触控板会发）
  ///   ⇒ 桌面用户"移上去"与"按下去"得到两种不同反馈，互不干扰。
  bool _hover = false;
  bool _focused = false;

  @override
  void didUpdateWidget(PosterCard old) {
    super.didUpdateWidget(old);
    /*
     * ⚠️ 封面换 URL 时要**重置状态**
     *
     * 不重置的话会沿用上一张的 `_loaded` —— 表现为新图还没加载出来
     * 却已经显示了（看到的是上一张图的残影或空白）。
     * 列表滚动复用 widget 时特别容易触发。
     */
    if (old.cover != widget.cover) {
      setState(() {
        _loaded = false;
        _failed = false;
      });
    }
  }

  /// 祖先是否已提供按下反馈（task-50 候选 A 的**双层守卫**，见 [build] 的说明）
  ///
  /// ⚠️ 为什么不只看 `widget.onTap != null` 就够：
  ///   `lib/ui/home_page.dart:991` **已经**在调用点包了 `PressFeedback`
  ///   ⇒ 这里若再包一层，缩放会**叠乘** `0.97 × 0.97 = 0.9409`
  ///     （按下"缩太狠"），且两层时长各自跑 ⇒ 观感不一致。
  ///   ★ 祖先已有 ⇒ 这里让位（`enabled: false` ⇒ `PressFeedback` 直接返回
  ///     child，**零 `AnimatedScale` 层**）⇒ 全仓恒为**单层**。
  ///
  /// ⚠️ `findAncestorWidgetOfExactType` **不建立依赖**（不因祖先变化而重建）——
  ///   这里可接受：祖先的增删必然伴随本子树的 widget 更新 ⇒ `build` 会重跑。
  bool get _hasPressAncestor =>
      context.findAncestorWidgetOfExactType<PressFeedback>() != null;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    /*
     * ★★ 宽度**不许超过父级给的约束** —— 原版 `.poster { max-width: 100% }`
     *    （`base.css:687-744`，`:704-708` 那段注释就是为这个问题写的）。
     *
     * # 不写这一句会怎样
     * `SizedBox(width: w)` 传下去的是**紧约束**，但当父级给的上限比 `w` 小
     * 时 `BoxConstraints.enforce`（SDK `rendering/box.dart:222`）会把它压到
     * 父级上限 ⇒ 卡片**被压扁**（图与标题一起缩），而 `layoutWidth` 还是
     * `w` ⇒ 按错误的尺寸解码封面（解码出来又被裁 ⇒ 糊）。
     * ```text
     * 原版实测：桌面 1280px → 列宽 161 < 海报 168 → 溢出 7px
     *           手机 412px → 列宽 116 < 海报 168 → 溢出 52px
     * ⇒ 现在网格按 `auto-fill` 分列，列宽一般不会小于 152/112，
     *   但**嵌入用法**（比窗口窄的容器、`_ContinueCard` 那种同族网格）
     *   仍可能出现 ⇒ 显式取一次最小值，让解码尺寸与显示尺寸同源。
     * ```
     */
    final avail = MediaQuery.sizeOf(context).width;
    final want = widget.width ?? AppMetrics.posterWidth;
    final w = want > avail ? avail : want;

    // ★ task-50 候选 C1：先造好卡片本体，最后再套 `MouseRegion`（见方法末尾）
    //   ⚠️ 用 `final card =` 而不是把 `MouseRegion` 直接写在 `return` 上：
    //      后者要让下面 275 行整体多缩进两格 ⇒ 纯噪声 diff。
    final bool ringed = widget.focused || (_focused && Device.needsFocusRing);
    final card = SizedBox(
      width: w,
      /*
       * ★★★ task-50 候选 A：按下反馈（2026-09-29）
       *
       * # 为什么加在**组件级**而不是各调用点
       * ```text
       * `PosterCard` 有 **5 个调用点**（browse / follow / home / search / my_shelf）。
       * 只有 `home_page.dart:991` 在调用点包了 `PressFeedback`
       *   ⇒ 其余 **4 个页面的海报卡片"按下去毫无反应"**（真实功能缺失，不是美化）。
       * ⇒ 放进组件本身：**一处生效、5 页受益**，且不会再有"漏了一页"。
       * ```
       *
       * # 为什么用 `PressFeedback` 而不是 `InkWell` 的水波纹
       * ```text
       * 本卡片内部**已有** `InkWell`（点击行为**一个字节都不动**）。
       * `PressFeedback` 用 `Listener`（**不消费手势**）⇒ 缩放只是**视觉叠加**。
       * ```
       *
       * # 判据映射（Lead 五条）
       * ```text
       * ① 反馈操作      ⇒ 按下 scale 真的变小（读渲染矩阵，不是读参数）
       * ② ≤150ms        ⇒ 按下 90ms（`Motion.press`）/ 回弹 150ms（`Motion.fast`）
       * ③ 可打断        ⇒ 中途抬起/取消都回弹，不卡在按下态
       * ④ Reduce Motion ⇒ 走 `MotionPrefs`（开 ⇒ `Duration.zero`，
       *                   仍保留"按下变小"这个**状态**，只去掉过渡）
       * ⑤ 惯用法        ⇒ `AnimatedScale`（`ImplicitlyAnimatedWidget`）
       * ```
       *
       * # ⚠️ 双层守卫（`_hasPressAncestor`）
       * ```text
       * `home_page.dart:991` 已在调用点包了一层 ⇒ 这里再包会**叠乘**
       *   `0.97 × 0.97 = 0.9409`（按下缩太狠）+ 两层时长各自跑（观感不一致）。
       * ⇒ 祖先已有 `PressFeedback` ⇒ 这里 `enabled: false` 让位（零 `AnimatedScale` 层）。
       * ```
       *
       * # ⚠️ `onTap == null` ⇒ 不包
       * ```text
       * 不可点的卡片"按下去会缩"是**假的可点击暗示**。
       * ⇒ `enabled: widget.onTap != null`（`&&` 短路 ⇒ 连祖先查找都不做）。
       * ```
       */
      child: PressFeedback(
        enabled: widget.onTap != null && !_hasPressAncestor,
        child: InkWell(
          onTap: widget.onTap,
          onFocusChange: (f) { if (f != _focused) setState(() => _focused = f); },
          borderRadius: Radii.rMd,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 海报本体 ──
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AspectRatio(
                    aspectRatio: AppMetrics.posterAspect,
                    child: ClipRRect(
                      borderRadius: Radii.rMd,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          /*
                           * 占位底色（图未加载或失败时可见）
                           *
                           * ★★★ task-37：从硬编码深色 `#23262E` 改成
                           * **前景色的 5%** —— 照抄原版
                           * `base.css:734` / `theme-light.css:220`
                           * （两处都是 5%，只是叠的基色不同）。
                           *
                           * # 为什么这样就不"割裂"了（用户原话）
                           *
                           * 旧值 `#23262E` 在浅色主题（用户的实际主题）下
                           * 是背景 `#EEF0F6` 上一个**近黑方块**（对比度 ≈12:1），
                           * 所以"深色方块 → 彩色海报"的跳变非常明显。
                           *
                           * 新写法合成后与背景**只差 5%**：
                           * ```text
                           * 浅色：黑 5% 叠 #EEF0F6 → ≈ #E3E5EB
                           * 深色：白 5% 叠 #0A0A0A → ≈ #161616
                           * ```
                           * ⇒ 占位几乎融进背景，图片淡入时看到的是
                           *   「背景 → 图片」，不是「色块 → 图片」。
                           *
                           * ⚠️ 用 `colors.onSurface`（前景色）而不是写死的黑/白：
                           *    前景色天然是"与背景相反"的那个方向，
                           *    所以**一条规则同时管住深浅两个主题**，
                           *    不需要 `if (brightness)` 分支。
                           */
                          Container(
                            color: colors.onSurface.withValues(
                              alpha: AppColors.posterPlaceholderAlpha,
                            ),
                          ),

                          // 图片
                          if (widget.cover != null &&
                              widget.cover!.isNotEmpty &&
                              !_failed)
                            coverImage(
                              context,
                              url: widget.cover!,
                              // 卡片宽度已知（`w` 就是本卡片的逻辑宽）⇒ 不需要 LayoutBuilder
                              layoutWidth: w,
                              /*
                               * ★★★ 2026-10-01：把**目标框高度**与**源图宽高比**
                               * 一起传下去 —— 修 Owner 报的「哔哩哔哩封面糊」
                               *
                               * # 为什么需要高度
                               * 卡片是 **2:3 竖版**（`AppMetrics.posterAspect`），
                               * 而 B 站封面是 **16:9 横版**（实测 API 返回 2560×1440）。
                               * `BoxFit.cover` 在"源图比目标框更宽"时**按高度放大**：
                               * ```text
                               * 目标 148×223、源 2560×1440
                               *   scaleH = 223/1440 = 0.1549  ← cover 取这个
                               *   ⇒ 实际绘制 396×223
                               * ⇒ 需要解码 **396** px 宽，而只给 layoutWidth 只有 148
                               *   ⇒ 水平放大 2.68 倍 ⇒ **糊**
                               * ```
                               * ⇒ 必须把高度告诉 `coverImage`，它才能反推 396。
                               *
                               * ⚠️ 高度**由宽高比算**（`w / posterAspect`）而不是
                               *    另取一个常量：`AspectRatio` 用的就是同一个
                               *    `posterAspect`（`:200`）⇒ 两者**同源**，
                               *    改了比例不会出现"布局按新比例、解码按旧比例"的错位。
                               */
                              layoutHeight: w / AppMetrics.posterAspect,
                              fit: BoxFit.cover,
                              /*
                               * `frameBuilder` 实现「首次加载才淡入」：
                               * `wasSynchronouslyLoaded` 为 true 说明图已在缓存里
                               * → 直接显示（不做淡入动画）。
                               *
                               * 这正是原版 `isImageReady()` 判定的等价物 ——
                               * 原版要自己维护一个"已就绪 URL 集合"，
                               * Flutter 的 ImageCache 直接给了这个信息。
                               */
                              frameBuilder: (context, child, frame, wasSync) {
                                if (wasSync) return child;
                                return AnimatedOpacity(
                                  opacity: frame == null ? 0 : 1,
                                  duration: Motion.base,
                                  curve: Motion.easeOut,
                                  child: child,
                                );
                              },
                              loadingBuilder: (context, child, progress) {
                                if (progress == null) {
                                  // 加载完成
                                  if (!_loaded) {
                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                      if (mounted) setState(() => _loaded = true);
                                    });
                                  }
                                  return child;
                                }
                                return const SizedBox.shrink();
                              },
                              errorBuilder: (context, error, stack) {
                                // 加载失败 → 记下来，改用首字占位
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted && !_failed) {
                                    setState(() => _failed = true);
                                  }
                                });
                                return const SizedBox.shrink();
                              },
                            ),

                          /*
                           * ══════════════════════════════════════════════════
                           * ★★★ task-63：空标题时画**中性图标**，绝不画 `'?'`
                           * ══════════════════════════════════════════════════
                           *
                           * # Owner 原话（逐字）
                           * ```text
                           * > 还有，播放记录多了几个 显示 ？ 的记录，
                           * > 没有封面没有名字点进去才知道是什么
                           * ```
                           * ★ 他看到的那个「？」**就是这一行**（旧代码 `? '?'`）。
                           *
                           * # 为什么"首字占位"策略在空标题下**不适用**
                           * ```text
                           * 本占位的前提是"标题至少有一个字"（原版 `title.slice(0,1)`）。
                           * 标题为空 ⇒ **没有首字可画** ⇒ 这个策略本身失效。
                           * ★ 此时三种做法都不对：
                           *   · 什么都不画 ⇒ 看着像"图挂了"
                           *   · 随便画一个字 ⇒ **假装是数据**（用户更困惑）
                           *   · 画 `'?'`      ⇒ ★ UI 语义是"出错/未知"，
                           *     而这里**没有出错**（就是数据里没标题）
                           *     ⇒ 正是 Owner 反感的那个观感
                           * ⇒ 用**中性图形**：语言无关、不假装、不像 bug。
                           * ```
                           *
                           * # 为什么是 `movie_outlined` 而不是别的
                           * ```text
                           * 这是**视频**应用的海报位 ⇒ 胶片/影片图标是"这里本来
                           * 该有一张影视封面"的最直接表达，且**不暗示任何具体内容**。
                           * ⚠️ 不用 `Icons.broken_image`（那是"加载失败"的语义，
                           *    而空标题与"图挂了"是两件事 —— 见下面 `_failed` 分支，
                           *    那种情况仍走首字占位）。
                           * ```
                           *
                           * # ★ 本组件是**共享**的（5 个调用点）
                           * ```text
                           * home:980 / search:492 / follow:1373 / browse:294 / my_shelf:785
                           * ⇒ 别处传空标题时同样是"没信息" ⇒ 这个改动对**全部**安全
                           *   （而不是只对播放记录那一处打补丁）。
                           * ```
                           *
                           * ⚠️ 与 `_failed` 的关系（两条不同的路，别混）
                           * ```text
                           * 标题非空 + 图加载失败 ⇒ 仍走**首字占位**（有字可画）✓
                           * 标题为空             ⇒ 走**中性图标**（无字可画）✓
                           * ```
                           */
                          if (!_loaded || _failed)
                            Center(
                              child: widget.title.isEmpty
                                  ? Icon(
                                      Icons.movie_outlined,
                                      size: FontSizes.display * 0.6,
                                      color: colors.onSurfaceVariant
                                          .withValues(alpha: 0.5),
                                    )
                                  : Text(
                                      // 原版 `title.slice(0, 1)` —— 中文一个字就是完整的字
                                      widget.title.characters.first,
                                      style: TextStyle(
                                        fontSize: FontSizes.display * 0.6,
                                        fontWeight: FontWeight.w600,
                                        color: colors.onSurfaceVariant
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                            ),

                          // 右上角角标
                          if (widget.badge != null && widget.badge!.isNotEmpty)
                            Positioned(
                              top: Sp.x2,
                              right: Sp.x2,
                              child: _Chip(text: widget.badge!),
                            ),

                          // 左上角未读
                          if (widget.unread > 0)
                            Positioned(
                              top: Sp.x2,
                              left: Sp.x2,
                              child: _Chip(
                                // 原版：`unread > 99 ? "99+" : unread`
                                text: widget.unread > 99 ? '99+' : '${widget.unread}',
                                color: AppColors.badge,
                              ),
                            ),

                          /*
                           * ★★★ task-50 候选 C1：鼠标悬停高亮（2026-09-30）
                           *
                           * # 为什么加在这里（而不是"再包一层 widget"）
                           * ```text
                           * 本组件**已有**一个 `Stack`（海报本体 + 角标 + 未读 + 聚焦环）
                           *   ⇒ 悬停层作为它的**最后一个兄弟**即可：
                           *     `Positioned.fill` **不进布局** ⇒ 卡片几何一个像素都不变。
                           * ★ 这一点是**既有测试**逼出来的（不是我随便选的）：
                           *   `t50a_poster_press_test.dart` C5 断言"加层后 PosterCard 的
                           *   rect 不变"、C1 断言子树里**恰好一层** `Transform`
                           *   ⇒ 悬停**不能**用 `AnimatedScale`（那会再加一层 Transform，
                           *     两条既有断言立刻变红），也不能用 `Container(color:)`
                           *     （`task37_poster_placeholder_test.dart` 的
                           *      `placeholderColorOf` 取"子树里第一个 color != null 的
                           *      Container" ⇒ 会被本层抢先取到，让占位色断言读错对象）。
                           * ```
                           *
                           * # 为什么用 `AnimatedOpacity` 而不是 `AnimatedContainer`
                           * ```text
                           * 判据⑤ 惯用法：`AnimatedOpacity` 是隐式动画（可打断，判据③）。
                           * ★ 它内部是 `FadeTransition` → `RenderOpacity` ——
                           *   **零 `Transform`**（`AnimatedScale` 才会插 Transform）
                           *   ⇒ 与上面那条"恰好一层 Transform"的既有断言**天然不冲突**。
                           * ★ 而且"透明度 0 → 1"这个读数**比颜色插值更好测**：
                           *   直接读 `FadeTransition.opacity.value`，是精确 double。
                           * ```
                           *
                           * # 为什么 `IgnorePointer`
                           * ```text
                           * 本层铺满整张海报 ⇒ 若不忽略指针，它会参与命中测试。
                           * 卡片的点击由 `InkWell`（**祖先**）负责，理论上仍收得到；
                           * 但"多一个可能吃掉事件的层"没有任何好处 ⇒ 显式忽略，
                           * 让命中测试结果与加本层之前**逐字节相同**。
                           * ```
                           *
                           * # 为什么 `onTap == null` 就不画（判据①的边界）
                           * ```text
                           * 不可点的卡片"移上去会亮"是**假的可点击暗示** ——
                           * 与 `PressFeedback` 那条 `enabled: widget.onTap != null`
                           * 是同一个理由（见上面候选 A 的注释）。
                           * ```
                           */
                          if (widget.onTap != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: AnimatedOpacity(
                                  // ★ 测试用它定位本层（`PosterCard` 里还有**另一个**
                                  //   `AnimatedOpacity` —— 图片首帧淡入，必须区分开）
                                  key: const ValueKey<String>('poster-hover-glow'),
                                  opacity: _hover ? 1 : 0,
                                  // ★ 判据②：150ms（`Motion.fast`，高频操作走最低档）
                                  //   判据④：`MotionPrefs` ⇒ 系统"减少动态效果"时
                                  //           `Duration.zero`（状态仍在，只是无过渡）
                                  duration: MotionPrefs.duration(context, Motion.fast),
                                  curve: MotionPrefs.curve(context, Motion.easeOut),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      // 极淡的品牌色罩（6%）：让"亮起来"有实体感
                                      color: colors.primary.withValues(alpha: 0.06),
                                      borderRadius: Radii.rMd,
                                      // ★ 与 TV 聚焦环**同一种**表达（描边），
                                      //   但更细更淡 ⇒ 两种状态看得出区别：
                                      //   悬停 2px/55%、聚焦 3px/100%
                                      border: Border.all(
                                        color: colors.primary.withValues(alpha: 0.55),
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (ringed) ...[
                    Positioned(
                      left: -6, top: -6, right: -6, bottom: -6,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: Radii.rMd,
                            border: Border.all(
                              color: colors.primary.withValues(alpha: 0.3),
                              width: 6,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: -3, top: -3, right: -3, bottom: -3,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: Radii.rMd,
                            border: Border.all(color: colors.primary, width: 3),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),

              // ── 标题 / 副标题 ──
              const SizedBox(height: Sp.x2),
              Text(
                widget.title,
                // ★ 行数由调用点决定（默认 1 ⇒ 与旧代码逐位相同）
                maxLines: widget.titleLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.base,
                  fontWeight: FontWeights.regular,
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
      ),
    );

    /*
     * ★★★ task-50 候选 C1：悬停检测 + 手型光标
     *
     * # 为什么 `MouseRegion` 包在**整张卡片**外面
     * ```text
     * 悬停高亮画在海报区（Stack 里），但"什么算悬停"应当是**整张卡片**：
     * 鼠标移到标题文字上时，用户认为他仍在"这张卡片上"。
     * ⇒ 检测层包最外层（含标题/副标题），高亮层只画在海报区。
     * ```
     *
     * # 为什么 `cursor` 要跟着 `onTap` 变
     * ```text
     * `SystemMouseCursors.click`（手型）= "这里可以点"。
     * `onTap == null` 时卡片不可点 ⇒ 必须退回默认箭头
     *   （否则又是一个"假的可点击暗示"）。
     * ```
     *
     * # ⚠️ `MouseRegion` 对既有行为的影响 = 0
     * ```text
     * · 不进布局（`getRect(PosterCard)` 不变 —— `t50a` C5 断言过）
     * · 不插 `Transform`（`t50a` C1 断言"恰好一层"）
     * · 不改命中测试（它只"听"悬停，点击仍由内层 `InkWell` 处理 —— `t50a` C4）
     * · `flutter test` 里 `tester.tap` **不发**悬停事件 ⇒ 既有测试不受影响
     * ```
     */
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: card,
    );
  }
}

/// 海报上的小标签（角标 / 未读数）
class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 2),
      decoration: BoxDecoration(
        color: color ?? Colors.black.withValues(alpha: 0.62),
        borderRadius: Radii.rFull,
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: FontSizes.cap,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}
